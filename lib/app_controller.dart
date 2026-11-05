import 'dart:async';
import 'dart:io';

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
  AppController({required this.store, NextcloudClient? client, this.cache})
    : client = client ?? NextcloudClient();

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
  final Map<String, Future<Uint8List>> _previews = {};
  final Map<String, int> _previewSizes = {};
  int _previewBytes = 0;
  final Map<String, Future<CloudFile?>> _covers = {};
  final Map<String, List<CloudFile>> _demoTrash = {};

  bool get connected => account != null || demo;
  bool get canCancelLogin => signingIn && !_savingAccount;

  Future<void> initialize() async {
    try {
      final saved = await store.read();
      if (saved != null) account = Account.decode(saved);
    } catch (e) {
      error = 'Could not restore the saved account. ${errorMessage(e)}';
    } finally {
      starting = false;
      notifyListeners();
    }
    if (connected) {
      unawaited(_prepareAlbums());
      unawaited(_prepareSharedAlbums(refresh: false));
      await load(refresh: false);
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
      unawaited(_prepareAlbums());
      unawaited(_prepareSharedAlbums(refresh: false));
      await load();
    } finally {
      _savingAccount = false;
    }
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
    _pendingDays.clear();
    if (!keepItems) items = [];
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
  Future<({List<CloudFile> files, List<int> days})> _nextPage(
    _MediaListing listing,
    Account session,
    int currentTab,
    List<String> path,
  ) async {
    final recursive = _recursiveMedia(currentTab, path);
    if (listing.days case final days?) {
      final ids = <int>[];
      var count = 0;
      for (final day in days) {
        if (listing.loaded.contains(day.id)) continue;
        if (ids.length >= 40 || (ids.isNotEmpty && count + day.count > 200)) {
          break;
        }
        ids.add(day.id);
        count += day.count;
      }
      if (ids.isEmpty) return (files: <CloudFile>[], days: ids);
      final files = await client.memoryDayFiles(
        session,
        ids,
        path: path,
        favorites: currentTab == 2,
        recursive: recursive,
      );
      return (files: files, days: ids);
    }
    final page = await client.search(
      session,
      favorites: currentTab == 2,
      path: path,
      offset: listing.offset,
      recursive: recursive,
    );
    final existing = listing.keys.toSet();
    if (page.isNotEmpty && page.every((f) => existing.contains(f.key))) {
      throw const CloudException(
        'The server repeated a page. Pull to refresh your library.',
      );
    }
    return (files: page, days: <int>[]);
  }

  Future<void> _fetchPage(
    _MediaListing listing,
    Account session,
    int currentTab,
    List<String> path,
  ) async {
    _mergePage(listing, await _nextPage(listing, session, currentTab, path));
  }

  void _mergePage(
    _MediaListing listing,
    ({List<CloudFile> files, List<int> days}) page,
  ) {
    listing.add(fileStore, page.files);
    if (listing.days case final days?) {
      listing.loaded.addAll(page.days);
      listing.more = days.any((d) => !listing.loaded.contains(d.id));
    } else {
      listing.offset += page.files.length;
      listing.more = page.files.length == NextcloudClient.photoLimit;
    }
  }

  Future<void> _publishListing(_MediaListing listing, String? key) async {
    _activeListing = listing;
    items = fileStore.resolve(listing.keys);
    hasMore = listing.more;
    if (tab == 0) _libraryFiles = items;
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
        for (final day in _pendingDays.toList().reversed) {
          final size = counts[day];
          if (size == null || listing.loaded.contains(day)) {
            _pendingDays.remove(day);
            continue;
          }
          if (batch.isNotEmpty && count + size > 200) break;
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
        );
        if (version != _loadVersion ||
            _disposed ||
            !identical(_activeListing, listing)) {
          continue;
        }
        _mergePage(listing, (files: files, days: batch));
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

  void _discardPreview(String key) {
    _previews.remove(key);
    _previewBytes -= _previewSizes.remove(key) ?? 0;
  }

  void _clearPreviews() {
    _previews.clear();
    _previewSizes.clear();
    _previewBytes = 0;
  }

  Future<Uint8List> preview(
    CloudFile file, {
    bool retry = false,
    int size = 384,
  }) {
    final session = account;
    if (session == null) {
      return Future.error(const CloudException('Reconnect to load previews.'));
    }
    final key =
        '${session.server}|${session.userId}|${file.id ?? file.key}|'
        '${file.modified?.microsecondsSinceEpoch}|${file.size}|${(file.etag ?? '').replaceAll('"', '')}|$size';
    if (retry) _discardPreview(key);
    final cached = _previews.remove(key);
    if (cached != null) {
      _previews[key] = cached;
      return cached;
    }
    late final Future<Uint8List> pending;
    final disk = cache;
    Future<Uint8List> fetch() async {
      if (!retry && disk != null) {
        final stored = await disk.readThumbnail(key);
        if (stored != null) return stored;
      }
      final bytes = await client.preview(session, file, size: size);
      unawaited(disk?.writeThumbnail(key, bytes));
      return bytes;
    }

    pending = fetch().then(
      (bytes) {
        if (identical(_previews[key], pending)) {
          _previewSizes[key] = bytes.length;
          _previewBytes += bytes.length;
          while (_previewBytes > 24 * 1024 * 1024 && _previews.isNotEmpty) {
            _discardPreview(_previews.keys.first);
          }
        }
        return bytes;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_previews[key], pending)) _discardPreview(key);
        Error.throwWithStackTrace(error, stack);
      },
    );
    _previews[key] = pending;
    while (_previews.length > 128) {
      _discardPreview(_previews.keys.first);
    }
    return pending;
  }

  /// Previously saved original for offline replay, if any.
  Future<File?> offlineCopy(CloudFile file) async {
    final session = account;
    if (cache == null || session == null) return null;
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
