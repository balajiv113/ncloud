import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'demo.dart';
import 'file_store.dart';
import 'local_cache.dart';
import 'models.dart';
import 'nextcloud_client.dart';

abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

/// A fetched page; [scanned] counts server results before filtering.
typedef _Page = ({List<CloudFile> files, List<int> days, int scanned});

class SecureSessionStore implements SessionStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const _key = 'ncloud.account.v1';

  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

String errorMessage(Object error) => switch (error) {
  CloudException() => error.message,
  FormatException() =>
    'Invalid address, name, or server response. ${error.message}',
  SocketException() => 'No connection to the server. Check your network.',
  FileSystemException() =>
    'Cannot access this file. Check free space and permissions.',
  TimeoutException() => 'The operation timed out. Please try again.',
  PlatformException() =>
    'A device service failed. Please retry or restart the app.',
  _ =>
    'The operation failed unexpectedly. Please retry and check server compatibility.',
};

class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    NextcloudClient? client,
    this.cache,
    this.pathlessTimeline = false,
  }) : client = client ?? NextcloudClient();

  /// Paints the Timeline straight from Memories rows and resolves real paths
  /// only when an action needs them.
  final bool pathlessTimeline;

  final SessionStore store;
  final NextcloudClient client;

  /// Optional persistent cache; tests run purely in memory without it.
  final LocalCache? cache;

  /// True while showing locally cached results that are being refreshed.
  bool refreshing = false;
  Account? account;
  bool demo = false;
  bool starting = true;
  bool signingIn = false;
  bool _savingAccount = false;
  bool loading = false;
  bool busy = false;
  bool loadingMore = false;
  bool hasMore = false;
  final Map<String, _MediaListing> _listings = {};

  /// The one cache of files shared by Timeline, Albums, Shared and Drive.
  final FileStore fileStore = FileStore();
  Future<void>? _restoringStore;
  String? _storeOwner;
  Future<void>? _storeWrite;
  bool _storeDirty = false;
  final Set<int> _pendingDays = {};
  bool _fetchingDays = false;

  /// True while days requested by the scrolling timeline are downloading.
  bool fetchingDays = false;
  _MediaListing? _activeListing;
  String? _visibleListingKey;
  bool? memoriesAvailable;
  bool discoveringAlbums = false;
  int discoveredFolders = 0;
  final List<SmartAlbum> _catalogue = [];
  DateTime? _catalogueUpdated;
  String? _catalogueRoot;
  List<MemoryDay>? _initialDays;
  Future<void>? _detectingMemories;
  int _catalogueVersion = 0;
  Future<void>? _catalogueTask;
  Account? _catalogueSession;
  bool get albumHome =>
      tab == 4 && !smartAlbumOpen && activeNativeAlbum == null;
  List<MemoryDay> get indexedDays => _activeListing?.days ?? [];
  List<CloudFile> _libraryFiles = [];
  List<NativeAlbum> nativeAlbums = [];
  NativeAlbum? activeNativeAlbum;
  bool smartAlbumOpen = false;
  String? nativeAlbumError;
  String? catalogueError;
  final List<SmartAlbum> sharedAlbums = [];
  String? sharedAlbumError;
  bool loadingSharedAlbums = false;
  DateTime? _sharedAlbumsUpdated;
  Future<void>? _sharedAlbumsTask;
  int _sharedAlbumsVersion = 0;
  bool get sharedAlbumHome => tab == 5 && directory.isEmpty;
  List<String>? _demoPhotoRoot;
  List<String>? _autoPhotoRoot;
  List<CloudFile> get libraryFiles => _libraryFiles;
  List<String> get photoRoot =>
      (demo ? _demoPhotoRoot : account?.photoRoot) ??
      _autoPhotoRoot ??
      (_libraryFiles.any((f) => f.path.firstOrNull == 'Photos')
          ? ['Photos']
          : []);
  List<SmartAlbum> get smartAlbums =>
      demo ? buildSmartAlbums(_libraryFiles, photoRoot) : _catalogue;
  int completed = 0;
  int total = 0;
  int tab = 0;
  List<String> directory = [];
  List<CloudFile> items = [];
  String? error;
  String? notice;
  int _loadVersion = 0;
  int _loginVersion = 0;
  bool _disposed = false;
  List<CloudFile> _demo = [];

  /// Decoded-ready thumbnails keyed by file id and size, each tagged with
  /// the file version it was rendered from. Survives revisions so a stale
  /// thumbnail stays on screen until its replacement arrives.
  final Map<String, ({Uint8List bytes, String version})> _thumbs = {};
  int _thumbBytes = 0;
  static const thumbnailMemoryBudget = 64 * 1024 * 1024;
  final Map<String, Future<Uint8List>> _previewLoads = {};
  final Map<String, int> _previewInterest = {};
  final Map<String, _PreviewRequest> _previewBatch = {};
  Timer? _previewTimer;
  int _previewBatches = 0;
  bool _multipreviewUnavailable = false;
  int _multipreviewFailures = 0;
  Timer? _thumbnailWarmupTimer;
  final List<CloudFile> _thumbnailWarmupQueue = [];
  final Set<String> _thumbnailWarmupKnown = {};
  bool _warmingThumbnails = false;
  final Map<String, Future<CloudFile?>> _covers = {};
  final Map<String, List<CloudFile>> _demoTrash = {};

  bool get connected => account != null || demo;
  bool get canCancelLogin => signingIn && !_savingAccount;

  Future<void> initialize() async {
    try {
      final saved = await store.read();
      if (saved != null) account = Account.decode(saved);
      warming = connected;
    } catch (e) {
      error = 'Could not restore the saved account. ${errorMessage(e)}';
    } finally {
      starting = false;
      notifyListeners();
    }
    if (connected) {
      final preparation = _prepareLibrary(refresh: false);
      unawaited(_prepareAlbums());
      unawaited(_prepareSharedAlbums(refresh: false));
      await preparation;
    }
  }

  void enterDemo() {
    if (_savingAccount) return;
    cancelLogin();
    demo = true;
    _demo = demoFiles();
    _demoTrash.clear();
    tab = 0;
    directory = [];
    error = null;
    notice = null;
    unawaited(load());
  }

  Future<void> passwordLogin(
    String server,
    String user,
    String password,
  ) async {
    final version = ++_loginVersion;
    signingIn = true;
    error = null;
    notifyListeners();
    try {
      final result = await client.authenticate(
        normalizeServer(server),
        user,
        password,
      );
      if (version != _loginVersion) return;
      await _saveAccount(result);
    } catch (e) {
      if (version == _loginVersion) error = errorMessage(e);
    } finally {
      if (version == _loginVersion) {
        signingIn = false;
        notifyListeners();
      }
    }
  }

  Future<void> browserLogin(
    String server,
    Future<bool> Function(Uri) openBrowser,
  ) async {
    final version = ++_loginVersion;
    signingIn = true;
    error = null;
    notifyListeners();
    try {
      final uri = normalizeServer(server);
      final flow = await client.startLogin(uri);
      if (version != _loginVersion) return;
      if (!await openBrowser(flow.login)) {
        throw const CloudException(
          'Could not open your browser. Try an app password instead.',
        );
      }
      final deadline = DateTime.now().add(const Duration(minutes: 20));
      while (version == _loginVersion && DateTime.now().isBefore(deadline)) {
        final result = await client.pollLogin(uri, flow);
        if (version != _loginVersion) return;
        if (result != null) {
          await _saveAccount(result);
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (version == _loginVersion) {
        throw const CloudException(
          'Sign-in timed out. Start again to get a new login link.',
        );
      }
    } catch (e) {
      if (version == _loginVersion) error = errorMessage(e);
    } finally {
      if (version == _loginVersion) {
        signingIn = false;
        notifyListeners();
      }
    }
  }

  void cancelLogin() {
    if (_savingAccount) return;
    _loginVersion++;
    signingIn = false;
    notifyListeners();
  }

  Future<void> _saveAccount(Account result) async {
    _savingAccount = true;
    notifyListeners();
    try {
      await store.write(result.encode());
      account = result;
      demo = false;
      tab = 0;
      directory = [];
      final preparation = _prepareLibrary();
      unawaited(_prepareAlbums());
      unawaited(_prepareSharedAlbums(refresh: false));
      await preparation;
    } finally {
      _savingAccount = false;
    }
  }

  /// True while the one-time welcome screen preloads recent years.
  bool warming = false;
  double warmProgress = 0;

  /// 0 day index, 1 recent metadata, 2 thumbnails, 3 ready.
  int warmPhase = 0;
  String warmIndex = '';
  int warmDone = 0;
  int warmTotal = 0;
  int _warmVersion = 0;
  Timer? _warmTimer;
  static const warmBudget = Duration(seconds: 30);
  static const warmYears = 3;

  Future<void> _prepareLibrary({bool refresh = true}) async {
    final session = account!;
    final key = 'warm-v2|${session.server}|${session.userId}';
    warming = true;
    warmProgress = 0;
    warmPhase = 0;
    warmIndex = '';
    warmDone = warmTotal = 0;
    notifyListeners();
    final prepared = await cache?.readDocument(key);
    if (_disposed || account != session) return;
    if (prepared?['complete'] == true) {
      skipWarmUp();
      await load(refresh: refresh);
      return;
    }
    await _warmUp();
    if (!_disposed &&
        account == session &&
        error == null &&
        warmDone == warmTotal &&
        warmPhase == 3) {
      await _storeWrite;
      await cache?.writeDocument(key, {'complete': true});
    }
  }

  /// After the first sign-in, loads the Timeline index, then the metadata of
  /// recent years and the first screen of thumbnails, within [warmBudget].
  /// Skipping only hides the screen; metadata keeps loading quietly.
  Future<void> _warmUp() async {
    final version = ++_warmVersion;
    final session = account;
    final deadline = DateTime.now().add(warmBudget);
    _warmTimer?.cancel();
    _warmTimer = Timer(warmBudget, () {
      if (version == _warmVersion) skipWarmUp();
    });
    bool active() =>
        version == _warmVersion && !_disposed && account == session;
    void step(double progress, int phase) {
      if (!active() || !warming) return;
      warmProgress = progress;
      warmPhase = phase;
      notifyListeners();
    }

    try {
      step(0.03, 0);
      await load(refresh: false);
      final listing = _activeListing;
      final days = listing?.days;
      if (!active() || listing == null || error != null) return;
      final thumbnails = Future.wait([
        for (final file in items.where((f) => f.isMedia).take(60))
          preview(file).then<void>(
            (_) {},
            onError: (Object e) {
              if (active() && e is! PreviewCancelled) {
                notice =
                    'Some previews could not be prepared. Tap them to retry.';
              }
            },
          ),
      ]);
      if (days != null && days.isNotEmpty) {
        final years = [
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
        warmIndex =
            '$count photos · '
            '${years.first == years.last ? years.first : years.join('–')}';
      }
      if (days != null) {
        final today = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;
        final recent = days
            .where((d) => d.id >= today - warmYears * 366)
            .toList();
        final total = recent.fold(0, (sum, d) => sum + d.count);
        warmTotal = total;
        while (active() &&
            DateTime.now().isBefore(deadline) &&
            identical(listing, _activeListing)) {
          final missing = recent
              .where((d) => !listing.loaded.contains(d.id))
              .fold(0, (sum, d) => sum + d.count);
          warmDone = total - missing;
          if (missing == 0) break;
          step(0.1 + 0.7 * warmDone / math.max(1, total), 1);
          final before = listing.loaded.length;
          await loadNextPage();
          if (listing.loaded.length == before) break;
        }
        warmDone =
            total -
            recent
                .where((d) => !listing.loaded.contains(d.id))
                .fold(0, (sum, d) => sum + d.count);
      }
      if (!active()) return;
      step(0.85, 2);
      final left = deadline.difference(DateTime.now());
      if (left > Duration.zero) {
        await thumbnails.timeout(left, onTimeout: () => []);
      }
      if (active() && warmDone == warmTotal) {
        warmProgress = 1;
        warmPhase = 3;
        notifyListeners();
      }
    } on Object catch (e) {
      error ??= errorMessage(e);
    } finally {
      if (version == _warmVersion) {
        _warmTimer?.cancel();
        skipWarmUp();
      }
    }
  }

  /// Leaves the welcome screen; loading continues in the background.
  void skipWarmUp() {
    if (!warming) return;
    warming = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      if (!demo) {
        await store.clear();
        final cache = Directory(
          '${(await getTemporaryDirectory()).path}/ncloud-downloads',
        );
        if (await cache.exists()) await cache.delete(recursive: true);
        _storeOwner = null;
        await _storeWrite;
        await this.cache?.clear();
      }
      _loadVersion++;
      _loginVersion++;
      _clearPreviews();
      _covers.clear();
      _demoTrash.clear();
      _warmVersion++;
      warming = false;
      account = null;
      demo = false;
      _demo = [];
      _libraryFiles = [];
      _listings.clear();
      fileStore.clear();
      _storeOwner = null;
      _restoringStore = null;
      _pendingDays.clear();
      _activeListing = null;
      _visibleListingKey = null;
      _catalogue.clear();
      _catalogueVersion++;
      _catalogueUpdated = null;
      _catalogueRoot = null;
      _catalogueTask = null;
      _catalogueSession = null;
      sharedAlbums.clear();
      sharedAlbumError = null;
      loadingSharedAlbums = false;
      _sharedAlbumsUpdated = null;
      _sharedAlbumsTask = null;
      _sharedAlbumsVersion++;
      catalogueError = null;
      memoriesAvailable = null;
      _initialDays = null;
      _detectingMemories = null;
      nativeAlbums = [];
      activeNativeAlbum = null;
      smartAlbumOpen = false;
      _demoPhotoRoot = null;
      _autoPhotoRoot = null;
      items = [];
      directory = [];
      notice = null;
      loading = false;
    } catch (e) {
      error =
          'Could not completely clear local session data. ${errorMessage(e)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> selectTab(int value) async {
    tab = value;
    directory = [];
    activeNativeAlbum = null;
    smartAlbumOpen = false;
    await load(refresh: false);
  }

  Future<void> openFolder(CloudFile folder) async {
    tab = 1;
    activeNativeAlbum = null;
    smartAlbumOpen = false;
    directory = [...folder.path];
    await load(refresh: false);
  }

  Future<void> goTo(List<String> path) async {
    directory = [...path];
    activeNativeAlbum = null;
    smartAlbumOpen = false;
    await load(refresh: false);
  }

  Future<void> openSmartAlbum(List<String> path) async {
    tab = 4;
    directory = [...path];
    activeNativeAlbum = null;
    smartAlbumOpen = true;
    await load(refresh: false);
  }

  bool get albumIncludesSubfolders =>
      tab != 4 || !listEquals(directory, photoRoot);

  /// The main timeline resolves paths on demand; albums need paths for their
  /// sub-folder chips.
  bool _pathless(int currentTab) =>
      pathlessTimeline && currentTab == 0 && activeNativeAlbum == null;

  /// Metadata-only batches are cheap, so the timeline asks for many more
  /// photos per request than views that must look up paths.
  int _dayBatchLimit(int currentTab) => _pathless(currentTab) ? 1500 : 200;

  bool _recursiveMedia(int currentTab, List<String> path) =>
      currentTab != 4 || !listEquals(path, photoRoot);

  Future<void> openNativeAlbum(NativeAlbum album) async {
    activeNativeAlbum = album;
    smartAlbumOpen = false;
    tab = 4;
    directory = [];
    await load(refresh: false);
  }

  Future<void> openSharedAlbum(List<String> path) async {
    tab = 5;
    directory = [...path];
    activeNativeAlbum = null;
    smartAlbumOpen = false;
    await load(refresh: false);
  }

  Future<void> setPhotoRoot(List<String> path) async {
    if (demo) {
      _demoPhotoRoot = [...path];
    } else if (account case final session?) {
      final updated = session.withPhotoRoot(path);
      try {
        await store.write(updated.encode());
      } catch (e) {
        error = 'Could not save your photo source. ${errorMessage(e)}';
        notifyListeners();
        return;
      }
      account = updated;
    }
    await selectTab(4);
  }

  Future<void> load({bool refresh = true}) async {
    final version = ++_loadVersion;
    if (refresh) _initialDays = null;
    final session = account;
    final currentTab = tab;
    final path = [...directory];
    final native = activeNativeAlbum;
    final listingKey = _listingKey();
    final keepItems = listingKey != null && listingKey == _visibleListingKey;
    loading = true;
    refreshing = keepItems && items.isNotEmpty;
    loadingMore = false;
    hasMore = false;
    error = null;
    _activeListing = null;
    _timelineChanges = null;
    _pendingDays.clear();
    if (!keepItems) {
      final previous = _listings[listingKey];
      items = previous != null
          ? fileStore.resolve(previous.keys)
          : _seed(currentTab, path, native);
    }
    _visibleListingKey = listingKey;
    notifyListeners();
    try {
      if (demo) {
        items = native != null
            ? _demo.where((f) => f.isMedia && f.favorite).toList()
            : _demo
                  .where(
                    (file) => switch (currentTab) {
                      0 || 4 =>
                        file.isMedia &&
                            pathStartsWith(file.path, path) &&
                            (_recursiveMedia(currentTab, path) ||
                                file.path.length == path.length + 1),
                      2 => file.favorite,
                      5 || 6 => false,
                      _ =>
                        file.path.length == path.length + 1 &&
                            pathStartsWith(file.path, path),
                    },
                  )
                  .toList();
        if (currentTab == 0 || albumHome) _libraryFiles = items;
        if (albumHome) {
          nativeAlbums = [
            const NativeAlbum(
              name: 'Best days',
              davPath: ['demo-album'],
              count: 3,
            ),
          ];
        }
        return;
      }
      if (session == null) return;
      if (sharedAlbumHome) {
        await _prepareSharedAlbums(refresh: refresh);
        return;
      }
      if (albumHome) {
        await Future.wait([
          _prepareAlbums(refresh: refresh),
          _prepareSharedAlbums(refresh: refresh),
        ]);
        return;
      }
      await _restoreStore(session);
      if (version != _loadVersion) return;
      _MediaListing? previous = listingKey == null
          ? null
          : _listings[listingKey];
      if (previous == null && listingKey != null) {
        final document = await cache?.readDocument(listingKey);
        if (version != _loadVersion) return;
        if (document != null) previous = _MediaListing.fromJson(document);
      }
      final known = previous == null ? null : fileStore.resolve(previous.keys);
      if (previous != null && known!.length == previous.keys.length) {
        items = known;
        refreshing = true;
        notifyListeners();
        if (!refresh && previous.fresh(fileStore) && currentTab != 6) {
          if (previous.days != null) memoriesAvailable ??= true;
          _activeListing = previous;
          _listings[listingKey!] = previous;
          hasMore = previous.more;
          if (currentTab == 0) _libraryFiles = items;
          return;
        }
      } else if (listingKey != null) {
        final cached = await cache?.readListing(listingKey);
        if (version != _loadVersion) return;
        final seed = cached ?? _seed(currentTab, path, native);
        if (seed.isNotEmpty && !keepItems) {
          items = seed;
          refreshing = true;
          notifyListeners();
        }
      }
      final listing = _MediaListing();
      if (currentTab == 6) {
        final saved = await cache?.readListing(_offlineListingKey) ?? [];
        final available = <CloudFile>[];
        for (final file in saved) {
          if (await offlineCopy(file) != null) available.add(file);
        }
        listing.add(fileStore, available);
      } else if (native != null) {
        listing.add(
          fileStore,
          await client.albumFiles(session, native, _libraryFiles),
        );
      } else if (currentTab == 1) {
        listing.add(
          fileStore,
          await _listFolder(session, path, force: refresh),
        );
      } else {
        if (currentTab != 5) await _ensureMemories(session);
        if (version != _loadVersion) return;
        if (memoriesAvailable == true && currentTab != 5) {
          listing.days = currentTab == 0 && _initialDays != null
              ? _initialDays
              : await client.memoryDays(
                  session,
                  path: path,
                  favorites: currentTab == 2,
                  recursive: _recursiveMedia(currentTab, path),
                );
          _initialDays = null;
        }
        listing.more = true;
        final previousDays = previous?.days;
        if (listing.days case final days? when !refresh) {
          if (previousDays != null) {
            // Keep days whose index entry and cached files are unchanged so
            // revalidation only downloads days that actually changed.
            final before = {for (final day in previousDays) day.id: day.count};
            final byDay = <int, List<CloudFile>>{};
            for (final file in known ?? <CloudFile>[]) {
              if (file.captureDay case final day?) {
                byDay.putIfAbsent(day, () => []).add(file);
              }
            }
            for (final day in days) {
              final files = byDay[day.id] ?? const <CloudFile>[];
              if (previous!.loaded.contains(day.id) &&
                  before[day.id] == day.count &&
                  files.length == day.count) {
                listing.add(fileStore, files);
                listing.loaded.add(day.id);
              }
            }
            listing.more = days.any((d) => !listing.loaded.contains(d.id));
          }
        }
        if (listing.loaded.isEmpty) {
          await _fetchPage(listing, session, currentTab, path);
        }
      }
      if (version != _loadVersion || _disposed) return;
      await _publishListing(listing, listingKey);
    } catch (e) {
      if (version == _loadVersion) error = errorMessage(e);
    } finally {
      if (version == _loadVersion) {
        loading = false;
        refreshing = false;
        loadingMore = false;
        if (tab == 0) _queueThumbnailWarmup(items);
        notifyListeners();
      }
    }
  }

  /// Files the shared store already knows for a view, shown instantly while
  /// the server confirms the authoritative list.
  List<CloudFile> _seed(int tab, List<String> path, NativeAlbum? native) {
    if (native != null || tab == 3 || tab == 6) return [];
    if (tab == 1) return fileStore.folder(path, fresh: false) ?? [];
    final recursive = _recursiveMedia(tab, path);
    return fileStore.where(
      (f) =>
          f.isMedia &&
          f.albumDavPath == null &&
          pathStartsWith(f.path, path) &&
          (recursive || f.path.length == path.length + 1) &&
          (tab != 2 || f.favorite),
    );
  }

  String _storeKey(Account session) =>
      'library-v1|${session.server}|${session.userId}';

  Future<void> _restoreStore(Account session) {
    final owner = _storeKey(session);
    if (_storeOwner == owner) return _restoringStore ?? Future.value();
    _storeOwner = owner;
    fileStore.clear();
    return _restoringStore = () async {
      final saved = await cache?.readDocument(owner);
      if (saved != null && _storeOwner == owner) {
        try {
          fileStore.restore(saved);
        } on Object {
          // A damaged cache is rebuilt from the server.
        }
      }
    }();
  }

  /// Saves the shared store, coalescing bursts of updates into one write.
  void _persistStore() {
    final session = account;
    if (cache == null || session == null || demo) return;
    if (_storeWrite != null) {
      _storeDirty = true;
      return;
    }
    final key = _storeKey(session);
    _storeWrite = () async {
      do {
        _storeDirty = false;
        if (_storeOwner != key) return;
        await cache!.writeDocument(key, fileStore.toJson());
      } while (_storeDirty);
    }().whenComplete(() => _storeWrite = null);
  }

  /// Direct children of a folder, reused from the shared store when the
  /// folder was listed recently or its recursive etag is unchanged.
  Future<List<CloudFile>> _listFolder(
    Account session,
    List<String> path, {
    bool force = false,
  }) async {
    await _restoreStore(session);
    if (!force) {
      final known = fileStore.folder(path);
      if (known != null) return known;
    }
    final result = await client.listFolder(session, path);
    if (account != session) return result.children;
    if (result.self case final self?) {
      if (path.isNotEmpty) fileStore.putAll([self]);
    }
    fileStore.putFolder(path, result.children, etag: result.self?.etag);
    _persistStore();
    return result.children;
  }

  Future<void> _ensureMemories(Account session) async {
    if (memoriesAvailable != null) return;
    final pending = _detectingMemories;
    if (pending != null) return pending;
    final detection = () async {
      final days = await client.memoryDays(session, optional: true);
      if (account != session || _disposed) return;
      memoriesAvailable = days != null;
      _initialDays = days;
    }();
    _detectingMemories = detection;
    try {
      await detection;
    } finally {
      if (identical(_detectingMemories, detection)) _detectingMemories = null;
    }
  }

  /// Fetches the next unloaded days (or WebDAV page) without changing
  /// [listing]; the caller merges the result only if it is still current.
  Future<_Page> _nextPage(
    _MediaListing listing,
    Account session,
    int currentTab,
    List<String> path,
  ) async {
    final recursive = _recursiveMedia(currentTab, path);
    if (listing.days case final days?) {
      final ids = <int>[];
      var count = 0;
      final limit = _dayBatchLimit(currentTab);
      for (final day in days) {
        if (listing.loaded.contains(day.id)) continue;
        if (ids.length >= 120 ||
            (ids.isNotEmpty && count + day.count > limit)) {
          break;
        }
        ids.add(day.id);
        count += day.count;
      }
      if (ids.isEmpty) return (files: <CloudFile>[], days: ids, scanned: 0);
      final files = await client.memoryDayFiles(
        session,
        ids,
        path: path,
        favorites: currentTab == 2,
        recursive: recursive,
        resolvePaths: !_pathless(currentTab),
      );
      return (files: files, days: ids, scanned: files.length);
    }
    final page = await client.searchPage(
      session,
      favorites: currentTab == 2,
      path: path,
      offset: listing.offset,
      recursive: recursive,
    );
    final existing = listing.keys.toSet();
    if (page.files.isNotEmpty &&
        page.files.every((f) => existing.contains(f.key))) {
      throw const CloudException(
        'The server repeated a page. Pull to refresh your library.',
      );
    }
    return (files: page.files, days: <int>[], scanned: page.scanned);
  }

  Future<void> _fetchPage(
    _MediaListing listing,
    Account session,
    int currentTab,
    List<String> path,
  ) async {
    _mergePage(listing, await _nextPage(listing, session, currentTab, path));
  }

  void _mergePage(_MediaListing listing, _Page page) {
    listing.add(fileStore, page.files);
    if (listing.days case final days?) {
      listing.loaded.addAll(page.days);
      listing.more = days.any((d) => !listing.loaded.contains(d.id));
    } else {
      listing.offset += page.scanned;
      listing.more = page.scanned == NextcloudClient.photoLimit;
    }
  }

  Future<void> _publishListing(_MediaListing listing, String? key) async {
    listing.pruneEvicted(fileStore);
    _activeListing = listing;
    items = fileStore.resolve(listing.keys);
    hasMore = listing.more;
    if (tab == 0) _libraryFiles = items;
    if (tab == 0) _queueThumbnailWarmup(items);
    if (key != null) {
      _listings[key] = listing;
      if (_listings.length > 20) _listings.remove(_listings.keys.first);
      _persistStore();
      await cache?.writeDocument(key, listing.toJson());
    }
  }

  Future<void> loadNextPage() async {
    final listing = _activeListing;
    final session = account;
    if (listing == null ||
        session == null ||
        !listing.more ||
        loading ||
        loadingMore ||
        busy ||
        error != null) {
      return;
    }
    final version = _loadVersion;
    final currentTab = tab;
    final path = [...directory];
    final key = _listingKey();
    loadingMore = true;
    notifyListeners();
    try {
      final page = await _nextPage(listing, session, currentTab, path);
      if (version != _loadVersion || _disposed) return;
      _mergePage(listing, page);
      await _publishListing(listing, key);
    } catch (e) {
      if (version == _loadVersion) error = errorMessage(e);
    } finally {
      if (version == _loadVersion) {
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  /// Whether the photos of an indexed day are already in the current view.
  bool dayLoaded(int day) => _activeListing?.loaded.contains(day) ?? true;

  /// Loads specific indexed days, such as those the timeline scrolled or was
  /// scrubbed to. The most recently requested days load first and requests
  /// left far behind by a fast scrub are dropped.
  ({List<MemoryDay> days, Set<int> changed, int added})? _timelineChanges;
  bool _checkingChanges = false;

  /// True when the server's Timeline differs from what is on screen.
  bool get timelineChanged => _timelineChanges != null;

  /// Photos added on the server since the Timeline was shown.
  int get newPhotos => _timelineChanges?.added ?? 0;

  /// Compares the server's day index with the one on screen. One small
  /// request; nothing is downloaded unless a day's count changed.
  Future<bool> checkForChanges() async {
    final listing = _activeListing;
    final session = account;
    final shown = listing?.days;
    if (_checkingChanges ||
        demo ||
        session == null ||
        shown == null ||
        tab != 0 ||
        activeNativeAlbum != null ||
        loading) {
      return false;
    }
    _checkingChanges = true;
    try {
      final path = [...directory];
      final days = await client.memoryDays(
        session,
        path: path,
        recursive: _recursiveMedia(0, path),
      );
      if (days == null || !identical(listing, _activeListing)) return false;
      final before = {for (final day in shown) day.id: day.count};
      final after = {for (final day in days) day.id: day.count};
      final changed = {
        for (final id in {...before.keys, ...after.keys})
          if (before[id] != after[id]) id,
      };
      if (changed.isEmpty) return false;
      int total(Map<int, int> counts) => counts.values.fold(0, (a, b) => a + b);
      _timelineChanges = (
        days: days,
        changed: changed,
        added: math.max(0, total(after) - total(before)),
      );
      notifyListeners();
      return true;
    } on Object {
      return false;
    } finally {
      _checkingChanges = false;
    }
  }

  /// Shows the changes found by [checkForChanges], reloading only the
  /// affected days that were already on screen.
  void applyChanges() {
    final changes = _timelineChanges;
    final listing = _activeListing;
    _timelineChanges = null;
    if (changes == null || listing == null || listing.days == null) {
      notifyListeners();
      return;
    }
    final reload = changes.changed.where(listing.loaded.contains).toList();
    listing.loaded.removeAll(changes.changed);
    listing.replace(const {}, {
      for (final key in listing.keys)
        if (changes.changed.contains(fileStore[key]?.captureDay)) key,
    });
    listing.days = changes.days;
    listing.more = changes.days.any((d) => !listing.loaded.contains(d.id));
    listing.updated = DateTime.now();
    unawaited(_publishListing(listing, _listingKey()));
    notifyListeners();
    final present = {for (final day in changes.days) day.id};
    ensureDays(reload.where(present.contains));
  }

  void ensureDays(Iterable<int> days) {
    final listing = _activeListing;
    if (listing?.days == null || account == null) return;
    for (final day in days) {
      if (listing!.loaded.contains(day)) continue;
      _pendingDays
        ..remove(day)
        ..add(day);
    }
    while (_pendingDays.length > 60) {
      _pendingDays.remove(_pendingDays.first);
    }
    if (!_fetchingDays && _pendingDays.isNotEmpty) unawaited(_drainDays());
  }

  Future<void> _drainDays() async {
    _fetchingDays = true;
    fetchingDays = true;
    notifyListeners();
    try {
      while (_pendingDays.isNotEmpty && !_disposed) {
        final listing = _activeListing;
        final session = account;
        final days = listing?.days;
        if (listing == null || session == null || days == null) break;
        final counts = {for (final day in days) day.id: day.count};
        final batch = <int>[];
        var count = 0;
        final limit = _dayBatchLimit(tab);
        for (final day in _pendingDays.toList().reversed) {
          final size = counts[day];
          if (size == null || listing.loaded.contains(day)) {
            _pendingDays.remove(day);
            continue;
          }
          if (batch.isNotEmpty && count + size > limit) break;
          batch.add(day);
          count += size;
        }
        _pendingDays.removeAll(batch);
        if (batch.isEmpty) continue;
        final version = _loadVersion;
        final currentTab = tab;
        final path = [...directory];
        final key = _listingKey();
        final files = await client.memoryDayFiles(
          session,
          batch,
          path: path,
          favorites: currentTab == 2,
          recursive: _recursiveMedia(currentTab, path),
          resolvePaths: !_pathless(currentTab),
        );
        if (version != _loadVersion ||
            _disposed ||
            !identical(_activeListing, listing)) {
          continue;
        }
        _mergePage(listing, (files: files, days: batch, scanned: files.length));
        await _publishListing(listing, key);
        notifyListeners();
      }
    } catch (e) {
      error ??= errorMessage(e);
      _pendingDays.clear();
    } finally {
      _fetchingDays = false;
      fetchingDays = false;
      notifyListeners();
    }
  }

  String? _listingKey() {
    final session = account;
    if (demo || session == null || tab == 3) return null;
    return 'browse-v4|${session.server}|${session.userId}|$tab|$smartAlbumOpen|'
        '${directory.join('/')}|${activeNativeAlbum?.davPath.join('/') ?? ''}';
  }

  Future<void> _prepareAlbums({bool refresh = false}) async {
    final session = account;
    if (demo || session == null || _disposed) return;
    final pending = _catalogueTask;
    if (pending != null && _catalogueSession == session) return pending;
    final generation = _catalogueVersion + 1;
    final task = () async {
      try {
        await _loadCatalogue(session, refresh: refresh);
      } catch (e) {
        if (account == session &&
            generation == _catalogueVersion &&
            !_disposed) {
          catalogueError = errorMessage(e);
          notifyListeners();
        }
      }
    }();
    _catalogueTask = task;
    _catalogueSession = session;
    try {
      await task;
    } finally {
      if (identical(_catalogueTask, task)) _catalogueTask = null;
    }
  }

  Future<void> _prepareSharedAlbums({required bool refresh}) async {
    final pending = _sharedAlbumsTask;
    if (pending != null) return pending;
    final session = account!;
    final generation = ++_sharedAlbumsVersion;
    final task = () async {
      final key = 'incoming-albums-v1|${session.server}|${session.userId}';
      sharedAlbumError = null;
      loadingSharedAlbums = true;
      notifyListeners();
      try {
        if (_sharedAlbumsUpdated == null) {
          final saved = await cache?.readDocument(key);
          if (account != session ||
              generation != _sharedAlbumsVersion ||
              _disposed) {
            return;
          }
          if (saved != null) {
            sharedAlbums
              ..clear()
              ..addAll(
                (saved['albums'] as List).map(
                  (a) =>
                      SmartAlbum.fromJson((a as Map).cast<String, dynamic>()),
                ),
              );
            _sharedAlbumsUpdated = DateTime.parse(saved['updated'] as String);
            notifyListeners();
          }
        }
        if (!refresh &&
            _sharedAlbumsUpdated != null &&
            DateTime.now().difference(_sharedAlbumsUpdated!) <
                const Duration(minutes: 15)) {
          return;
        }
        final folders = await client.incomingSharedFolders(session);
        final found = <SmartAlbum>[];
        for (final path in folders) {
          if (account != session ||
              generation != _sharedAlbumsVersion ||
              _disposed) {
            return;
          }
          final covers = await client.search(session, path: path, limit: 1);
          if (covers.isNotEmpty) {
            found.add(SmartAlbum(path: path, files: covers));
          }
        }
        if (account != session ||
            generation != _sharedAlbumsVersion ||
            _disposed) {
          return;
        }
        found.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        sharedAlbums
          ..clear()
          ..addAll(found);
        _sharedAlbumsUpdated = DateTime.now();
        notifyListeners();
        await cache?.writeDocument(key, {
          'updated': _sharedAlbumsUpdated!.toIso8601String(),
          'albums': sharedAlbums.map((a) => a.toJson()).toList(),
        });
      } catch (e) {
        if (account == session &&
            generation == _sharedAlbumsVersion &&
            !_disposed) {
          sharedAlbumError = errorMessage(e);
          notifyListeners();
        }
      }
    }();
    _sharedAlbumsTask = task;
    try {
      await task;
    } finally {
      if (identical(_sharedAlbumsTask, task)) {
        _sharedAlbumsTask = null;
        loadingSharedAlbums = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadCatalogue(Account session, {required bool refresh}) async {
    final generation = ++_catalogueVersion;
    if (session.photoRoot == null && _autoPhotoRoot == null) {
      final sourceKey = 'album-source|${session.server}|${session.userId}';
      final saved = await cache?.readDocument(sourceKey);
      if (account != session || generation != _catalogueVersion || _disposed) {
        return;
      }
      if (saved != null) {
        _autoPhotoRoot = (saved['path'] as List).cast<String>();
      } else {
        final roots = await _listFolder(session, []);
        if (account != session ||
            generation != _catalogueVersion ||
            _disposed) {
          return;
        }
        _autoPhotoRoot = roots.any((f) => f.isDirectory && f.name == 'Photos')
            ? ['Photos']
            : [];
        await cache?.writeDocument(sourceKey, {'path': _autoPhotoRoot});
      }
    }
    if (account != session || generation != _catalogueVersion || _disposed) {
      return;
    }
    final root = [...photoRoot];
    final rootKey = '${session.server}|${session.userId}|${root.join('/')}';
    if (!refresh &&
        _catalogueRoot == rootKey &&
        _catalogueUpdated != null &&
        DateTime.now().difference(_catalogueUpdated!) <
            const Duration(minutes: 15)) {
      return;
    }
    final key = 'album-catalogue-v5|$rootKey';
    if (_catalogueRoot != rootKey) {
      _catalogue.clear();
      _catalogueUpdated = null;
      _catalogueRoot = rootKey;
      nativeAlbums = [];
    }
    if (_catalogueUpdated == null) {
      final saved = await cache?.readDocument(key);
      if (generation != _catalogueVersion || account != session) return;
      if (saved != null) {
        _catalogue.clear();
        _catalogue.addAll(
          (saved['albums'] as List).map(
            (value) =>
                SmartAlbum.fromJson((value as Map).cast<String, dynamic>()),
          ),
        );
        if (saved['native'] case final List native) {
          nativeAlbums = native.map((value) {
            final item = (value as Map).cast<String, dynamic>();
            return NativeAlbum(
              name: item['name'] as String,
              davPath: (item['path'] as List).cast<String>(),
              count: item['count'] as int,
              coverId: item['coverId'] as String?,
              shared: item['shared'] as bool,
            );
          }).toList();
        }
        notifyListeners();
        final updated = DateTime.tryParse(saved['updated'] as String? ?? '');
        if (!refresh &&
            updated != null &&
            DateTime.now().difference(updated) < const Duration(minutes: 15)) {
          _catalogueUpdated = updated;
          if (saved['native'] == null) {
            await _loadNativeAlbums(session, generation);
          }
          return;
        }
      }
    }
    discoveringAlbums = true;
    catalogueError = null;
    discoveredFolders = 0;
    final nativeLoad = _loadNativeAlbums(session, generation);
    notifyListeners();
    try {
      await _ensureMemories(session);
      if (generation != _catalogueVersion || account != session) return;
      final queue = <MemoryFolder>[MemoryFolder(root, [])];
      final found = <String, SmartAlbum>{};
      while (queue.isNotEmpty) {
        if (generation != _catalogueVersion ||
            account != session ||
            _disposed) {
          return;
        }
        final folder = queue.removeAt(0);
        // The first folder with its own media on each branch is an album
        // (including everything below it); folders that only group other
        // folders are walked through. Loose media at the source root never
        // hides the albums inside it.
        final atRoot = folder.path.length == root.length;
        List<MemoryFolder> children;
        List<CloudFile> covers;
        if (memoriesAvailable == true) {
          final direct = await client.memoryDays(
            session,
            path: folder.path,
            recursive: false,
            existenceOnly: true,
          );
          covers = direct!.isEmpty
              ? []
              : folder.previews.isNotEmpty
              ? folder.previews
              : await client.memoryCover(session, folder.path, direct.first.id);
          children = direct.isEmpty || atRoot
              ? await client.memoryFolders(session, folder.path)
              : [];
        } else {
          final contents = await _listFolder(session, folder.path);
          covers = contents.where((f) => f.isMedia).take(1).toList();
          children = covers.isNotEmpty && !atRoot
              ? []
              : contents
                    .where((f) => f.isDirectory)
                    .map((f) => MemoryFolder(f.path, []))
                    .toList();
        }
        if (generation != _catalogueVersion ||
            account != session ||
            _disposed) {
          return;
        }
        if (covers.isNotEmpty) {
          final album = SmartAlbum(path: folder.path, files: covers);
          found[album.key] = album;
        }
        if (children.isNotEmpty) {
          queue.addAll(
            memoriesAvailable == true
                ? children.where((f) => f.previews.isNotEmpty)
                : children,
          );
        }
        discoveredFolders++;
      }
      _catalogue
        ..clear()
        ..addAll(found.values);
      _catalogueUpdated = DateTime.now();
      notifyListeners();
      await nativeLoad;
      if (generation != _catalogueVersion || account != session || _disposed) {
        return;
      }
      await cache?.writeDocument(key, {
        'updated': _catalogueUpdated!.toIso8601String(),
        'albums': _catalogue.map((a) => a.toJson()).toList(),
        'native': [
          for (final album in nativeAlbums)
            {
              'name': album.name,
              'path': album.davPath,
              'count': album.count,
              'coverId': album.coverId,
              'shared': album.shared,
            },
        ],
      });
    } catch (e) {
      if (generation == _catalogueVersion && account == session && !_disposed) {
        catalogueError = errorMessage(e);
      }
      rethrow;
    } finally {
      if (generation == _catalogueVersion) {
        discoveringAlbums = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadNativeAlbums(Account session, int generation) async {
    nativeAlbumError = null;
    try {
      final own = await client.albums(session);
      final shared = await client.albums(session, shared: true);
      if (account == session && generation == _catalogueVersion && !_disposed) {
        nativeAlbums = [...own, ...shared];
      }
    } catch (e) {
      if (account == session && generation == _catalogueVersion && !_disposed) {
        nativeAlbumError =
            'Could not load Nextcloud albums. ${errorMessage(e)}';
      }
    } finally {
      if (account == session && generation == _catalogueVersion && !_disposed) {
        notifyListeners();
      }
    }
  }

  /// After a change, every view keeps showing its (already patched) files
  /// from the shared store and quietly revalidates when next shown.
  Future<void> _invalidateBrowse() async {
    fileStore.markStale();
    if (_activeListing case final listing?) {
      items = fileStore.resolve(listing.keys);
      if (tab == 0) _libraryFiles = items;
    }
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    if (_catalogueUpdated != null) _catalogueUpdated = epoch;
    _catalogueVersion++;
    _catalogueTask = null;
    _catalogueSession = null;
    if (_sharedAlbumsUpdated != null) _sharedAlbumsUpdated = epoch;
    _sharedAlbumsVersion++;
    _sharedAlbumsTask = null;
    loadingSharedAlbums = false;
    discoveringAlbums = false;
    _initialDays = null;
    notifyListeners();
    _persistStore();
  }

  Future<List<CloudFile>> folderContents(List<String> path) async {
    if (demo) {
      return _demo
          .where(
            (f) =>
                f.path.length == path.length + 1 &&
                pathStartsWith(f.path, path),
          )
          .toList();
    }
    return _listFolder(account!, path);
  }

  Future<CloudFile?> albumCover(CloudFile folder) => _covers.putIfAbsent(
    folder.key,
    () async {
      if (demo) {
        return _demo
            .where((f) => f.isMedia && pathStartsWith(f.path, folder.path))
            .firstOrNull;
      }
      final known = fileStore
          .where((f) => f.isMedia && pathStartsWith(f.path, folder.path))
          .firstOrNull;
      if (known != null) return known;
      final found = await client.search(account!, path: folder.path, limit: 1);
      return found.firstOrNull;
    },
  );

  Future<bool> organize(
    List<CloudFile> files,
    String operation, {
    List<String>? destination,
    String? newName,
    bool favorite = true,
  }) async {
    if (busy || files.isEmpty) return false;
    busy = true;
    error = null;
    notice = null;
    completed = 0;
    total = files.length;
    notifyListeners();
    Object? failure;
    try {
      files = await _resolveAll(files);
      for (final file in files) {
        if (file.readOnly) {
          throw const CloudException(
            'This album item is view-only. Manage its original in Nextcloud.',
          );
        }
        final target = [...?destination, newName ?? file.name];
        if (operation == 'move' ||
            operation == 'copy' ||
            operation == 'rename') {
          if (operation == 'rename') {
            target.clear();
            target.addAll([...file.path.take(file.path.length - 1), newName!]);
          }
          validateName(target.last);
          if (file.isDirectory && pathStartsWith(target, file.path)) {
            throw const CloudException(
              'A folder cannot be placed inside itself.',
            );
          }
          if (demo) {
            if (_demo.any((f) => listEquals(f.path, target))) {
              throw const CloudException(
                'An item with that name already exists.',
              );
            }
            final affected = _demo
                .where((f) => pathStartsWith(f.path, file.path))
                .toList();
            final moved = affected
                .map(
                  (f) =>
                      f.atPath([...target, ...f.path.skip(file.path.length)]),
                )
                .toList();
            if (operation != 'copy') {
              _demo.removeWhere((f) => pathStartsWith(f.path, file.path));
            }
            _demo.addAll(moved);
          } else {
            await client.transfer(
              account!,
              file,
              target,
              copy: operation == 'copy',
            );
            fileStore.moveTree(file.path, target, copy: operation == 'copy');
          }
        } else if (operation == 'delete') {
          if (demo) {
            _demoTrash['${file.key}:${DateTime.now().microsecondsSinceEpoch}'] =
                _demo.where((f) => pathStartsWith(f.path, file.path)).toList();
            _demo.removeWhere((f) => pathStartsWith(f.path, file.path));
          } else {
            await client.delete(account!, file);
            fileStore.removeTree(file.path);
          }
        } else if (operation == 'favorite') {
          if (demo) {
            _demo = _demo
                .map((f) => f.key == file.key ? f.withFavorite(favorite) : f)
                .toList();
          } else {
            await client.setFavorite(account!, file, favorite);
            fileStore.update(file.key, (f) => f.withFavorite(favorite));
          }
        } else {
          throw const CloudException('This action is not supported.');
        }
        completed++;
        notifyListeners();
      }
    } catch (e) {
      failure = e;
    }
    _covers.clear();
    await _invalidateBrowse();
    await load();
    if (failure != null) {
      error = '$completed of $total completed. ${errorMessage(failure)}';
    } else {
      notice = '$completed ${completed == 1 ? 'item' : 'items'} updated';
    }
    busy = false;
    notifyListeners();
    return failure == null;
  }

  Future<List<TrashEntry>> trash() async {
    if (!demo) return client.trash(account!);
    return _demoTrash.entries
        .map(
          (entry) => TrashEntry(
            key: entry.key,
            name: entry.value.first.name,
            originalPath: entry.value.first.path.join('/'),
            deleted: DateTime.now(),
          ),
        )
        .toList();
  }

  Future<void> restore(TrashEntry entry) async {
    if (busy) throw const CloudException('Wait for the current operation.');
    busy = true;
    notifyListeners();
    try {
      if (demo) {
        final files = _demoTrash[entry.key]!;
        if (_demo.any((f) => f.key == files.first.key)) {
          throw const CloudException(
            'An item already exists at the original location.',
          );
        }
        _demo.addAll(files);
        _demoTrash.remove(entry.key);
      } else {
        await client.restore(account!, entry);
      }
      _covers.clear();
      await _invalidateBrowse();
      await load();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> _action(Future<void> Function() action, String success) async {
    if (busy) return;
    busy = true;
    total = 0;
    completed = 0;
    error = null;
    notice = null;
    notifyListeners();
    try {
      await action();
      notice = success;
      await _invalidateBrowse();
      await load();
    } catch (e) {
      error = errorMessage(e);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> favorite(CloudFile file) => _action(() async {
    file = await resolve(file);
    if (demo) {
      _demo = _demo
          .map((f) => f.key == file.key ? f.withFavorite(!file.favorite) : f)
          .toList();
    } else {
      await client.setFavorite(account!, file, !file.favorite);
      fileStore.update(file.key, (f) => f.withFavorite(!file.favorite));
    }
  }, file.favorite ? 'Removed from favorites' : 'Added to favorites');

  Future<void> createFolder(String name) => _action(() async {
    validateName(name);
    if (demo) {
      final path = [...directory, name];
      if (_demo.any((f) => listEquals(f.path, path))) {
        throw const CloudException('An item with that name already exists.');
      }
      _demo.add(CloudFile(path: path, name: name, isDirectory: true));
    } else {
      await client.createFolder(account!, [...directory, name]);
      fileStore.invalidateFolder(directory);
    }
  }, 'Folder created');

  Future<void> upload(String name, Stream<List<int>> bytes, int size) =>
      _action(() async {
        if (demo) {
          throw const CloudException(
            'Connect a Nextcloud server to upload files.',
          );
        }
        await client.upload(account!, [...directory, name], bytes, size);
        fileStore.invalidateFolder(directory);
      }, 'Upload complete');

  void _clearPreviews() {
    _thumbnailWarmupTimer?.cancel();
    _thumbnailWarmupQueue.clear();
    _thumbnailWarmupKnown.clear();
    _resolvedIds.clear();
    _thumbs.clear();
    _thumbBytes = 0;
    _previewLoads.clear();
    _previewInterest.clear();
    _previewTimer?.cancel();
    _previewTimer = null;
    for (final request in _previewBatch.values) {
      request.completer.completeError(const PreviewCancelled());
    }
    _previewBatch.clear();
    _multipreviewUnavailable = false;
    _multipreviewFailures = 0;
  }

  final Map<String, CloudFile> _resolvedIds = {};

  /// Prime disk-backed thumbnails beyond the viewport in small batches.
  /// Visible tiles share these requests and still take priority in the queue.
  void _queueThumbnailWarmup(List<CloudFile> files) {
    if (cache == null || !pathlessTimeline || demo || _disposed) return;
    final today = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;
    for (final file in files) {
      if (_thumbnailWarmupKnown.length >= FileStore.maxFiles) break;
      if (!file.isMedia ||
          file.captureDay == null ||
          file.captureDay! < today - warmYears * 366) {
        continue;
      }
      final key = _previewKey(file, 384);
      if (key != null &&
          _thumbnailWarmupKnown.add('$key|${_previewVersion(file)}')) {
        _thumbnailWarmupQueue.add(file);
      }
    }
    _scheduleThumbnailWarmup();
  }

  void _scheduleThumbnailWarmup() {
    if (_disposed ||
        _warmingThumbnails ||
        _thumbnailWarmupQueue.isEmpty ||
        tab != 0) {
      return;
    }
    _thumbnailWarmupTimer?.cancel();
    _thumbnailWarmupTimer = Timer(
      const Duration(milliseconds: 250),
      _warmThumbnailBatch,
    );
  }

  Future<void> _warmThumbnailBatch() async {
    if (_disposed || tab != 0 || account == null) return;
    if (busy || loading || loadingMore || fetchingDays) {
      _scheduleThumbnailWarmup();
      return;
    }
    _warmingThumbnails = true;
    final session = account;
    final batch = _thumbnailWarmupQueue.take(48).toList();
    _thumbnailWarmupQueue.removeRange(0, batch.length);
    try {
      await Future.wait([
        for (final file in batch)
          preview(file).then<void>(
            (_) {},
            onError: (Object e) {
              const message =
                  'Some previews could not be cached. Tap them to retry.';
              if (!_disposed &&
                  account == session &&
                  e is! PreviewCancelled &&
                  notice != message) {
                notice = message;
                notifyListeners();
              }
            },
          ),
      ]);
    } finally {
      _warmingThumbnails = false;
      if (!_disposed && account == session) _scheduleThumbnailWarmup();
    }
  }

  void _applyResolved(List<String> ids, Map<String, CloudFile> found) {
    final renamed = <String, String>{};
    final gone = <String>{};
    final resolved = <CloudFile>[];
    for (final id in ids) {
      final key = CloudFile(
        path: [CloudFile.pendingRoot, id],
        name: id,
        isDirectory: false,
      ).key;
      final placeholder = fileStore[key];
      final real = found[id];
      if (real == null) {
        gone.add(key);
        continue;
      }
      if (placeholder == null) {
        // Already swapped by an on-demand [resolve]; keep its timeline date.
        _resolvedIds[id] ??= real;
        continue;
      }
      final day = placeholder.captureDay;
      final file = day != null
          ? real.withCaptureDate(
              placeholder.taken ?? real.modified ?? DateTime.now(),
              placeholder.etag ?? real.etag,
              day: day,
            )
          : real;
      _resolvedIds[id] = file;
      resolved.add(file);
      renamed[key] = file.key;
    }
    fileStore.putAll(resolved);
    var changed = false;
    for (final listing in {..._listings.values, ?_activeListing}) {
      if (listing.replace(renamed, gone)) changed = true;
    }
    fileStore.removeKeys({...renamed.keys, ...gone});
    if (!changed) return;
    if (_activeListing case final listing?) {
      items = fileStore.resolve(listing.keys);
      if (tab == 0) _libraryFiles = items;
    }
    _persistStore();
    notifyListeners();
  }

  /// Real WebDAV location of [file]; actions call this before touching paths.
  Future<CloudFile> resolve(CloudFile file) async {
    if (!file.pending) return file;
    final id = file.id!;
    if (_resolvedIds[id] case final known?) return known;
    final session = account;
    if (session == null) {
      throw const CloudException('Sign in again to open this item.');
    }
    final found = await client.resolveFileIds(session, [id]);
    _applyResolved([id], found);
    return _resolvedIds[id] ??
        (throw const CloudException('This item is no longer available.'));
  }

  Future<List<CloudFile>> _resolveAll(List<CloudFile> files) async {
    if (!files.any((f) => f.pending)) return files;
    return [for (final file in files) await resolve(file)];
  }

  String? _previewKey(CloudFile file, int size) {
    final session = account;
    if (session == null) return null;
    return '${session.server}|${session.userId}|${file.id ?? file.key}|$size';
  }

  static String _previewVersion(CloudFile file) {
    final etag = (file.etag ?? '').replaceAll('"', '');
    return etag.isNotEmpty
        ? etag
        : '${file.modified?.microsecondsSinceEpoch}|${file.size}';
  }

  void _rememberPreview(String key, Uint8List bytes, String version) {
    final old = _thumbs.remove(key);
    if (old != null) _thumbBytes -= old.bytes.length;
    _thumbs[key] = (bytes: bytes, version: version);
    _thumbBytes += bytes.length;
    while ((_thumbBytes > thumbnailMemoryBudget || _thumbs.length > 4000) &&
        _thumbs.length > 1) {
      final oldest = _thumbs.keys.first;
      _thumbBytes -= _thumbs.remove(oldest)!.bytes.length;
    }
  }

  /// Thumbnail already in memory, possibly from an older file revision, so
  /// tiles can paint on their first frame without a loading state.
  Uint8List? cachedPreview(CloudFile file, {int size = 384}) {
    final key = _previewKey(file, size);
    final entry = key == null ? null : _thumbs.remove(key);
    if (entry == null) return null;
    _thumbs[key!] = entry;
    return entry.bytes;
  }

  /// Whether [cachedPreview] matches the file's current revision.
  bool previewCurrent(CloudFile file, {int size = 384}) {
    final key = _previewKey(file, size);
    return key != null && _thumbs[key]?.version == _previewVersion(file);
  }

  /// Current thumbnail for [file]: memory, then disk, then the server.
  /// A cached thumbnail of an older revision is handed to [stale] at once
  /// while the new one downloads. Callers must [releasePreview] if they stop
  /// waiting, so requests for tiles scrolled away are dropped.
  Future<Uint8List> preview(
    CloudFile file, {
    bool retry = false,
    int size = 384,
    void Function(Uint8List bytes)? stale,
  }) {
    final session = account;
    final key = _previewKey(file, size);
    if (session == null || key == null) {
      return Future.error(const CloudException('Reconnect to load previews.'));
    }
    final version = _previewVersion(file);
    final memory = _thumbs[key];
    if (!retry && memory?.version == version) {
      cachedPreview(file, size: size);
      return Future.value(memory!.bytes);
    }
    final loadKey = '$key|$version';
    _previewInterest[loadKey] = (_previewInterest[loadKey] ?? 0) + 1;
    final existing = _previewLoads[loadKey];
    if (existing != null && !retry) return existing;
    final disk = cache;
    Future<Uint8List> load() async {
      if (!retry && disk != null) {
        final stored = await disk.readThumbnail(key);
        if (stored != null) {
          if (stored.version == version) {
            _rememberPreview(key, stored.bytes, version);
            return stored.bytes;
          }
          if (memory == null) stale?.call(stored.bytes);
        }
      }
      final bytes = await _fetchPreview(session, file, size, loadKey);
      if (identical(account, session)) {
        _rememberPreview(key, bytes, version);
        unawaited(disk?.writeThumbnail(key, bytes, version: version));
      }
      return bytes;
    }

    late final Future<Uint8List> pending;
    pending = load().whenComplete(() {
      if (identical(_previewLoads[loadKey], pending)) {
        _previewLoads.remove(loadKey);
        _previewInterest.remove(loadKey);
      }
    });
    _previewLoads[loadKey] = pending;
    return pending;
  }

  /// A tile no longer needs [file]'s thumbnail.
  void releasePreview(CloudFile file, {int size = 384}) {
    final key = _previewKey(file, size);
    if (key == null) return;
    final loadKey = '$key|${_previewVersion(file)}';
    final interest = (_previewInterest[loadKey] ?? 0) - 1;
    if (interest > 0) {
      _previewInterest[loadKey] = interest;
    } else {
      _previewInterest.remove(loadKey);
    }
  }

  Future<Uint8List> _fetchPreview(
    Account session,
    CloudFile file,
    int size,
    String loadKey,
  ) {
    if (file.id == null ||
        memoriesAvailable != true ||
        _multipreviewUnavailable ||
        size > 512) {
      return client.preview(session, file, size: size);
    }
    final batchKey = '${file.id}|$size';
    final queued = _previewBatch.remove(batchKey);
    final request =
        queued ?? _PreviewRequest(file, size, loadKey, Completer<Uint8List>());
    // Re-inserting keeps the most recently wanted thumbnails last.
    _previewBatch[batchKey] = request;
    _previewTimer ??= Timer(
      const Duration(milliseconds: 12),
      () => _flushPreviews(session),
    );
    return request.completer.future;
  }

  /// Sends queued thumbnails as Memories multipreview batches, newest
  /// requests (tiles currently on screen) first.
  void _flushPreviews(Account session) {
    _previewTimer = null;
    if (!identical(account, session)) return;
    while (_previewBatch.isNotEmpty && _previewBatches < 3) {
      final batch = <_PreviewRequest>[];
      for (final key in _previewBatch.keys.toList().reversed) {
        final request = _previewBatch[key]!;
        if (batch.isNotEmpty && request.size != batch.first.size) continue;
        _previewBatch.remove(key);
        if ((_previewInterest[request.loadKey] ?? 0) <= 0) {
          request.completer.completeError(const PreviewCancelled());
          continue;
        }
        batch.add(request);
        if (batch.length == 48) break;
      }
      if (batch.isEmpty) continue;
      _previewBatches++;
      unawaited(_sendPreviews(session, batch));
    }
  }

  Future<void> _sendPreviews(
    Account session,
    List<_PreviewRequest> batch,
  ) async {
    void single(_PreviewRequest request) => request.completer.complete(
      client.preview(session, request.file, size: request.size),
    );
    try {
      if (batch.length == 1) {
        single(batch.single);
        return;
      }
      final previews = await client.multipreview(session, [
        for (final request in batch) request.file.id!,
      ], size: batch.first.size);
      _multipreviewFailures = 0;
      for (final request in batch) {
        final bytes = previews[request.file.id];
        if (bytes != null) {
          request.completer.complete(bytes);
        } else {
          single(request);
        }
      }
    } on Object {
      // Older Memories versions or proxies may not support batching.
      if (++_multipreviewFailures >= 2) _multipreviewUnavailable = true;
      for (final request in batch) {
        if (!request.completer.isCompleted) single(request);
      }
    } finally {
      _previewBatches--;
      if (_previewBatch.isNotEmpty) {
        _previewTimer ??= Timer(Duration.zero, () => _flushPreviews(session));
      }
    }
  }

  /// Previously saved original for offline replay, if any.
  Future<File?> offlineCopy(CloudFile file) async {
    final session = account;
    if (cache == null || session == null) return null;
    if (file.pending) {
      // Never block a tile on a path lookup; unresolved items have no copy.
      final known = _resolvedIds[file.id];
      if (known == null) return null;
      file = known;
    }
    final copy = await cache!.original(_originalKey(session, file), file.name);
    return await copy.exists() ? copy : null;
  }

  String _originalKey(Account session, CloudFile file) =>
      'original|${session.server}|${session.userId}|${file.id ?? file.key}|'
      '${file.modified?.microsecondsSinceEpoch}|${file.size}';

  /// Direct authenticated WebDAV stream for the platform video player.
  ({Uri uri, Map<String, String> headers})? streamSource(CloudFile file) {
    final session = account;
    if (demo || session == null) return null;
    return (
      uri: client.fileUri(session, file),
      headers: {'Authorization': session.authorization},
    );
  }

  /// Keeps a full copy of [file] in the cache so it replays without network.
  Future<File> saveOffline(CloudFile file) async {
    final session = account;
    if (cache == null || session == null) {
      throw const CloudException('Offline copies need a connected server.');
    }
    file = await resolve(file);
    final target = await cache!.original(
      _originalKey(session, file),
      file.name,
    );
    if (!await target.exists()) {
      final downloaded = await download(file);
      try {
        await downloaded.copy(target.path);
      } finally {
        await downloaded.parent.delete(recursive: true);
      }
    }
    final saved = await cache!.readListing(_offlineListingKey) ?? [];
    await cache!.writeListing(_offlineListingKey, [
      ...saved.where((f) => f.key != file.key),
      file,
    ]);
    unawaited(cache!.trim());
    return target;
  }

  String get _offlineListingKey =>
      'offline|${account?.server}|${account?.userId}';

  Future<int> cacheSize() async => await cache?.size() ?? 0;

  Future<void> clearCache() async {
    _clearPreviews();
    _covers.clear();
    await _invalidateBrowse();
    _listings.clear();
    fileStore.clear();
    _activeListing = null;
    hasMore = false;
    await _storeWrite;
    await cache?.clear();
    notifyListeners();
  }

  Future<File> download(CloudFile file) async {
    if (demo) {
      throw const CloudException(
        'Demo files are illustrations. Connect a server to download.',
      );
    }
    if (busy) {
      throw const CloudException('Wait for the current transfer to finish.');
    }
    busy = true;
    total = 0;
    completed = 0;
    notifyListeners();
    File? output;
    try {
      file = await resolve(file);
      final folder = Directory(
        '${(await getTemporaryDirectory()).path}/ncloud-downloads',
      );
      await folder.create(recursive: true);
      validateName(file.name);
      final response = await client.download(account!, file);
      // Separate each transfer so identical filenames never collide.
      final transfer = await folder.createTemp('transfer-');
      output = File('${transfer.path}/${file.name}');
      final sink = output.openWrite();
      try {
        await sink.addStream(
          response.stream.timeout(const Duration(seconds: 45)),
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
      return output;
    } catch (_) {
      if (output != null && await output.exists()) await output.delete();
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _warmTimer?.cancel();
    _thumbnailWarmupTimer?.cancel();
    _catalogueVersion++;
    _sharedAlbumsVersion++;
    _loadVersion++;
    _loginVersion++;
    client.close();
    super.dispose();
  }
}

/// A view's ordered references into the shared [FileStore] plus its paging
/// state; files themselves are never duplicated per view.
class _MediaListing {
  List<String> keys = [];
  final Set<String> _known = {};
  List<MemoryDay>? days;
  final Set<int> loaded = {};
  int offset = 0;
  bool more = false;
  DateTime updated = DateTime.now();

  bool fresh(FileStore store) =>
      !updated.isBefore(store.staleBefore) &&
      DateTime.now().difference(updated) < const Duration(minutes: 5);

  void add(FileStore store, List<CloudFile> files) {
    store.putAll(files);
    for (final file in files) {
      if (_known.add(file.key)) keys.add(file.key);
    }
  }

  /// Eviction must not leave a day marked as loaded with missing photo rows.
  void pruneEvicted(FileStore store) {
    final missing = keys.where((key) => store[key] == null).toSet();
    if (missing.isEmpty) return;
    keys.removeWhere(missing.contains);
    _known.removeAll(missing);
    final counts = <int, int>{};
    for (final key in keys) {
      final day = store[key]?.captureDay;
      if (day != null) counts[day] = (counts[day] ?? 0) + 1;
    }
    for (final day in days ?? <MemoryDay>[]) {
      if (counts[day.id] != day.count) loaded.remove(day.id);
    }
    if (days case final days?) {
      more = days.any((day) => !loaded.contains(day.id));
    }
  }

  /// Swaps placeholder keys for resolved files, dropping any in [gone].
  bool replace(Map<String, String> renamed, Set<String> gone) {
    if (!keys.any((k) => renamed.containsKey(k) || gone.contains(k))) {
      return false;
    }
    final next = <String>[];
    _known.clear();
    for (final key in keys) {
      if (gone.contains(key)) continue;
      final value = renamed[key] ?? key;
      if (_known.add(value)) next.add(value);
    }
    keys = next;
    return true;
  }

  Map<String, dynamic> toJson() => {
    'keys': keys,
    'days': days?.map((d) => d.toJson()).toList(),
    'loaded': loaded.toList(),
    'offset': offset,
    'more': more,
    'updated': updated.toIso8601String(),
  };

  static _MediaListing fromJson(Map<String, dynamic> value) {
    final listing = _MediaListing()
      ..days = (value['days'] as List?)
          ?.map((d) => MemoryDay.fromJson((d as Map).cast<String, dynamic>()))
          .toList()
      ..offset = value['offset'] as int
      ..more = value['more'] as bool
      ..updated = DateTime.parse(value['updated'] as String);
    listing.keys = (value['keys'] as List).cast<String>();
    listing._known.addAll(listing.keys);
    listing.loaded.addAll((value['loaded'] as List).cast<int>());
    return listing;
  }
}

class _PreviewRequest {
  _PreviewRequest(this.file, this.size, this.loadKey, this.completer);
  final CloudFile file;
  final int size;
  final String loadKey;
  final Completer<Uint8List> completer;
}

/// A thumbnail request dropped because no tile is waiting for it anymore.
class PreviewCancelled implements Exception {
  const PreviewCancelled();
}
