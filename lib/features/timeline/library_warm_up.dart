import 'dart:async';
import 'dart:math' as math;

import '../../app/status_sink.dart';
import '../../core/storage/local_cache.dart';
import '../../diagnostics.dart';
import '../../models.dart';
import '../../core/storage/media_listing.dart';
import '../../core/thumbnails/preview_batcher.dart';

/// The one-time welcome after the first sign-in: loads the Timeline index, the
/// metadata of the recent years, the albums and people, and the first screen of
/// thumbnails, so the library opens already full. A returning user, or one with a stored
/// timeline, skips it. Skipping only hides the screen; loading continues.
class LibraryWarmUp {
  LibraryWarmUp({
    required this.cache,
    required this.account,
    required this.disposed,
    required this.browsingActive,
    required this.status,
    required this.listingKey,
    required this.load,
    required this.activeListing,
    required this.loadNextPage,
    required this.loadCatalogue,
    required this.items,
    required this.preview,
    required this.storeWritten,
    required this.started,
    required this.onChanged,
    this.budget = defaultBudget,
  });

  static const defaultBudget = Duration(seconds: 30);

  /// How many years back the welcome prepares.
  static const years = 3;

  final LocalCache? cache;
  final Account? Function() account;
  final bool Function() disposed;
  final bool Function() browsingActive;
  final StatusSink status;

  /// Key of the Timeline's stored listing for the current account.
  final String Function() listingKey;
  final Future<void> Function() load;
  final MediaListing? Function() activeListing;
  final Future<void> Function() loadNextPage;

  /// Loads the albums, shared albums and people, so the Albums tab opens full.
  final Future<void> Function() loadCatalogue;
  final List<CloudFile> Function() items;
  final Future<void> Function(CloudFile file) preview;

  /// Completes when the library's pending metadata write has finished.
  final Future<void>? Function() storeWritten;

  /// Called once the first screen can be shown, welcome or not.
  final void Function() started;

  /// Tells listeners the welcome's progress changed.
  final void Function() onChanged;
  final Duration budget;

  /// True while the welcome screen is shown.
  bool warming = false;
  double progress = 0;

  /// 0 day index, 1 recent metadata, 2 thumbnails, 3 ready.
  int phase = 0;
  String index = '';
  int done = 0;
  int total = 0;

  int _version = 0;
  Timer? _timer;

  /// Decides whether the welcome is needed and runs it, or loads the stored
  /// library.
  Future<void> prepare() async {
    final session = account()!;
    final key = 'warm-v2|${session.storageKey}';
    final prepared = await cache?.readDocument(key);
    if (disposed() || account() != session) return;
    final saved = await cache?.readDocument(listingKey());
    if (disposed() || account() != session) return;
    var cachedLibrary = false;
    if (saved != null) {
      try {
        MediaListing.fromJson(saved);
        cachedLibrary = true;
      } catch (e) {
        status.notice =
            'The saved timeline needs rebuilding. ${errorMessage(e)}';
      }
    }
    started();
    if (prepared?['complete'] == true || cachedLibrary) {
      warming = false;
      onChanged();
      await load();
      return;
    }
    warming = true;
    progress = 0;
    phase = 0;
    index = '';
    done = total = 0;
    onChanged();
    await _run();
    if (!disposed() &&
        account() == session &&
        status.error == null &&
        done == total &&
        phase == 3) {
      await storeWritten();
      await cache?.writeDocument(key, {'complete': true});
    }
  }

  Future<void> _run() async {
    final version = ++_version;
    final session = account();
    final deadline = DateTime.now().add(budget);
    _timer?.cancel();
    _timer = Timer(budget, () {
      if (version == _version) skip();
    });
    bool current() =>
        version == _version && !disposed() && account() == session;
    void step(double value, int next) {
      if (!current() || !warming) return;
      progress = value;
      phase = next;
      onChanged();
    }

    try {
      step(0.03, 0);
      await load();
      final listing = activeListing();
      final days = listing?.days;
      if (!current() || listing == null || status.error != null) return;
      final catalogue = loadCatalogue().then<void>(
        (_) {},
        onError: (Object e) {
          if (current()) {
            status.notice = 'Albums could not be prepared. ${errorMessage(e)}';
          }
        },
      );
      final thumbnails = Future.wait([
        for (final file in items().where((f) => f.isMedia).take(60))
          preview(file).then<void>(
            (_) {},
            onError: (Object e) {
              if (current() && e is! PreviewCancelled) {
                status.notice =
                    'Some previews could not be prepared. Tap them to retry.';
              }
            },
          ),
      ]);
      if (days != null && days.isNotEmpty) {
        final span = [
          for (final day in [
            days.map((d) => d.id).reduce(math.min),
            days.map((d) => d.id).reduce(math.max),
          ])
            DateTime.fromMillisecondsSinceEpoch(
              day * 86400000,
              isUtc: true,
            ).year,
        ];
        final count = days.fold(0, (sum, d) => sum + d.count);
        index =
            '$count photos · '
            '${span.first == span.last ? span.first : span.join('–')}';
      }
      if (days != null) {
        final today = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;
        final recent = days.where((d) => d.id >= today - years * 366).toList();
        final all = recent.fold(0, (sum, d) => sum + d.count);
        total = all;
        while (current() &&
            browsingActive() &&
            DateTime.now().isBefore(deadline) &&
            identical(listing, activeListing())) {
          final missing = recent
              .where((d) => !listing.loaded.contains(d.id))
              .fold(0, (sum, d) => sum + d.count);
          done = all - missing;
          if (missing == 0) break;
          step(0.1 + 0.7 * done / math.max(1, all), 1);
          final before = listing.loaded.length;
          await loadNextPage();
          if (listing.loaded.length == before) break;
        }
        done =
            all -
            recent
                .where((d) => !listing.loaded.contains(d.id))
                .fold(0, (sum, d) => sum + d.count);
      }
      if (!current()) return;
      step(0.85, 2);
      final left = deadline.difference(DateTime.now());
      if (left > Duration.zero) {
        await Future.wait([
          thumbnails,
          catalogue,
        ]).timeout(left, onTimeout: () => []);
      }
      if (current() && done == total) {
        progress = 1;
        phase = 3;
        onChanged();
      }
    } on Object catch (e) {
      if (current()) status.error ??= errorMessage(e);
    } finally {
      if (version == _version) {
        _timer?.cancel();
        skip();
      }
    }
  }

  /// Leaves the welcome screen; loading continues in the background.
  void skip() {
    if (!warming) return;
    warming = false;
    onChanged();
  }

  /// Abandons any welcome in progress, as when the cache is cleared or the
  /// account signs out.
  void cancel() {
    _version++;
    _timer?.cancel();
    warming = false;
  }
}
