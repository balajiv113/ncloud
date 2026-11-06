import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'demo.dart';
import 'diagnostics.dart';
import 'discovery_models.dart';
import 'file_store.dart';
import 'folder_sync.dart';
import 'local_cache.dart';
import 'models.dart';
import 'media_listing.dart';
import 'cloud_backend.dart';

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

String errorMessage(Object error) {
  Diagnostics.session.record(error);
  return switch (error) {
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
}

class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.client,
    this.cache,
    this.pathlessTimeline = false,
    FolderSyncController? folderSyncController,
  }) {
    _folderSync = folderSyncController;
    cache?.onWriteError = (message) {
      if (_disposed || notice == message) return;
      notice = message;
      notifyListeners();
    };
  }

  /// Paints the Timeline straight from indexed day rows and resolves real paths
  /// only when an action needs them.
  final bool pathlessTimeline;

  final SessionStore store;
  final CloudBackend client;

  /// Optional persistent cache; tests run purely in memory without it.
  final LocalCache? cache;
  FolderSyncController? _folderSync;
  FolderSyncController get folderSync => _folderSync ??= FolderSyncController(
    client: client,
    account: () => demo ? null : account,
  );

  void setSyncForeground(bool active) {
    _folderSync?.setForeground(active);
    if (active &&
        connected &&
        !demo &&
        (Platform.isAndroid || Platform.isIOS)) {
      unawaited(folderSync.load());
    }
  }

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
  final Map<String, MediaListing> _listings = {};

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
  MediaListing? _activeListing;
  String? _visibleListingKey;
  bool? timelineIndexAvailable;
  bool discoveringAlbums = false;
  int discoveredFolders = 0;
  final List<SmartAlbum> _catalogue = [];
  DateTime? _catalogueUpdated;
  String? _catalogueRoot;
  List<TimelineDay>? _initialDays;
  Future<void>? _detectingTimelineIndex;
  int _catalogueVersion = 0;
  Future<void>? _catalogueTask;
  Account? _catalogueSession;
  bool get albumHome =>
      tab == 4 &&
      !smartAlbumOpen &&
      activeCloudAlbum == null &&
      activePerson == null &&
      activeMapBounds == null;
  List<PhotoMapBounds>? activeMapBounds;
  List<RecognizedPerson> people = [];
  RecognizedPerson? activePerson;
  bool loadingPeople = false;
  bool? peopleAvailable;
  String? peopleError;
  DateTime? _peopleUpdated;
  Future<void>? _peopleTask;
  int _peopleVersion = 0;
  final Map<String, int> _facePreviewGenerations = {};
  List<TimelineDay> get indexedDays => _activeListing?.days ?? [];
  List<CloudFile> _libraryFiles = [];
  List<CloudAlbum> nativeAlbums = [];
  CloudAlbum? activeCloudAlbum;
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
  int _cacheGeneration = 0;
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
  int _previewGeneration = 0;
  bool _multipreviewUnavailable = false;
  int _multipreviewFailures = 0;
  Timer? _thumbnailWarmupTimer;
  final List<CloudFile> _thumbnailWarmupQueue = [];
  final Set<String> _thumbnailWarmupKnown = {};
  bool _warmingThumbnails = false;
  bool _browsingActive = true;
  Completer<void>? _loginResume;

  void setBrowsingActive(bool active) {
    _browsingActive = active;
    if (active) _wakeLogin();
    if (!active) {
      _thumbnailWarmupTimer?.cancel();
      _thumbnailWarmupTimer = null;
      _previewTimer?.cancel();
      _previewTimer = null;
      for (final request in _previewBatch.values) {
        request.completer.completeError(const PreviewCancelled());
      }
      _previewBatch.clear();
    } else {
      _scheduleThumbnailWarmup();
      if (!_fetchingDays && _pendingDays.isNotEmpty && error == null) {
        unawaited(_drainDays());
      }
    }
  }

  void reportChangeError(Object error) {
    if (_disposed) return;
    final message =
        'Live updates are delayed; using change checks. ${errorMessage(error)}';
    if (notice == message) return;
    notice = message;
    notifyListeners();
  }

  final Map<String, Future<CloudFile?>> _covers = {};
  final Map<String, List<CloudFile>> _demoTrash = {};

  bool get connected => account != null || demo;
  bool get canCancelLogin => signingIn && !_savingAccount;

  Future<void> initialize() async {
    final version = _loginVersion;
    try {
      final saved = await store.read();
      if (_disposed || version != _loginVersion) return;
      if (saved != null) account = Account.decode(saved);
    } catch (e) {
      if (!_disposed && version == _loginVersion) {
        error = 'Could not restore the saved account. ${errorMessage(e)}';
      }
    } finally {
      if (!_disposed && version == _loginVersion) {
        if (!connected) starting = false;
        notifyListeners();
      }
    }
    if (_disposed || version != _loginVersion) return;
    if (connected) {
      setSyncForeground(true);
      try {
        await cache?.readOfflineListing(_offlineListingKey);
      } catch (e) {
        notice = 'Could not restore saved offline files. ${errorMessage(e)}';
      }
      final preparation = _prepareLibrary();
      unawaited(_prepareAlbums());
      unawaited(loadPeople());
      unawaited(_prepareSharedAlbums(refresh: false));
      await preparation;
      try {
        await cache?.trim();
      } catch (e) {
        notice =
            'Could not enforce the browsing cache limit. ${errorMessage(e)}';
        notifyListeners();
      }
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
    notice = null;
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
      if (version != _loginVersion) return;
      final deadline = DateTime.now().add(const Duration(minutes: 20));
      var failures = 0;
      while (version == _loginVersion && DateTime.now().isBefore(deadline)) {
        if (!_browsingActive) {
          final resume = _loginResume ??= Completer<void>();
          await resume.future.timeout(
            deadline.difference(DateTime.now()),
            onTimeout: () {},
          );
          if (version != _loginVersion) return;
          if (!DateTime.now().isBefore(deadline)) break;
        }
        Account? result;
        try {
          result = await client.pollLogin(uri, flow);
          failures = 0;
        } on CloudException catch (e) {
          if (version != _loginVersion) return;
          // A request interrupted by leaving for browser approval must not
          // consume the foreground retry budget.
          if (!_browsingActive && e.retryable) continue;
          if (!e.retryable || ++failures >= 5) rethrow;
          notice = 'Sign-in connection interrupted. Retrying…';
          notifyListeners();
        }
        if (version != _loginVersion) return;
        if (result != null) {
          notice = null;
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
        notice = null;
        notifyListeners();
      }
    }
  }

  void cancelLogin() {
    if (_savingAccount) return;
    _loginVersion++;
    _wakeLogin();
    signingIn = false;
    notice = null;
    notifyListeners();
  }

  void _wakeLogin() {
    final pending = _loginResume;
    _loginResume = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  Future<void> _saveAccount(Account result) async {
    _savingAccount = true;
    notifyListeners();
    try {
      await store.write(result.encode());
      account = result;
      demo = false;
      setSyncForeground(true);
      tab = 0;
      directory = [];
      final preparation = _prepareLibrary();
      unawaited(_prepareAlbums());
      unawaited(loadPeople());
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

  Future<void> _prepareLibrary() async {
    final session = account!;
    final key = 'warm-v2|${session.server}|${session.userId}';
    final prepared = await cache?.readDocument(key);
    if (_disposed || account != session) return;
    final saved = await cache?.readDocument(_listingKey()!);
    if (_disposed || account != session) return;
    var cachedLibrary = false;
    if (saved != null) {
      try {
        MediaListing.fromJson(saved);
        cachedLibrary = true;
      } catch (e) {
        notice = 'The saved timeline needs rebuilding. ${errorMessage(e)}';
      }
    }
    starting = false;
    if (prepared?['complete'] == true || cachedLibrary) {
      warming = false;
      notifyListeners();
      await load(refresh: false);
      return;
    }
    warming = true;
    warmProgress = 0;
    warmPhase = 0;
    warmIndex = '';
    warmDone = warmTotal = 0;
    notifyListeners();
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
            _browsingActive &&
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
      if (active()) error ??= errorMessage(e);
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
    if (busy || _savingAccount) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _folderSync?.disconnect();
      if (!demo) {
        await store.clear();
        final cache = Directory(
          '${(await getTemporaryDirectory()).path}/ncloud-downloads',
        );
        if (await cache.exists()) await cache.delete(recursive: true);
        _storeOwner = null;
        await _storeWrite;
        await this.cache?.clearAll();
      }
      _loadVersion++;
      _loginVersion++;
      _changeOwner = null;
      _changeEtag = null;
      _lastIndexCheck = null;
      _pendingChangeHint = false;
      _pendingChangeIds = {};
      _clearPreviews();
      _covers.clear();
      _demoTrash.clear();
      _warmVersion++;
      warming = false;
      account = null;
      Diagnostics.session.clear();
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
      _catalogueEtag = null;
      _catalogueTask = null;
      _catalogueSession = null;
      sharedAlbums.clear();
      sharedAlbumError = null;
      loadingSharedAlbums = false;
      _sharedAlbumsUpdated = null;
      _sharedAlbumsTask = null;
      _sharedAlbumsVersion++;
      catalogueError = null;
      timelineIndexAvailable = null;
      _initialDays = null;
      _detectingTimelineIndex = null;
      nativeAlbums = [];
      activeCloudAlbum = null;
      activePerson = null;
      activeMapBounds = null;
      people = [];
      loadingPeople = false;
      peopleAvailable = null;
      peopleError = null;
      _peopleUpdated = null;
      _peopleTask = null;
      _peopleVersion++;
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
    activeMapBounds = null;
    tab = value;
    directory = [];
    activeCloudAlbum = null;
    activePerson = null;
    smartAlbumOpen = false;
    await load(refresh: false);
  }

  Future<void> openFolder(CloudFile folder) async {
    activeMapBounds = null;
    tab = 1;
    activeCloudAlbum = null;
    activePerson = null;
    smartAlbumOpen = false;
    directory = [...folder.path];
    await load(refresh: false);
  }

  Future<void> goTo(List<String> path) async {
    activeMapBounds = null;
    directory = [...path];
    activeCloudAlbum = null;
    activePerson = null;
    smartAlbumOpen = false;
    await load(refresh: false);
  }

  Future<void> openSmartAlbum(List<String> path) async {
    activeMapBounds = null;
    tab = 4;
    directory = [...path];
    activeCloudAlbum = null;
    activePerson = null;
    smartAlbumOpen = true;
    await load(refresh: false);
  }

  bool get albumIncludesSubfolders =>
      tab != 4 || !listEquals(directory, photoRoot);

  /// The main timeline resolves paths on demand; albums need paths for their
  /// sub-folder chips.
  bool _pathless(int currentTab) =>
      (activeMapBounds != null ||
          activePerson != null ||
          (pathlessTimeline && currentTab == 0)) &&
      activeCloudAlbum == null;

  /// Metadata-only batches are cheap, so the timeline asks for many more
  /// photos per request than views that must look up paths.
  int _dayBatchLimit(int currentTab) => _pathless(currentTab) ? 1500 : 200;

  bool _recursiveMedia(int currentTab, List<String> path) =>
      activeMapBounds != null ||
      activePerson != null ||
      currentTab != 4 ||
      !listEquals(path, photoRoot);

  Future<void> openMapArea(List<PhotoMapBounds> bounds) async {
    if (bounds.isEmpty) throw const FormatException('Choose a map area.');
    activeMapBounds = List.unmodifiable(bounds);
    activePerson = null;
    activeCloudAlbum = null;
    smartAlbumOpen = false;
    tab = 4;
    directory = [];
    await load(refresh: false);
  }

  Future<void> openPerson(RecognizedPerson person) async {
    activeMapBounds = null;
    activePerson = person;
    activeCloudAlbum = null;
    smartAlbumOpen = false;
    tab = 4;
    directory = [];
    await load(refresh: false);
  }

  Future<void> openCloudAlbum(CloudAlbum album) async {
    activeMapBounds = null;
    activePerson = null;
    activeCloudAlbum = album;
    smartAlbumOpen = false;
    tab = 4;
    directory = [];
    await load(refresh: false);
  }

  Future<void> openSharedAlbum(List<String> path) async {
    activeMapBounds = null;
    tab = 5;
    directory = [...path];
    activeCloudAlbum = null;
    activePerson = null;
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
    final native = activeCloudAlbum;
    final person = activePerson;
    final mapBounds = activeMapBounds;
    final listingKey = _listingKey();
    final keepItems = listingKey != null && listingKey == _visibleListingKey;
    loading = true;
    refreshing = keepItems && items.isNotEmpty;
    loadingMore = false;
    hasMore = false;
    error = null;
    if (!keepItems) _activeListing = null;
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
            const CloudAlbum(
              name: 'Best days',
              reference: ['demo-album'],
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
          loadPeople(refresh: refresh),
        ]);
        return;
      }
      await _restoreStore(session);
      if (version != _loadVersion) return;
      MediaListing? previous = listingKey == null
          ? null
          : _listings[listingKey];
      if (previous == null && listingKey != null) {
        final document = await cache?.readDocument(listingKey);
        if (version != _loadVersion) return;
        if (document != null) previous = MediaListing.fromJson(document);
      }
      var known = previous == null ? null : fileStore.resolve(previous.keys);
      if (previous?.days != null) timelineIndexAvailable ??= true;
      if (previous != null &&
          known!.length != previous.keys.length &&
          listingKey != null) {
        final persisted = await cache?.readListing(listingKey);
        if (version != _loadVersion) return;
        if (persisted != null) {
          fileStore.putAll(persisted);
          known = fileStore.resolve(previous.keys);
        }
      }
      if (previous != null && known!.length == previous.keys.length) {
        items = known;
        refreshing = true;
        notifyListeners();
        if (!refresh && previous.fresh(fileStore) && currentTab != 6) {
          if (previous.days != null) timelineIndexAvailable ??= true;
          _activeListing = previous;
          _listings[listingKey!] = previous;
          hasMore = previous.more;
          if (currentTab == 0) _libraryFiles = items;
          return;
        }
      } else if (listingKey != null) {
        final cached = await cache?.readListing(listingKey);
        if (version != _loadVersion) return;
        if (cached != null) fileStore.putAll(cached);
        final seed = cached ?? _seed(currentTab, path, native);
        if (seed.isNotEmpty && !keepItems) {
          items = seed;
          refreshing = true;
          notifyListeners();
        }
      }
      String? scopeEtag;
      if (cache != null &&
          currentTab == 4 &&
          smartAlbumOpen &&
          native == null &&
          person == null &&
          mapBounds == null) {
        scopeEtag = await client.folderEtag(session, path, optional: true);
        if (version != _loadVersion || _disposed) return;
        if (!refresh &&
            previous != null &&
            known?.length == previous.keys.length &&
            scopeEtag != null &&
            scopeEtag == previous.scopeEtag) {
          previous.updated = DateTime.now();
          previous.staleDays.clear();
          await _publishListing(previous, listingKey);
          return;
        }
      }
      final listing = MediaListing()
        ..allowCachedDays =
            !refresh && (scopeEtag == null || scopeEtag == previous?.scopeEtag);
      listing.scopeEtag = scopeEtag;
      if (currentTab == 6) {
        final saved = await cache?.readOfflineListing(_offlineListingKey) ?? [];
        final available = <CloudFile>[];
        for (final file in saved) {
          if (await offlineCopy(file) != null) available.add(file);
        }
        if (version != _loadVersion || account != session || _disposed) return;
        listing.add(fileStore, available);
      } else if (native != null) {
        final files = await client.albumFiles(session, native, _libraryFiles);
        if (version != _loadVersion || account != session || _disposed) return;
        listing.add(fileStore, files);
      } else if (currentTab == 1) {
        final files = await _listFolder(
          session,
          path,
          force: refresh,
          isCurrent: () => version == _loadVersion,
        );
        if (version != _loadVersion || account != session || _disposed) return;
        listing.add(fileStore, files);
      } else {
        if (currentTab != 5) await _ensureTimelineIndex(session);
        if (version != _loadVersion) return;
        if (person != null && timelineIndexAvailable != true) {
          throw const CloudException(
            'This server does not support browsing people.',
          );
        }
        if (mapBounds != null && timelineIndexAvailable != true) {
          throw const CloudException(
            'This server does not support browsing the photo map.',
          );
        }
        if (timelineIndexAvailable == true && currentTab != 5) {
          listing.days = mapBounds != null
              ? await client.mapDays(session, mapBounds)
              : currentTab == 0 && _initialDays != null
              ? _initialDays
              : await client.timelineDays(
                  session,
                  path: path,
                  favorites: currentTab == 2,
                  recursive: _recursiveMedia(currentTab, path),
                  person: person,
                );
          if (version != _loadVersion || account != session || _disposed) {
            return;
          }
          _initialDays = null;
        }
        listing.more = true;
        final previousDays = previous?.days;
        if (listing.days case final days? when listing.allowCachedDays) {
          if (previousDays != null &&
              !previous!.updated.isBefore(fileStore.staleBefore)) {
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
              if (previous.loaded.contains(day.id) &&
                  !previous.staleDays.contains(day.id) &&
                  before[day.id] == day.count &&
                  files.length == day.count) {
                listing.add(fileStore, files);
                listing.loaded.add(day.id);
              }
            }
            listing.more = days.any((d) => !listing.loaded.contains(d.id));
          }
        }
        if (version != _loadVersion) return;
        if (listing.loaded.isEmpty) {
          final page = await _nextPage(listing, session, currentTab, path);
          if (version != _loadVersion || account != session || _disposed) {
            return;
          }
          _mergePage(listing, page);
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
  List<CloudFile> _seed(int tab, List<String> path, CloudAlbum? native) {
    if (native != null ||
        activePerson != null ||
        activeMapBounds != null ||
        tab == 3 ||
        tab == 6) {
      return [];
    }
    if (tab == 1) return fileStore.folder(path, fresh: false) ?? [];
    final recursive = _recursiveMedia(tab, path);
    return fileStore.where(
      (f) =>
          f.isMedia &&
          f.albumReference == null &&
          pathStartsWith(f.path, path) &&
          (recursive || f.path.length == path.length + 1) &&
          (tab != 2 || f.favorite),
    );
  }

  String _storeKey(Account session) =>
      'library-v1|${session.server}|${session.userId}';

  Future<void> _restoreStore(Account session) {
    final generation = _cacheGeneration;
    final owner = _storeKey(session);
    if (_storeOwner == owner) return _restoringStore ?? Future.value();
    _storeOwner = owner;
    fileStore.clear();
    return _restoringStore = () async {
      final saved = await cache?.readDocument(owner);
      if (saved != null &&
          _storeOwner == owner &&
          generation == _cacheGeneration &&
          !_disposed) {
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
        await cache!.writeLibrary(key, fileStore);
      } while (_storeDirty);
    }().whenComplete(() => _storeWrite = null);
  }

  /// Direct children of a folder, reused from the shared store when the
  /// folder was listed recently or its recursive etag is unchanged.
  Future<List<CloudFile>> _listFolder(
    Account session,
    List<String> path, {
    bool force = false,
    bool Function()? isCurrent,
  }) async {
    final generation = _cacheGeneration;
    bool current() =>
        account == session &&
        !_disposed &&
        generation == _cacheGeneration &&
        (isCurrent?.call() ?? true);
    await _restoreStore(session);
    if (!current()) return [];
    if (!force) {
      final known = fileStore.folder(path);
      if (known != null) return known;
      final saved = await cache?.readFolderSnapshot(_storeKey(session), path);
      if (saved != null && current()) {
        final etag = await client.folderEtag(session, path);
        if (!current()) return [];
        if (etag != null && etag == saved.etag) {
          fileStore.putFolder(path, saved.files, etag: etag);
          _persistStore();
          return saved.files;
        }
      }
    }
    final previous = fileStore.folder(path, fresh: false);
    final result = await client.listFolder(session, path);
    if (!current()) return [];
    final returned = result.children.map((file) => file.key).toSet();
    final gone = {
      for (final file in previous ?? <CloudFile>[])
        if (!returned.contains(file.key)) file.key,
    };
    for (final file in previous ?? <CloudFile>[]) {
      if (file.isDirectory && gone.contains(file.key)) {
        fileStore.removeTree(file.path);
      }
    }
    fileStore.removeKeys(gone);
    for (final listing in _listings.values) {
      listing.replace(const {}, gone);
    }
    if (result.self case final self?) {
      if (path.isNotEmpty) fileStore.putAll([self]);
    }
    fileStore.putFolder(path, result.children, etag: result.self?.etag);
    _persistStore();
    return result.children;
  }

  Future<void> _ensureTimelineIndex(Account session) async {
    if (timelineIndexAvailable != null) return;
    final pending = _detectingTimelineIndex;
    if (pending != null) return pending;
    final generation = _cacheGeneration;
    final detection = () async {
      final days = await client.timelineDays(session, optional: true);
      if (account != session || _disposed || generation != _cacheGeneration) {
        return;
      }
      timelineIndexAvailable = days != null;
      _initialDays = days;
    }();
    _detectingTimelineIndex = detection;
    try {
      await detection;
    } finally {
      if (identical(_detectingTimelineIndex, detection)) {
        _detectingTimelineIndex = null;
      }
    }
  }

  /// Fetches the next unloaded days (or server page) without changing
  /// [listing]; the caller merges the result only if it is still current.
  Future<_Page> _nextPage(
    MediaListing listing,
    Account session,
    int currentTab,
    List<String> path,
  ) async {
    final recursive = _recursiveMedia(currentTab, path);
    final person = activePerson;
    final mapBounds = activeMapBounds;
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
      final cached = await _cachedDayFiles(
        listing,
        session,
        ids,
        currentTab,
        path,
      );
      final files =
          cached ??
          (mapBounds != null
              ? await client.mapDayFiles(session, ids, mapBounds)
              : await client.timelineDayFiles(
                  session,
                  ids,
                  path: path,
                  favorites: currentTab == 2,
                  recursive: recursive,
                  resolvePaths: !_pathless(currentTab),
                  person: person,
                ));
      return (files: files, days: ids, scanned: files.length);
    }
    final page = await client.searchPage(
      session,
      favorites: currentTab == 2,
      path: path,
      offset: listing.offset,
      limit: client.pageSize,
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

  Future<List<CloudFile>?> _cachedDayFiles(
    MediaListing listing,
    Account session,
    List<int> days,
    int currentTab,
    List<String> path,
  ) async {
    if (cache == null ||
        !listing.allowCachedDays ||
        currentTab != 0 ||
        path.isNotEmpty ||
        activeCloudAlbum != null ||
        activePerson != null ||
        activeMapBounds != null ||
        listing.updated.isBefore(fileStore.staleBefore) ||
        days.any(listing.staleDays.contains)) {
      return null;
    }
    final saved = await cache!.readDayFiles(
      _storeKey(session),
      days,
      freshSince: fileStore.staleBefore,
    );
    final counts = <int, int>{};
    for (final file in saved) {
      if (file.captureDay case final day?) {
        counts[day] = (counts[day] ?? 0) + 1;
      }
    }
    final expected = {for (final day in listing.days!) day.id: day.count};
    return days.every((day) => counts[day] == expected[day]) ? saved : null;
  }

  void _mergePage(MediaListing listing, _Page page) {
    if (page.days.isNotEmpty) {
      final days = page.days.toSet();
      final previous = {
        for (final key in listing.keys)
          if (days.contains(fileStore[key]?.captureDay)) key,
      };
      if (tab == 0 &&
          directory.isEmpty &&
          activeCloudAlbum == null &&
          activePerson == null &&
          activeMapBounds == null) {
        final returned = page.files.map((file) => file.key).toSet();
        final gone = previous.difference(returned);
        fileStore.removeKeys(gone);
        for (final cached in _listings.values) {
          cached.replace(const {}, gone);
        }
      }
      listing.replace(const {}, previous);
      listing.staleDays.removeAll(days);
    }
    listing.add(fileStore, page.files);
    if (listing.days case final days?) {
      listing.loaded.addAll(page.days);
      listing.more = days.any((d) => !listing.loaded.contains(d.id));
    } else {
      listing.offset += page.scanned;
      listing.more = page.scanned == client.pageSize;
    }
  }

  Future<void> _publishListing(MediaListing listing, String? key) async {
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
      if (version != _loadVersion || account != session || _disposed) return;
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
  bool dayNeedsRefresh(int day) =>
      _activeListing?.staleDays.contains(day) ?? false;

  /// Loads specific indexed days, such as those the timeline scrolled or was
  /// scrubbed to. The most recently requested days load first and requests
  /// left far behind by a fast scrub are dropped.
  ({List<TimelineDay> days, Set<int> changed, int added})? _timelineChanges;
  bool _checkingChanges = false;
  bool _pendingChangeHint = false;
  Set<String>? _pendingChangeIds = {};
  String? _changeOwner;
  String? _changeEtag;
  DateTime? _lastIndexCheck;

  /// True when the server's Timeline differs from what is on screen.
  bool get timelineChanged => _timelineChanges != null;

  /// Photos added on the server since the Timeline was shown.
  int get newPhotos => _timelineChanges?.added ?? 0;

  /// Unchanged trees cost one depth-zero etag request, not a library scan.
  Future<bool> checkForChanges({
    Set<String>? changedFileIds,
    bool force = false,
  }) async {
    if (force) {
      _pendingChangeHint = true;
      if (changedFileIds == null) {
        _pendingChangeIds = null;
      } else {
        _pendingChangeIds?.addAll(changedFileIds);
      }
    }
    final listing = _activeListing;
    final session = account;
    final shown = listing?.days;
    if (_checkingChanges ||
        demo ||
        session == null ||
        loading ||
        loadingMore ||
        fetchingDays ||
        busy ||
        !_browsingActive) {
      return false;
    }
    force = force || _pendingChangeHint;
    if (_pendingChangeHint) changedFileIds = _pendingChangeIds;
    _pendingChangeHint = false;
    _pendingChangeIds = {};
    _checkingChanges = true;
    final loadVersion = _loadVersion;
    try {
      final owner = 'changes-v1|${session.server}|${session.userId}';
      if (_changeOwner != owner) {
        _changeOwner = owner;
        _changeEtag = (await cache?.readDocument(owner))?['etag'] as String?;
        _lastIndexCheck = null;
      }
      final etag = await client.folderEtag(session, const []);
      if (_disposed || account != session) return false;
      if (loadVersion != _loadVersion ||
          loading ||
          loadingMore ||
          fetchingDays) {
        if (force) {
          _pendingChangeHint = true;
          if (changedFileIds == null) {
            _pendingChangeIds = null;
          } else {
            _pendingChangeIds?.addAll(changedFileIds);
          }
        }
        return false;
      }
      final treeChanged =
          force || (etag != null && _changeEtag != null && etag != _changeEtag);
      final indexDue =
          _lastIndexCheck == null ||
          DateTime.now().difference(_lastIndexCheck!) >=
              const Duration(minutes: 15);
      final metadataSweep = indexDue && _lastIndexCheck != null;
      if (!treeChanged && etag != null && etag == _changeEtag && !indexDue) {
        return false;
      }
      if (treeChanged) {
        _resolvedIds.clear();
        await cache?.invalidateListings(_storeKey(session));
        await _invalidateBrowse();
        final ids = changedFileIds;
        final hinted = ids == null
            ? <CloudFile>[]
            : fileStore.where((file) => ids.contains(file.id));
        final knownIds = hinted.map((file) => file.id).toSet();
        final precise =
            ids != null &&
            ids.isNotEmpty &&
            ids.every(knownIds.contains) &&
            hinted.every((file) => file.captureDay != null);
        final hintedDays = hinted.map((file) => file.captureDay).toSet();
        for (final cached in _listings.values) {
          cached.staleDays.addAll(
            precise ? cached.loaded.where(hintedDays.contains) : cached.loaded,
          );
        }
      }
      if (metadataSweep && !treeChanged) {
        listing?.staleDays.addAll(listing.loaded);
      }
      if (tab != 0 || shown == null || activeCloudAlbum != null) {
        if (treeChanged || metadataSweep) await load(refresh: true);
        if (_disposed || account != session || error != null) return false;
        _changeEtag = etag;
        _lastIndexCheck = DateTime.now();
        await cache?.writeDocument(owner, {'etag': etag});
        return treeChanged || metadataSweep;
      }
      final path = [...directory];
      final days = await client.timelineDays(
        session,
        path: path,
        recursive: _recursiveMedia(0, path),
      );
      if (days == null ||
          _disposed ||
          account != session ||
          !identical(listing, _activeListing)) {
        return false;
      }
      _lastIndexCheck = DateTime.now();
      final before = {for (final day in shown) day.id: day.count};
      final after = {for (final day in days) day.id: day.count};
      final changed = {
        for (final id in {...before.keys, ...after.keys})
          if (before[id] != after[id]) id,
      };
      if (treeChanged || metadataSweep) {
        listing!.staleDays.addAll(changed.where(listing.loaded.contains));
      }
      _changeEtag = etag;
      await cache?.writeDocument(owner, {'etag': etag});
      if (changed.isEmpty) {
        if (treeChanged || metadataSweep) {
          _persistStore();
          await cache?.writeDocument(_listingKey()!, listing!.toJson());
          notifyListeners();
        }
        return treeChanged || metadataSweep;
      }
      int total(Map<int, int> counts) => counts.values.fold(0, (a, b) => a + b);
      _timelineChanges = (
        days: days,
        changed: changed,
        added: math.max(0, total(after) - total(before)),
      );
      notifyListeners();
      return true;
    } catch (e) {
      if (force) {
        _pendingChangeHint = true;
        if (changedFileIds == null) {
          _pendingChangeIds = null;
        } else {
          _pendingChangeIds?.addAll(changedFileIds);
        }
      }
      if (!_disposed && account == session) {
        notice = 'Could not check for library updates. ${errorMessage(e)}';
        notifyListeners();
      }
      rethrow;
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
    listing.staleDays.addAll(changes.changed);
    final removed = changes.changed.difference(
      changes.days.map((day) => day.id).toSet(),
    );
    listing.loaded.removeAll(removed);
    listing.staleDays.removeAll(removed);
    listing.replace(const {}, {
      for (final key in listing.keys)
        if (removed.contains(fileStore[key]?.captureDay)) key,
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
    if (loading || listing?.days == null || account == null || error != null) {
      return;
    }
    for (final day in days) {
      if (listing!.loaded.contains(day) && !listing.staleDays.contains(day)) {
        continue;
      }
      _pendingDays
        ..remove(day)
        ..add(day);
    }
    while (_pendingDays.length > 60) {
      _pendingDays.remove(_pendingDays.first);
    }
    if (_browsingActive && !_fetchingDays && _pendingDays.isNotEmpty) {
      unawaited(_drainDays());
    }
  }

  Future<void> _drainDays() async {
    _fetchingDays = true;
    fetchingDays = true;
    notifyListeners();
    MediaListing? requestListing;
    Account? requestSession;
    var requestVersion = _loadVersion;
    try {
      while (_pendingDays.isNotEmpty && !_disposed && _browsingActive) {
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
          if (size == null ||
              (listing.loaded.contains(day) &&
                  !listing.staleDays.contains(day))) {
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
        requestVersion = version;
        requestListing = listing;
        requestSession = session;
        final currentTab = tab;
        final path = [...directory];
        final key = _listingKey();
        final person = activePerson;
        final mapBounds = activeMapBounds;
        final cached = await _cachedDayFiles(
          listing,
          session,
          batch,
          currentTab,
          path,
        );
        final files =
            cached ??
            (mapBounds != null
                ? await client.mapDayFiles(session, batch, mapBounds)
                : await client.timelineDayFiles(
                    session,
                    batch,
                    path: path,
                    favorites: currentTab == 2,
                    recursive: _recursiveMedia(currentTab, path),
                    resolvePaths: !_pathless(currentTab),
                    person: person,
                  ));
        if (version != _loadVersion ||
            account != session ||
            _disposed ||
            !identical(_activeListing, listing)) {
          continue;
        }
        _mergePage(listing, (files: files, days: batch, scanned: files.length));
        await _publishListing(listing, key);
        notifyListeners();
      }
    } catch (e) {
      if (!_disposed &&
          requestVersion == _loadVersion &&
          account == requestSession &&
          identical(requestListing, _activeListing)) {
        error ??= errorMessage(e);
        _pendingDays.clear();
      }
    } finally {
      _fetchingDays = false;
      fetchingDays = false;
      notifyListeners();
      if (!_disposed &&
          _browsingActive &&
          _pendingDays.isNotEmpty &&
          error == null) {
        unawaited(_drainDays());
      }
    }
  }

  String? _listingKey() {
    final session = account;
    if (demo || session == null || tab == 3) return null;
    return 'browse-v4|${session.server}|${session.userId}|$tab|$smartAlbumOpen|'
        '${directory.join('/')}|${activeCloudAlbum?.reference.join('/') ?? ''}'
        '${activePerson == null ? '' : '|person:${activePerson!.id}'}'
        '${activeMapBounds == null ? '' : '|map:${activeMapBounds!.map((b) => b.query).join(';')}'}';
  }

  Future<void> loadPeople({bool refresh = false}) async {
    final session = account;
    if (demo || session == null || _disposed) return;
    if (_peopleTask case final pending? when !refresh) return pending;
    if (!refresh &&
        _peopleUpdated != null &&
        DateTime.now().difference(_peopleUpdated!) <
            const Duration(minutes: 5)) {
      return;
    }
    final generation = ++_peopleVersion;
    final key = 'people-v1|${session.server}|${session.userId}';
    bool current() =>
        !_disposed &&
        generation == _peopleVersion &&
        account?.server == session.server &&
        account?.userId == session.userId;
    loadingPeople = true;
    peopleError = null;
    notifyListeners();
    final task = () async {
      try {
        if (people.isEmpty && !refresh) {
          final saved = await cache?.readDocument(key);
          if (!current()) return;
          if (saved != null) {
            try {
              final rows = saved['people'];
              if (rows is! List) {
                throw const FormatException('Unsupported cached people list.');
              }
              people = [
                for (final row in rows)
                  if (row is Map<String, dynamic>)
                    RecognizedPerson.fromJson(row)
                  else
                    throw const FormatException('Unsupported cached person.'),
              ]..sort(RecognizedPerson.compareByCount);
            } on FormatException {
              notice =
                  'The saved People list was damaged. Reloading from your server.';
            }
            notifyListeners();
          }
        }
        final result = await client.people(session, optional: true);
        if (!current()) return;
        final next = {
          for (final person in result ?? <RecognizedPerson>[])
            person.id: person,
        };
        for (final previous in people) {
          final replacement = next[previous.id];
          if (replacement == null ||
              _personPreviewVersion(previous) !=
                  _personPreviewVersion(replacement)) {
            final faceKey = _personPreviewKey(previous)!;
            final removed = _thumbs.remove(faceKey);
            if (removed != null) _thumbBytes -= removed.bytes.length;
            _facePreviewGenerations.remove(faceKey);
            await cache?.removeThumbnail(faceKey);
            if (!current()) return;
          }
        }
        peopleAvailable = result != null;
        people = result ?? [];
        _peopleUpdated = DateTime.now();
        await cache?.writeDocument(key, {
          'people': [for (final person in people) person.toJson()],
        });
      } catch (e) {
        if (current()) peopleError = errorMessage(e);
      } finally {
        if (current()) {
          loadingPeople = false;
          notifyListeners();
        }
      }
    }();
    _peopleTask = task;
    try {
      await task;
    } finally {
      if (identical(_peopleTask, task)) _peopleTask = null;
    }
  }

  String? _personPreviewKey(RecognizedPerson person) {
    final session = account;
    return session == null
        ? null
        : 'face-v1|${session.server}|${session.userId}|${person.id}';
  }

  String _personPreviewVersion(RecognizedPerson person) =>
      '${person.cover ?? ''}|${person.coverEtag ?? ''}';

  Uint8List? cachedPersonPreview(RecognizedPerson person) {
    final saved = _thumbs[_personPreviewKey(person)];
    return saved?.version == _personPreviewVersion(person)
        ? saved?.bytes
        : null;
  }

  Future<Uint8List?> restorePersonPreview(RecognizedPerson person) async {
    final generation = _peopleVersion;
    final key = _personPreviewKey(person);
    if (key == null) return null;
    if (cachedPersonPreview(person) case final saved?) return saved;
    final saved = await cache?.readThumbnail(key);
    if (saved == null ||
        saved.version != _personPreviewVersion(person) ||
        generation != _peopleVersion ||
        key != _personPreviewKey(person) ||
        _disposed) {
      return null;
    }
    _rememberPreview(key, saved.bytes, saved.version);
    return saved.bytes;
  }

  Future<Uint8List> personPreview(RecognizedPerson person) async {
    final session = account;
    final generation = _peopleVersion;
    final key = _personPreviewKey(person);
    if (session == null || key == null) {
      throw const CloudException('Sign in to load people.');
    }
    final version = _personPreviewVersion(person);
    if (_thumbs[key] case final saved?
        when saved.version == version &&
            _facePreviewGenerations[key] == generation) {
      return saved.bytes;
    }
    final loadKey = '$key|$version|$generation';
    if (_previewLoads[loadKey] case final pending?) return pending;
    final task = () async {
      Uint8List bytes;
      try {
        bytes = await client.personPreview(session, person);
      } on CloudException catch (error) {
        if (generation == _peopleVersion &&
            key == _personPreviewKey(person) &&
            !_disposed &&
            (error.statusCode == 404 || error.statusCode == 410)) {
          final removed = _thumbs.remove(key);
          if (removed != null) _thumbBytes -= removed.bytes.length;
          _facePreviewGenerations.remove(key);
          await cache?.removeThumbnail(key);
        }
        rethrow;
      }
      if (generation != _peopleVersion ||
          key != _personPreviewKey(person) ||
          _disposed) {
        throw const PreviewCancelled();
      }
      _rememberPreview(key, bytes, version);
      _facePreviewGenerations.remove(key);
      _facePreviewGenerations[key] = generation;
      while (_facePreviewGenerations.length > 4000) {
        _facePreviewGenerations.remove(_facePreviewGenerations.keys.first);
      }
      await cache?.writeThumbnail(key, bytes, version: version);
      if (generation != _peopleVersion ||
          key != _personPreviewKey(person) ||
          _disposed) {
        throw const PreviewCancelled();
      }
      return bytes;
    }();
    _previewLoads[loadKey] = task;
    try {
      return await task;
    } finally {
      if (identical(_previewLoads[loadKey], task)) {
        _previewLoads.remove(loadKey);
      }
    }
  }

  Future<void> _prepareAlbums({bool refresh = false}) async {
    final session = account;
    if (demo || session == null || _disposed) return;
    final pending = _catalogueTask;
    if (!refresh && pending != null && _catalogueSession == session) {
      return pending;
    }
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
    if (!refresh && pending != null) return pending;
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
        final roots = await _listFolder(
          session,
          [],
          isCurrent: () => generation == _catalogueVersion,
        );
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
      _catalogueEtag = null;
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
        nativeAlbums = (saved['native'] as List).map((value) {
          final item = (value as Map).cast<String, dynamic>();
          return CloudAlbum(
            name: item['name'] as String,
            reference: (item['path'] as List).cast<String>(),
            count: item['count'] as int,
            coverId: item['coverId'] as String?,
            shared: item['shared'] as bool,
          );
        }).toList();
        notifyListeners();
        final updated = DateTime.tryParse(saved['updated'] as String? ?? '');
        _catalogueUpdated = updated;
        _catalogueEtag = saved['etag'] as String?;
        if (!refresh &&
            updated != null &&
            DateTime.now().difference(updated) < const Duration(minutes: 15)) {
          _catalogueUpdated = updated;
          return;
        }
      }
    }
    final etag = cache == null
        ? null
        : await client.folderEtag(session, root, optional: true);
    if (generation != _catalogueVersion || account != session || _disposed) {
      return;
    }
    if (!refresh &&
        _catalogueUpdated != null &&
        etag != null &&
        etag == _catalogueEtag) {
      // Album memberships can change independently of the files' etags.
      await _loadCloudAlbums(session, generation);
      if (generation != _catalogueVersion || account != session || _disposed) {
        return;
      }
      _catalogueUpdated = DateTime.now();
      await _saveCatalogue(key);
      return;
    }
    discoveringAlbums = true;
    catalogueError = null;
    discoveredFolders = 0;
    final nativeLoad = _loadCloudAlbums(session, generation);
    notifyListeners();
    try {
      await _ensureTimelineIndex(session);
      if (generation != _catalogueVersion || account != session) return;
      final queue = <TimelineFolder>[TimelineFolder(root, [])];
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
        List<TimelineFolder> children;
        List<CloudFile> covers;
        if (timelineIndexAvailable == true) {
          final direct = await client.timelineDays(
            session,
            path: folder.path,
            recursive: false,
            existenceOnly: true,
          );
          covers = direct!.isEmpty
              ? []
              : folder.previews.isNotEmpty
              ? folder.previews
              : await client.timelineCover(
                  session,
                  folder.path,
                  direct.first.id,
                );
          children = direct.isEmpty || atRoot
              ? await client.timelineFolders(session, folder.path)
              : [];
        } else {
          final contents = await _listFolder(
            session,
            folder.path,
            force: refresh,
            isCurrent: () => generation == _catalogueVersion,
          );
          covers = contents.where((f) => f.isMedia).take(1).toList();
          children = covers.isNotEmpty && !atRoot
              ? []
              : contents
                    .where((f) => f.isDirectory)
                    .map((f) => TimelineFolder(f.path, []))
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
            timelineIndexAvailable == true
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
      _catalogueEtag = etag;
      notifyListeners();
      await nativeLoad;
      if (generation != _catalogueVersion || account != session || _disposed) {
        return;
      }
      await _saveCatalogue(key);
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

  String? _catalogueEtag;

  Future<void> _saveCatalogue(String key) async {
    await cache?.writeDocument(key, {
      'updated': _catalogueUpdated!.toIso8601String(),
      'etag': _catalogueEtag,
      'albums': _catalogue.map((a) => a.toJson()).toList(),
      'native': [
        for (final album in nativeAlbums)
          {
            'name': album.name,
            'path': album.reference,
            'count': album.count,
            'coverId': album.coverId,
            'shared': album.shared,
          },
      ],
    });
  }

  Future<void> _loadCloudAlbums(Account session, int generation) async {
    nativeAlbumError = null;
    try {
      final own = await client.albums(session);
      final shared = await client.albums(session, shared: true);
      if (account == session && generation == _catalogueVersion && !_disposed) {
        nativeAlbums = [...own, ...shared];
      }
    } catch (e) {
      if (account == session && generation == _catalogueVersion && !_disposed) {
        nativeAlbumError = 'Could not load server albums. ${errorMessage(e)}';
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
    _peopleVersion++;
    _peopleTask = null;
    _peopleUpdated = null;
    loadingPeople = false;
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
            'This album item is view-only. Manage its original on your server.',
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
          throw const CloudException('Connect a server to upload files.');
        }
        await client.upload(account!, [...directory, name], bytes, size);
        fileStore.invalidateFolder(directory);
      }, 'Upload complete');

  void _clearPreviews() {
    _previewGeneration++;
    _thumbnailWarmupTimer?.cancel();
    _thumbnailWarmupQueue.clear();
    _thumbnailWarmupKnown.clear();
    _resolvedIds.clear();
    _thumbs.clear();
    _facePreviewGenerations.clear();
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
        !_browsingActive ||
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
    if (_disposed || !_browsingActive || tab != 0 || account == null) return;
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

  /// Resolved location of [file]; actions call this before touching paths.
  Future<CloudFile> resolve(CloudFile file) async {
    if (!file.pending) return file;
    final id = file.id!;
    if (_resolvedIds[id] case final known?) return known;
    final session = account;
    if (session == null) {
      throw const CloudException('Sign in again to open this item.');
    }
    final generation = _cacheGeneration;
    final found = await client.resolveFileIds(session, [id]);
    if (_disposed ||
        !identical(account, session) ||
        generation != _cacheGeneration) {
      throw const CloudException(
        'The account or cache changed. Open this item again.',
      );
    }
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
    final generation = _previewGeneration;
    void checkCurrent() {
      if (_disposed ||
          !identical(account, session) ||
          generation != _previewGeneration) {
        throw const PreviewCancelled();
      }
    }

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
        checkCurrent();
        if (stored != null) {
          if (stored.version == version) {
            _rememberPreview(key, stored.bytes, version);
            return stored.bytes;
          }
          if (memory == null) stale?.call(stored.bytes);
        }
      }
      checkCurrent();
      final bytes = await _fetchPreview(session, file, size, loadKey);
      checkCurrent();
      _rememberPreview(key, bytes, version);
      unawaited(disk?.writeThumbnail(key, bytes, version: version));
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
    if (!_browsingActive) return Future.error(const PreviewCancelled());
    if (file.id == null ||
        timelineIndexAvailable != true ||
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

  /// Sends queued thumbnails as batched preview requests, newest
  /// requests (tiles currently on screen) first.
  void _flushPreviews(Account session) {
    _previewTimer = null;
    if (!identical(account, session) || !_browsingActive) return;
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
    final generation = _previewGeneration;
    bool current() =>
        !_disposed &&
        identical(account, session) &&
        generation == _previewGeneration;
    void single(_PreviewRequest request) {
      if (!_browsingActive || !current()) {
        request.completer.completeError(const PreviewCancelled());
      } else {
        request.completer.complete(
          client.preview(session, request.file, size: request.size),
        );
      }
    }

    try {
      if (batch.length == 1) {
        single(batch.single);
        return;
      }
      final previews = await client.multipreview(session, [
        for (final request in batch) request.file.id!,
      ], size: batch.first.size);
      if (!current()) {
        for (final request in batch) {
          request.completer.completeError(const PreviewCancelled());
        }
        return;
      }
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
      // Some servers or proxies may not support batching.
      if (current() && ++_multipreviewFailures >= 2) {
        _multipreviewUnavailable = true;
      }
      for (final request in batch) {
        if (!request.completer.isCompleted) single(request);
      }
    } finally {
      _previewBatches--;
      final nextSession = account;
      if (!_disposed &&
          _browsingActive &&
          nextSession != null &&
          _previewBatch.isNotEmpty) {
        _previewTimer ??= Timer(
          Duration.zero,
          () => _flushPreviews(nextSession),
        );
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
    return await copy.exists() && await copy.length() == file.size
        ? copy
        : null;
  }

  String _originalKey(Account session, CloudFile file) =>
      'original|${session.server}|${session.userId}|${file.id ?? file.key}|'
      '${file.modified?.microsecondsSinceEpoch}|${file.size}';

  /// Direct authenticated stream for the platform video player.
  ({Uri uri, Map<String, String> headers})? streamSource(CloudFile file) {
    final session = account;
    if (demo || session == null) return null;
    return client.streamSource(session, file);
  }

  /// Explicitly saved original, outside the bounded browsing cache.
  Future<File> saveOffline(CloudFile file) => _download(file, offline: true);

  String get _offlineListingKey =>
      'offline|${account?.server}|${account?.userId}';

  Future<int> cacheSize() async => await cache?.size() ?? 0;
  Future<int> downloadSize() async => await cache?.downloadSize() ?? 0;

  Future<void> clearCache() async {
    if (busy) {
      throw const CloudException('Wait for the current transfer to finish.');
    }
    _loadVersion++;
    _cacheGeneration++;
    _warmVersion++;
    _warmTimer?.cancel();
    warming = false;
    loading = false;
    refreshing = false;
    loadingMore = false;
    _pendingDays.clear();
    _initialDays = null;
    _detectingTimelineIndex = null;
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

  Future<File> download(CloudFile file) => _download(file);

  Future<File> _download(CloudFile file, {bool offline = false}) async {
    final session = account;
    if (session == null || (offline && cache == null)) {
      throw const CloudException('Downloads need a connected server.');
    }
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
    Directory? transfer;
    try {
      file = await resolve(file);
      void checkSession() {
        if (_disposed || account != session) {
          throw const CloudException(
            'The account changed. Start the download again.',
          );
        }
      }

      checkSession();
      final target = offline
          ? await cache!.original(_originalKey(session, file), file.name)
          : null;
      Future<File> publishOffline() async {
        checkSession();
        final key = 'offline|${session.server}|${session.userId}';
        final saved = await cache!.readOfflineListing(key);
        checkSession();
        await cache!.writeOfflineListing(key, [
          ...saved.where((f) => f.key != file.key),
          file,
        ]);
        return target!;
      }

      if (target != null &&
          await target.exists() &&
          await target.length() == file.size) {
        return await publishOffline();
      }
      final folder = Directory(
        '${(await getTemporaryDirectory()).path}/ncloud-downloads',
      );
      await folder.create(recursive: true);
      validateName(file.name);
      checkSession();
      final response = offline
          ? await client.downloadVersion(session, file)
          : await client.download(session, file);
      // Separate each transfer so identical filenames never collide.
      transfer = await folder.createTemp('transfer-');
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
      if (await output.length() != file.size) {
        throw const CloudException(
          'Download size did not match the file. Refresh and retry.',
        );
      }
      checkSession();
      if (target != null) {
        final partial = File('${target.path}.part');
        try {
          await output.copy(partial.path);
          checkSession();
          await partial.rename(target.path);
        } finally {
          if (await partial.exists()) await partial.delete();
        }
        return await publishOffline();
      }
      return output;
    } catch (_) {
      if (transfer != null && await transfer.exists()) {
        await transfer.delete(recursive: true);
      }
      rethrow;
    } finally {
      try {
        if (offline && transfer != null && await transfer.exists()) {
          await transfer.delete(recursive: true);
        }
      } finally {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _folderSync?.dispose();
    _disposed = true;
    _warmTimer?.cancel();
    _thumbnailWarmupTimer?.cancel();
    _catalogueVersion++;
    _sharedAlbumsVersion++;
    _peopleVersion++;
    _loadVersion++;
    _loginVersion++;
    _wakeLogin();
    client.close();
    unawaited(cache?.close());
    super.dispose();
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
