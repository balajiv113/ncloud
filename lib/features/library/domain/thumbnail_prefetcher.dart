import 'dart:async';

import '../../../models.dart';
import 'preview_batcher.dart';
import 'thumbnail_repository.dart';

/// Fetches thumbnails of recent Timeline photos in the background, a batch at
/// a time, so scrolling finds them already stored. Visible tiles share these
/// requests and still take priority.
///
/// It waits while the library is busy or the app is inactive, and drops its
/// work when asked to [clear].
class ThumbnailPrefetcher {
  ThumbnailPrefetcher({
    required this.thumbnails,
    required this.account,
    required this.enabled,
    required this.active,
    required this.idle,
    required this.fetch,
    required this.onFailure,
    required this.limit,
    required this.recentDays,
    this.batchSize = 48,
    this.delay = const Duration(milliseconds: 250),
  });

  final ThumbnailRepository thumbnails;
  final Account? Function() account;

  /// Whether prefetching is wanted at all, such as when thumbnails persist.
  final bool Function() enabled;

  /// Whether the app is showing the Timeline and may spend bandwidth.
  final bool Function() active;

  /// Whether nothing else is loading, which has priority.
  final bool Function() idle;
  final Future<void> Function(CloudFile file) fetch;
  final void Function() onFailure;

  /// Most photos remembered; the shared store holds no more.
  final int limit;

  /// Only photos taken within this many days are fetched.
  final int recentDays;
  final int batchSize;
  final Duration delay;

  final List<CloudFile> _queue = [];
  final Set<String> _known = {};
  Timer? _timer;
  bool _running = false;

  /// Adds the recent, not yet seen photos of [files] and starts a batch soon.
  void queue(Iterable<CloudFile> files) {
    if (!enabled()) return;
    final today = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;
    for (final file in files) {
      if (_known.length >= limit) break;
      if (!file.isMedia ||
          file.captureDay == null ||
          file.captureDay! < today - recentDays) {
        continue;
      }
      final key = thumbnails.key(file, 384);
      if (key != null &&
          _known.add('$key|${ThumbnailRepository.versionOf(file) ?? ''}')) {
        _queue.add(file);
      }
    }
    schedule();
  }

  /// Starts the next batch after a short pause, unless one is running or there
  /// is nothing to do.
  void schedule() {
    if (_running || _queue.isEmpty || !active()) return;
    _timer?.cancel();
    _timer = Timer(delay, _runBatch);
  }

  Future<void> _runBatch() async {
    if (!active() || account() == null) return;
    if (!idle()) {
      schedule();
      return;
    }
    _running = true;
    final session = account();
    final batch = _queue.take(batchSize).toList();
    _queue.removeRange(0, batch.length);
    try {
      await Future.wait([
        for (final file in batch)
          fetch(file).then<void>(
            (_) {},
            onError: (Object e) {
              if (e is! PreviewCancelled && identical(account(), session)) {
                onFailure();
              }
            },
          ),
      ]);
    } finally {
      _running = false;
      if (identical(account(), session)) schedule();
    }
  }

  /// Stops waiting to start a batch; queued photos are kept.
  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  /// Forgets every queued photo.
  void clear() {
    pause();
    _queue.clear();
    _known.clear();
  }
}
