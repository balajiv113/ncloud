import '../features/backup/background/backup_scheduler.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../features/account/account_session.dart';
import '../features/albums/album_catalogue.dart';
import '../features/albums/album_members.dart';
import '../features/timeline/change_detection.dart';
import '../features/timeline/change_monitor.dart';
import '../features/timeline/day_batches.dart';
import '../features/timeline/timeline_fetcher.dart';
import '../features/timeline/view_query.dart';
import '../diagnostics.dart';
import 'status_sink.dart';
import '../discovery_models.dart';
import '../core/storage/file_store.dart';
import '../features/backup/state/backup_controller.dart';
import '../core/storage/local_cache.dart';
import '../models.dart';
import '../features/files/library_operations.dart';
import '../features/timeline/library_warm_up.dart';
import '../core/storage/media_listing.dart';
import '../features/files/file_resolver.dart';
import '../features/files/original_transfers.dart';
import '../features/files/share_session.dart';
import '../features/map/photo_map_session.dart';
import 'browse_target.dart';
import '../core/cached_resource.dart';
import '../core/thumbnails/thumbnail_prefetcher.dart';
import '../core/thumbnails/thumbnail_repository.dart';
import '../core/cloud/cloud_backend.dart';
import '../features/backup/background/android_backup.dart';
import '../features/account/session_store.dart';
import '../features/backup/background/ios_album_backup.dart';
export '../features/account/session_store.dart';
export '../core/thumbnails/preview_batcher.dart' show PreviewCancelled;

/// A fetched index batch or page with its opaque continuation.

class AppController extends ChangeNotifier implements StatusSink {
  AppController({
    required this.store,
    required this.client,
    this.cache,
    this.pathlessTimeline = false,
    BackupController? backupController,
  }) {
    _backup = backupController;
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
  BackupController? _backup;
  BackupController get backup => _backup ??= _createBackup();

  BackupController _createBackup() {
    final journal = SyncJournal();
    return BackupController(
      client: client,
      account: () => account,
      journal: journal,
      scheduler: Platform.isAndroid
          ? AndroidBackupScheduler()
          : Platform.isIOS
          ? IosAlbumScheduler(
              journal: journal,
              readAccount: () async => account,
              initialize: initializeBackupDispatcher,
            )
          : UnsupportedBackupScheduler(),
    );
  }

  void setSyncForeground(bool active) {
    _backup?.setForeground(active);
    if (active && connected && (Platform.isAndroid || Platform.isIOS)) {
      unawaited(backup.load());
    }
  }

  /// True while showing locally cached results that are being refreshed.
  bool refreshing = false;
  Account? account;
  bool get starting => _session.starting;
  set starting(bool value) => _session.starting = value;
  bool get signingIn => _session.signingIn;
  bool loading = false;
  bool get busy => _ops.busy;
  set busy(bool value) => _ops.busy = value;
  bool loadingMore = false;
  bool hasMore = false;
  final Map<String, MediaListing> _listings = {};

  /// The one cache of files shared by Timeline, Albums, Shared and Drive.
  final FileStore fileStore = FileStore();
  Future<void>? _restoringStore;
  String? _storeOwner;
  Future<void>? _storeWrite;
  bool _storeDirty = false;
  final DayRequestQueue _dayRequests = DayRequestQueue();
  late final TimelineFetcher _fetcher = TimelineFetcher(
    client: client,
    cache: cache,
    staleBefore: () => fileStore.staleBefore,
  );

  /// True while days requested by the scrolling timeline are downloading.
  bool fetchingDays = false;
  MediaListing? _activeListing;
  String? _visibleListingKey;
  bool? timelineIndexAvailable;
  bool get discoveringAlbums => _albums.discovering;
  int get discoveredFolders => _albums.discovered;
  List<TimelineDay>? _initialDays;
  Future<void>? _detectingTimelineIndex;
  bool get albumHome => target is AlbumHomeTarget;
  List<RecognizedPerson> get people => _people.value;
  @visibleForTesting
  set people(List<RecognizedPerson> value) => _people.value = value;
  bool get loadingPeople => _people.loading;
  bool? get peopleAvailable => _people.available;
  String? get peopleError => _people.error;
  List<TimelineDay> get indexedDays => _activeListing?.days ?? [];
  List<CloudFile> _libraryFiles = [];
  List<CloudAlbum> get nativeAlbums => _albums.server;
  String? get nativeAlbumError => _albums.serverError;
  String? get catalogueError => _albums.error;
  List<SmartAlbum> get sharedAlbums => _shared.value;
  String? get sharedAlbumError => _shared.error;
  bool get loadingSharedAlbums => _shared.loading;
  List<CloudFile> get libraryFiles => _libraryFiles;
  List<String> get photoRoot =>
      account?.photoRoot ??
      _albums.autoRoot ??
      (_libraryFiles.any((f) => f.path.firstOrNull == 'Photos')
          ? ['Photos']
          : []);
  List<SmartAlbum> get smartAlbums => _albums.smart;
  int get completed => _ops.completed;
  int get total => _ops.total;

  /// What the library is showing. The fields below read it.
  BrowseTarget target = const TimelineTarget();
  Destination get destination => target.destination;
  List<String> get directory => target.path;
  bool get smartAlbumOpen => target is SmartAlbumTarget;
  CloudAlbum? get activeCloudAlbum => target.serverAlbum;
  RecognizedPerson? get activePerson => target.person;
  List<PhotoMapBounds>? get activeMapBounds => target.mapBounds;
  List<CloudFile> items = [];
  @override
  String? error;
  @override
  String? notice;
  int _loadVersion = 0;
  int _cacheGeneration = 0;
  bool _disposed = false;

  /// Every screen's photo and face thumbnails: memory, then disk, then server.
  late final ThumbnailRepository _thumbnails = ThumbnailRepository(
    client: client,
    cache: cache,
    account: () => account,
    active: () => _browsingActive,
    batchAvailable: () => timelineIndexAvailable == true,
    offlineOriginal: offlineCopy,
  );
  ThumbnailRepository get thumbnails => _thumbnails;

  /// Recognize clusters, revalidated at most every five minutes.
  late final CachedResource<List<RecognizedPerson>> _people = CachedResource(
    empty: const [],
    freshFor: const Duration(minutes: 5),
    account: () => account,
    disposed: () => _disposed,
    cache: cache,
    key: (session) => 'people-v2|${session.storageKey}',
    fetch: (session, _) => client.people(session, optional: true),
    encode: (people, _) => {
      'people': [for (final person in people) person.toJson()],
    },
    decode: (document) {
      final rows = document['people'];
      if (rows is! List) {
        throw const FormatException('Unsupported cached people list.');
      }
      return (
        value: [
          for (final row in rows)
            if (row is Map<String, dynamic>)
              RecognizedPerson.fromJson(row)
            else
              throw const FormatException('Unsupported cached person.'),
        ]..sort(RecognizedPerson.compareByCount),
        updated: null,
      );
    },
    onChanged: notifyListeners,
    onRestored: (people) =>
        unawaited(Future.wait(people.map(_thumbnails.restoreFace))),
    replace: (old, next) async {
      final byId = {for (final person in next) person.id: person};
      for (final previous in old) {
        final replacement = byId[previous.id];
        if (replacement == null ||
            !_thumbnails.sameFace(previous, replacement)) {
          await _thumbnails.forgetFace(previous);
        }
      }
    },
    onDamaged: () => notice =
        'The saved People list was damaged. Reloading from your server.',
  );

  /// Smart and server albums.
  late final AlbumCatalogue _albums = AlbumCatalogue(
    client: client,
    cache: cache,
    account: () => account,
    disposed: () => _disposed,
    onChanged: notifyListeners,
    photoRoot: () => photoRoot,
    listFolder: _listFolder,
    ensureIndex: _ensureTimelineIndex,
    indexAvailable: () => timelineIndexAvailable == true,
    hydrate: _hydrate,
  );

  /// Albums from folders shared with this account, reused for 15 minutes.
  late final CachedResource<List<SmartAlbum>> _shared = CachedResource(
    empty: const [],
    freshFor: const Duration(minutes: 15),
    account: () => account,
    disposed: () => _disposed,
    cache: cache,
    key: (session) => 'incoming-albums-v1|${session.storageKey}',
    fetch: _fetchSharedAlbums,
    encode: (albums, updated) => {
      'updated': updated.toIso8601String(),
      'albums': [for (final album in albums) album.toJson()],
    },
    decode: (document) => (
      value: [
        for (final album in document['albums'] as List)
          SmartAlbum.fromJson((album as Map).cast<String, dynamic>()),
      ],
      updated: DateTime.parse(document['updated'] as String),
    ),
    onChanged: notifyListeners,
    onRestored: (albums) =>
        _hydrate(albums.expand((album) => album.files.take(1))),
  );
  late final FileResolver _fileResolver = FileResolver(
    client: client,
    account: () => account,
    active: () => !_disposed,
    apply: _applyResolved,
  );
  late final OriginalTransfers _originalTransfers = OriginalTransfers(
    client: client,
    cache: cache,
  );
  late final ThumbnailPrefetcher _prefetch = ThumbnailPrefetcher(
    thumbnails: _thumbnails,
    account: () => account,
    enabled: () => cache != null && pathlessTimeline && !_disposed,
    active: () =>
        !_disposed && _browsingActive && destination == Destination.timeline,
    idle: () => !(busy || loading || loadingMore || fetchingDays),
    fetch: (file) => preview(file),
    onFailure: () {
      const message = 'Some previews could not be cached. Tap them to retry.';
      if (notice != message) {
        notice = message;
        notifyListeners();
      }
    },
    limit: FileStore.maxFiles,
    recentDays: LibraryWarmUp.years * 366,
  );
  bool _browsingActive = true;

  void setBrowsingActive(bool active) {
    _browsingActive = active;
    if (active) _session.wake();
    if (!active) {
      _prefetch.pause();
      _thumbnails.pause();
    } else {
      _prefetch.schedule();
      if (!fetchingDays && _dayRequests.isNotEmpty && error == null) {
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

  ChangeMonitor? createChangeMonitor(
    Future<bool> Function(Set<String>? ids, bool pushed) check,
  ) {
    final session = account;
    if (session == null || _disposed) return null;
    bool current() => !_disposed && identical(account, session);
    return ChangeMonitor(
      client: client,
      account: session,
      check: (ids, pushed) async =>
          current() ? await check(ids, pushed) : false,
      onActive: (active) {
        if (current()) setBrowsingActive(active);
      },
      onError: (error) {
        if (current()) reportChangeError(error);
      },
    );
  }

  final Map<String, Future<CloudFile?>> _covers = {};

  bool get connected => account != null;
  bool get canCancelLogin => _session.canCancel;

  Future<void> initialize() async {
    final restored = await _session.restore();
    if (!restored.current) return;
    if (restored.account != null) account = restored.account;
    if (!connected) starting = false;
    notifyListeners();
    if (connected) {
      setSyncForeground(true);
      try {
        await cache?.readOfflineListing(_offlineListingKey);
      } catch (e) {
        notice = 'Could not restore saved offline files. ${errorMessage(e)}';
      }
      final preparation = warmUp.prepare();
      unawaited(_albums.load());
      unawaited(loadPeople());
      unawaited(_shared.load());
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

  Future<void> passwordLogin(String server, String user, String password) =>
      _session.passwordLogin(server, user, password);

  Future<void> browserLogin(
    String server,
    Future<bool> Function(Uri) openBrowser,
  ) => _session.browserLogin(server, openBrowser);

  void cancelLogin() => _session.cancel();

  /// Saves a newly accepted account and prepares its library.
  Future<void> _signedIn(Account result) async {
    if (account != null) await backup.disconnect();
    await store.write(result.encode());
    account = result;
    setSyncForeground(true);
    target = const TimelineTarget();
    final preparation = warmUp.prepare();
    unawaited(_albums.load());
    unawaited(loadPeople());
    unawaited(_shared.load());
    await preparation;
  }

  late final AccountSession _session = AccountSession(
    client: client,
    store: store,
    status: this,
    disposed: () => _disposed,
    active: () => _browsingActive,
    signedIn: _signedIn,
    onChanged: notifyListeners,
  );

  /// The one-time welcome after the first sign-in.
  late final LibraryWarmUp warmUp = LibraryWarmUp(
    cache: cache,
    account: () => account,
    disposed: () => _disposed,
    browsingActive: () => _browsingActive,
    status: this,
    listingKey: () => _listingKey()!,
    load: () => load(refresh: false),
    activeListing: () => _activeListing,
    loadNextPage: loadNextPage,
    loadCatalogue: () =>
        Future.wait([_albums.load(), _shared.load(), loadPeople()]),
    items: () => items,
    preview: (file) => preview(file),
    storeWritten: () => _storeWrite,
    started: () => starting = false,
    onChanged: notifyListeners,
  );

  /// Removes everything the signed-in account left on the device: the saved
  /// login, backup records and staged transfer files, downloads, and the
  /// browsing cache. Every part runs even if an earlier one fails; the first
  /// failure is rethrown afterwards.
  Future<void> _wipeLocalData() async {
    Object? failure;
    Future<void> step(Future<void> Function() part) async {
      try {
        await part();
      } catch (e) {
        failure ??= e;
      }
    }

    final backup = _backup;
    if (backup != null) {
      await step(backup.disconnect);
      await step(backup.wipe);
    }
    await step(store.clear);
    await step(() async {
      final downloads = Directory(
        '${(await getTemporaryDirectory()).path}/ncloud-downloads',
      );
      if (await downloads.exists()) await downloads.delete(recursive: true);
    });
    await step(() async {
      _storeOwner = null;
      await _storeWrite;
    });
    await step(() async => await cache?.clearAll());
    if (failure != null) throw failure!;
  }

  Future<void> signOut() async {
    if (busy || _session.saving) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _wipeLocalData();
      _loadVersion++;
      _session.invalidate();
      _forgetChangeTracking();
      _clearPreviews();
      _covers.clear();
      warmUp.cancel();
      account = null;
      Diagnostics.session.clear();
      _libraryFiles = [];
      _listings.clear();
      fileStore.clear();
      _storeOwner = null;
      _restoringStore = null;
      _dayRequests.clear();
      _activeListing = null;
      _visibleListingKey = null;
      _albums.reset();
      _shared.reset();
      timelineIndexAvailable = null;
      _initialDays = null;
      _detectingTimelineIndex = null;
      _people.reset();
      items = [];
      target = const TimelineTarget();
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

  /// Opens [next] and loads it.
  Future<void> open(BrowseTarget next) {
    target = next;
    return load(refresh: false);
  }

  /// Switches to the root of a destination.
  Future<void> select(Destination destination) => open(rootTarget(destination));

  Future<void> openFolder(CloudFile folder) => open(DriveTarget(folder.path));

  /// Moves the current folder view to [path].
  Future<void> goTo(List<String> path) => open(target.inFolder(path));

  Future<void> openSmartAlbum(List<String> path) =>
      open(SmartAlbumTarget(path));

  bool get albumIncludesSubfolders =>
      destination != Destination.albums || !listEquals(directory, photoRoot);

  /// The folder the current view shows, as a file for folder actions.
  CloudFile get currentFolder => CloudFile(
    path: [...directory],
    name: directory.lastOrNull ?? 'My drive',
    isDirectory: true,
  );

  Future<void> openMapArea(List<PhotoMapBounds> bounds) {
    if (bounds.isEmpty) throw const FormatException('Choose a map area.');
    return open(MapAreaTarget(bounds));
  }

  Future<void> openPerson(RecognizedPerson person) =>
      open(PersonTarget(person));

  Future<void> openCloudAlbum(CloudAlbum album) =>
      open(ServerAlbumTarget(album));

  Future<void> openSharedAlbum(List<String> path) =>
      open(SharedFolderTarget(path));

  Future<void> setPhotoRoot(List<String> path) async {
    if (account case final session?) {
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
    await select(Destination.albums);
  }

  Future<void> load({bool refresh = true}) async {
    final run = _LoadRun(
      version: ++_loadVersion,
      session: account,
      view: target,
      refresh: refresh,
      listingKey: _listingKey(),
    );
    if (refresh) _initialDays = null;
    final keepItems =
        run.listingKey != null && run.listingKey == _visibleListingKey;
    _startLoad(run, keepItems: keepItems);
    try {
      final session = run.session;
      if (session == null) return;
      if (run.view is AlbumHomeTarget) {
        await Future.wait([
          _albums.load(refresh: refresh),
          _shared.load(refresh: refresh),
          loadPeople(refresh: refresh),
        ]);
        return;
      }
      await _restoreStore(session);
      if (!_isCurrent(run)) return;
      final cached = await _restoreListing(run, keepItems: keepItems);
      if (cached == null || cached.fresh) return;
      final scope = await _checkScope(run, cached);
      if (scope == null) return;
      final listing = MediaListing()
        ..allowCachedDays =
            !refresh &&
            (scope.etag == null || scope.etag == cached.previous?.scopeEtag)
        ..scopeEtag = scope.etag;
      final loaded = switch (run.view) {
        OfflineTarget() => await _loadOffline(run, listing),
        ServerAlbumTarget(:final album) => await _loadServerAlbum(
          run,
          listing,
          album,
        ),
        DriveTarget() => await _loadFolder(run, listing),
        _ => await _loadIndexed(run, listing, cached),
      };
      if (!loaded || !_isCurrent(run)) return;
      await _publishListing(listing, run.listingKey);
    } catch (e) {
      if (run.version == _loadVersion) error = errorMessage(e);
    } finally {
      if (run.version == _loadVersion) {
        loading = false;
        refreshing = false;
        loadingMore = false;
        if (destination == Destination.timeline) _prefetch.queue(items);
        notifyListeners();
      }
    }
  }

  /// Whether [run] is still the load that should publish: nothing newer has
  /// started and the account is unchanged.
  bool _isCurrent(_LoadRun run) =>
      run.version == _loadVersion && !_disposed && account == run.session;

  /// Shows what is already known for the view while the load runs.
  void _startLoad(_LoadRun run, {required bool keepItems}) {
    loading = true;
    refreshing = keepItems && items.isNotEmpty;
    loadingMore = false;
    hasMore = false;
    error = null;
    if (!keepItems) _activeListing = _listings[run.listingKey];
    _timelineChanges = null;
    _dayRequests.clear();
    if (!keepItems) {
      final previous = _listings[run.listingKey];
      items = run.view is AlbumHomeTarget
          ? []
          : previous != null
          ? previous.resolve(fileStore)
          : _seed(_queryFor(run.view));
      if (run.destination == Destination.drive &&
          !FileStore.validChildren(run.path, items)) {
        items = [];
      }
    }
    _visibleListingKey = run.listingKey;
    notifyListeners();
  }

  /// Reads the view's remembered listing from memory or disk and shows it. A
  /// listing that is still fresh is published as is, which ends the load; null
  /// means the load was superseded.
  Future<_CachedListing?> _restoreListing(
    _LoadRun run, {
    required bool keepItems,
  }) async {
    final key = run.listingKey;
    MediaListing? previous = key == null ? null : _listings[key];
    if (previous == null && key != null) {
      final document = await cache?.readDocument(key);
      if (!_isCurrent(run)) return null;
      if (document != null) previous = MediaListing.fromJson(document);
    }
    var known = previous?.resolve(fileStore);
    if (previous?.days != null) timelineIndexAvailable ??= true;
    if (previous != null &&
        known!.length != previous.keys.length &&
        key != null) {
      final persisted = await cache?.readListing(key);
      if (!_isCurrent(run)) return null;
      if (persisted != null) {
        fileStore.putAll(persisted);
        known = previous.resolve(fileStore);
      }
    }
    if (run.destination == Destination.drive &&
        known != null &&
        !FileStore.validChildren(run.path, known)) {
      previous = null;
      known = null;
      items = [];
    }
    if (previous != null && known!.length == previous.keys.length) {
      items = known;
      refreshing = true;
      _hydrate(items.take(_hydrateLimit));
      notifyListeners();
      if (!run.refresh &&
          previous.fresh(fileStore) &&
          run.destination != Destination.offline) {
        if (previous.days != null) timelineIndexAvailable ??= true;
        _activeListing = previous;
        _listings[key!] = previous;
        hasMore = previous.more;
        if (run.destination == Destination.timeline) _libraryFiles = items;
        return _CachedListing(previous, known, fresh: true);
      }
    } else if (key != null) {
      final cached = await cache?.readListing(key);
      if (!_isCurrent(run)) return null;
      if (cached != null) fileStore.putAll(cached);
      final seed = run.destination == Destination.drive && cached != null
          ? {
              for (final file in cached)
                if (file.path.length == run.path.length + 1 &&
                    pathStartsWith(file.path, run.path))
                  file.key: file,
            }.values.toList()
          : cached ?? _seed(_queryFor(run.view));
      if (seed.isNotEmpty && !keepItems) {
        items = seed;
        refreshing = true;
        _hydrate(items.take(_hydrateLimit));
        notifyListeners();
      }
    }
    return _CachedListing(previous, known);
  }

  /// For an opened Smart album, asks the folder's revision. An unchanged
  /// folder republishes the remembered listing and returns null; otherwise
  /// the revision is returned for the new listing.
  Future<({String? etag})?> _checkScope(
    _LoadRun run,
    _CachedListing cached,
  ) async {
    if (cache == null || run.view is! SmartAlbumTarget) return (etag: null);
    final etag = (await client.listFolder(
      run.session!,
      run.path,
      metadataOnly: true,
      optional: true,
    )).revision;
    if (!_isCurrent(run)) return null;
    final previous = cached.previous;
    if (!run.refresh &&
        previous != null &&
        cached.known?.length == previous.keys.length &&
        etag != null &&
        etag == previous.scopeEtag) {
      previous.updated = DateTime.now();
      previous.staleDays.clear();
      await _publishListing(previous, run.listingKey);
      return null;
    }
    return (etag: etag);
  }

  Future<bool> _loadOffline(_LoadRun run, MediaListing listing) async {
    final saved = await cache?.readOfflineListing(_offlineListingKey) ?? [];
    final available = <CloudFile>[];
    for (final file in saved) {
      if (await offlineCopy(file) != null) available.add(file);
    }
    if (!_isCurrent(run)) return false;
    listing.add(fileStore, available);
    return true;
  }

  Future<bool> _loadServerAlbum(
    _LoadRun run,
    MediaListing listing,
    CloudAlbum album,
  ) async {
    final members = await client.albumFiles(run.session!, album);
    if (!_isCurrent(run)) return false;
    listing.add(fileStore, reconcileAlbumMembers(members, _libraryFiles));
    return true;
  }

  Future<bool> _loadFolder(_LoadRun run, MediaListing listing) async {
    final files = await _listFolder(
      run.session!,
      run.path,
      force: run.refresh,
      isCurrent: () => run.version == _loadVersion,
    );
    if (!_isCurrent(run)) return false;
    listing.add(fileStore, files);
    return true;
  }

  /// Timeline-like views: the day index when the server has one, then the
  /// first batch of photos. Days whose index entry and files are unchanged
  /// since the remembered listing are reused.
  Future<bool> _loadIndexed(
    _LoadRun run,
    MediaListing listing,
    _CachedListing cached,
  ) async {
    final session = run.session!;
    final view = run.view;
    if (run.destination != Destination.sharedFolder) {
      await _ensureTimelineIndex(session);
    }
    if (!_isCurrent(run)) return false;
    if (view is PersonTarget && timelineIndexAvailable != true) {
      throw const CloudException(
        'This server does not support browsing people.',
      );
    }
    if (view is MapAreaTarget && timelineIndexAvailable != true) {
      throw const CloudException(
        'This server does not support browsing the photo map.',
      );
    }
    if (timelineIndexAvailable == true &&
        run.destination != Destination.sharedFolder) {
      listing.days = view is TimelineTarget && _initialDays != null
          ? _initialDays
          : (await client.timeline(session, _queryFor(view).index))?.days;
      if (!_isCurrent(run)) return false;
      _initialDays = null;
    }
    listing.more = true;
    _reuseLoadedDays(listing, cached);
    if (listing.loaded.isEmpty) {
      final query = _queryFor(view);
      final page = await _fetcher.next(
        listing,
        session,
        query,
        _storeKey(session),
      );
      if (!_isCurrent(run)) return false;
      _mergePage(listing, page, query);
    }
    return true;
  }

  /// Keeps days whose index entry and cached files are unchanged so
  /// revalidation only downloads days that actually changed.
  void _reuseLoadedDays(MediaListing listing, _CachedListing cached) {
    final previous = cached.previous;
    final days = listing.days;
    if (days == null || !listing.allowCachedDays) return;
    final previousDays = previous?.days;
    if (previousDays == null ||
        previous!.updated.isBefore(fileStore.staleBefore)) {
      return;
    }
    final before = {for (final day in previousDays) day.id: day.count};
    final byDay = <int, List<CloudFile>>{};
    for (final file in cached.known ?? <CloudFile>[]) {
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

  /// Files the shared store already knows for a view, shown instantly while
  /// the server confirms the authoritative list.
  List<CloudFile> _seed(ViewQuery query) {
    final destination = query.destination;
    final path = query.path;
    if (query.target.serverAlbum != null ||
        query.target.person != null ||
        query.target.mapBounds != null ||
        destination == Destination.offline) {
      return [];
    }
    if (destination == Destination.drive) {
      return fileStore.folder(path, fresh: false) ?? [];
    }
    final recursive = query.recursive;
    return fileStore.where(
      (f) =>
          f.isMedia &&
          f.albumReference == null &&
          pathStartsWith(f.path, path) &&
          (recursive || f.path.length == path.length + 1) &&
          (destination != Destination.favorites || f.favorite),
    );
  }

  String _storeKey(Account session) => 'library-v1|${session.storageKey}';

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
    if (cache == null || session == null) return;
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
        final etag = (await client.listFolder(
          session,
          path,
          metadataOnly: true,
        )).revision;
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
    fileStore.putFolder(path, result.children, etag: result.revision);
    _persistStore();
    return result.children;
  }

  Future<void> _ensureTimelineIndex(Account session) async {
    if (timelineIndexAvailable != null) return;
    final pending = _detectingTimelineIndex;
    if (pending != null) return pending;
    final generation = _cacheGeneration;
    final detection = () async {
      final days = (await client.timeline(
        session,
        const TimelineQuery(optional: true),
      ))?.days;
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

  ViewQuery _queryFor(BrowseTarget view) =>
      ViewQuery(view, pathlessTimeline: pathlessTimeline, photoRoot: photoRoot);

  ViewQuery get _query => _queryFor(target);

  /// Whether the loaded view is still the one a request was made for.
  bool _stillShowing(MediaListing listing, Account session, int version) =>
      !_disposed &&
      version == _loadVersion &&
      account == session &&
      identical(_activeListing, listing);

  /// Merges a fetched batch into [listing] and shows it.
  void _mergePage(MediaListing listing, FetchedPage page, ViewQuery query) {
    final gone = listing.merge(fileStore, page);
    if (query.isMainTimeline && gone.isNotEmpty) {
      fileStore.removeKeys(gone);
      for (final cached in _listings.values) {
        cached.replace(const {}, gone);
      }
    }
  }

  Future<void> _publishListing(MediaListing listing, String? key) async {
    listing.pruneEvicted(fileStore);
    _activeListing = listing;
    items = listing.resolve(fileStore);
    hasMore = listing.more;
    if (destination == Destination.timeline) _libraryFiles = items;
    if (destination == Destination.timeline) _prefetch.queue(items);
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
        _fetchingAny ||
        busy ||
        error != null) {
      return;
    }
    final version = _loadVersion;
    final query = _query;
    final key = _listingKey();
    loadingMore = true;
    notifyListeners();
    try {
      final page = await _fetcher.next(
        listing,
        session,
        query,
        _storeKey(session),
      );
      if (version != _loadVersion || account != session || _disposed) return;
      _mergePage(listing, page, query);
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

  bool get _fetchingAny => loading || loadingMore || fetchingDays;

  /// Changes whenever a day of the current view is loaded, dropped or marked
  /// stale, so views can tell when what they derived from the index is out of
  /// date.
  ({int loaded, int stale}) get dayLoadState => (
    loaded: _activeListing?.loaded.length ?? 0,
    stale: _activeListing?.staleDays.length ?? 0,
  );

  /// Whether the photos of an indexed day are already in the current view.
  bool dayLoaded(int day) => _activeListing?.loaded.contains(day) ?? true;
  bool dayNeedsRefresh(int day) =>
      _activeListing?.staleDays.contains(day) ?? false;

  ({List<TimelineDay> days, Set<int> changed, int added})? _timelineChanges;
  bool _checkingChanges = false;
  final ChangeHints _hints = ChangeHints();
  String? _changeOwner;
  String? _changeEtag;
  DateTime? _lastIndexCheck;

  /// True when the server's Timeline differs from what is on screen.
  bool get timelineChanged => _timelineChanges != null;

  /// Photos added on the server since the Timeline was shown.
  int get newPhotos => _timelineChanges?.added ?? 0;

  void _forgetChangeTracking() {
    _changeOwner = null;
    _changeEtag = null;
    _lastIndexCheck = null;
    _hints.clear();
  }

  /// Compares the server with what is shown. Unchanged trees cost one
  /// depth-zero etag request, not a library scan. [changedFileIds] says which
  /// files a push named, and only counts together with [force].
  Future<bool> checkForChanges({
    Set<String>? changedFileIds,
    bool force = false,
  }) async {
    if (force) _hints.add(changedFileIds);
    final session = account;
    if (_checkingChanges ||
        session == null ||
        _fetchingAny ||
        busy ||
        !_browsingActive) {
      return false;
    }
    final hint = _hints.take();
    _checkingChanges = true;
    try {
      final found = await _compareWithServer(session, hint);
      if (found == null) {
        if (hint != null) _hints.add(hint.ids);
        return false;
      }
      return found;
    } catch (e) {
      if (hint != null) _hints.add(hint.ids);
      if (!_disposed && account == session) {
        notice = 'Could not check for library updates. ${errorMessage(e)}';
        notifyListeners();
      }
      rethrow;
    } finally {
      _checkingChanges = false;
    }
  }

  /// Returns whether something changed, or null when the check could not
  /// finish because the view moved on and should be repeated.
  Future<bool?> _compareWithServer(
    Account session,
    ({Set<String>? ids})? hint,
  ) async {
    final listing = _activeListing;
    final loadVersion = _loadVersion;
    final owner = 'changes-v1|${session.storageKey}';
    if (_changeOwner != owner) {
      _changeOwner = owner;
      _changeEtag = (await cache?.readDocument(owner))?['etag'] as String?;
      _lastIndexCheck = null;
    }
    final etag = (await client.listFolder(
      session,
      const [],
      metadataOnly: true,
    )).revision;
    if (_disposed || account != session) return false;
    if (loadVersion != _loadVersion || _fetchingAny) return null;
    final plan = planCheck(
      force: hint != null,
      etag: etag,
      knownEtag: _changeEtag,
      lastIndexCheck: _lastIndexCheck,
      now: DateTime.now(),
    );
    if (plan.idle) return false;
    if (plan.treeChanged) {
      await _invalidateAfterTreeChange(session, hint?.ids);
    } else if (plan.metadataSweep) {
      listing?.markStale();
    }
    Future<void> remember() async {
      _changeEtag = etag;
      await cache?.writeDocument(owner, {'etag': etag});
    }

    final shown = listing?.days;
    if (listing == null || shown == null || target is! TimelineTarget) {
      if (plan.stale) await load(refresh: true);
      if (_disposed || account != session || error != null) return false;
      _lastIndexCheck = DateTime.now();
      await remember();
      return plan.stale;
    }
    final days = (await client.timeline(session, _query.index))?.days;
    if (days == null || !_stillShowing(listing, session, loadVersion)) {
      return false;
    }
    _lastIndexCheck = DateTime.now();
    final changes = diffDays(shown, days);
    if (plan.stale && changes != null) listing.markStale(only: changes.days);
    await remember();
    if (changes == null) {
      if (plan.stale) {
        _persistStore();
        await cache?.writeDocument(_listingKey()!, listing.toJson());
        notifyListeners();
      }
      return plan.stale;
    }
    _timelineChanges = (
      days: days,
      changed: changes.days,
      added: changes.added,
    );
    notifyListeners();
    return true;
  }

  /// A changed tree makes everything cached about it suspect; only the days
  /// a push named stay trusted when it named files this device knows.
  Future<void> _invalidateAfterTreeChange(
    Account session,
    Set<String>? hintedIds,
  ) async {
    _fileResolver.clear();
    await cache?.invalidateListings(_storeKey(session));
    await _invalidateBrowse();
    final days = hintedDays(hintedIds, fileStore.where((_) => true));
    for (final cached in _listings.values) {
      cached.markStale(only: days);
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
    final reload = listing.applyIndex(fileStore, changes.days, changes.changed);
    unawaited(_publishListing(listing, _listingKey()));
    notifyListeners();
    ensureDays(reload);
  }

  /// Loads specific indexed days, such as those the timeline scrolled or was
  /// scrubbed to.
  void ensureDays(Iterable<int> days) {
    final listing = _activeListing;
    if (loading || listing?.days == null || account == null || error != null) {
      return;
    }
    for (final day in days) {
      if (listing!.loaded.contains(day) && !listing.staleDays.contains(day)) {
        continue;
      }
      _dayRequests.request(day);
    }
    if (_browsingActive && !fetchingDays && _dayRequests.isNotEmpty) {
      unawaited(_drainDays());
    }
  }

  Future<void> _drainDays() async {
    fetchingDays = true;
    notifyListeners();
    MediaListing? requestListing;
    Account? requestSession;
    var requestVersion = _loadVersion;
    try {
      while (_dayRequests.isNotEmpty && !_disposed && _browsingActive) {
        final listing = _activeListing;
        final session = account;
        final days = listing?.days;
        if (listing == null || session == null || days == null) break;
        final query = _query;
        final batch = _dayRequests.takeBatch(
          counts: {for (final day in days) day.id: day.count},
          needed: (day) =>
              !listing.loaded.contains(day) || listing.staleDays.contains(day),
          limit: query.dayBatchLimit,
        );
        if (batch.isEmpty) continue;
        requestVersion = _loadVersion;
        requestListing = listing;
        requestSession = session;
        final key = _listingKey();
        final page = await _fetcher.fetchDays(
          listing,
          session,
          query,
          batch,
          _storeKey(session),
        );
        if (!_stillShowing(listing, session, requestVersion)) continue;
        _mergePage(listing, page, query);
        await _publishListing(listing, key);
        notifyListeners();
      }
    } catch (e) {
      if (requestListing != null &&
          _stillShowing(requestListing, requestSession!, requestVersion)) {
        error ??= errorMessage(e);
        _dayRequests.clear();
      }
    } finally {
      fetchingDays = false;
      notifyListeners();
      if (!_disposed &&
          _browsingActive &&
          _dayRequests.isNotEmpty &&
          error == null) {
        unawaited(_drainDays());
      }
    }
  }

  String? _listingKey() {
    final session = account;
    if (session == null) return null;
    return 'browse-v6|${session.storageKey}|${target.cacheKey}';
  }

  Future<void> loadPeople({bool refresh = false}) =>
      _people.load(refresh: refresh);

  Uint8List? cachedPersonPreview(RecognizedPerson person) =>
      _thumbnails.cachedFace(person);

  Future<Uint8List?> restorePersonPreview(RecognizedPerson person) =>
      _thumbnails.restoreFace(person);

  Future<Uint8List> personPreview(RecognizedPerson person) =>
      _thumbnails.face(person);

  static const _coverLookups = 4;

  Future<List<SmartAlbum>> _fetchSharedAlbums(
    Account session,
    bool Function() current,
  ) async {
    final folders = await client.incomingSharedFolders(session);
    final found = <SmartAlbum>[];
    for (var start = 0; start < folders.length; start += _coverLookups) {
      if (!current()) return found;
      final batch = await Future.wait([
        for (final path in folders.skip(start).take(_coverLookups))
          () async {
            final covers = (await client.timeline(
              session,
              TimelineQuery.page(path: path, limit: 1),
            ))!.items!;
            return covers.isEmpty
                ? null
                : SmartAlbum(path: path, files: covers);
          }(),
      ]);
      found.addAll(batch.nonNulls);
    }
    return found
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// After a change, every view keeps showing its (already patched) files
  /// from the shared store and quietly revalidates when next shown.
  Future<void> _invalidateBrowse() async {
    _fileResolver.clear();
    fileStore.markStale();
    if (_activeListing case final listing?) {
      items = listing.resolve(fileStore);
      if (destination == Destination.timeline) _libraryFiles = items;
    }
    _albums.invalidate();
    _shared.invalidate();
    _people.invalidate();
    _initialDays = null;
    notifyListeners();
    _persistStore();
  }

  Future<List<CloudFile>> folderContents(List<String> path) async {
    return _listFolder(account!, path);
  }

  Future<CloudFile?> albumCover(CloudFile folder) =>
      _covers.putIfAbsent(folder.key, () async {
        final known = fileStore
            .where((f) => f.isMedia && pathStartsWith(f.path, folder.path))
            .firstOrNull;
        if (known != null) return known;
        final found = (await client.timeline(
          account!,
          TimelineQuery.page(path: folder.path, limit: 1),
        ))!.items!;
        return found.firstOrNull;
      });

  late final LibraryOperations _ops = LibraryOperations(
    client: client,
    store: fileStore,
    originals: _originalTransfers,
    resolver: _fileResolver,
    account: () => account,
    disposed: () => _disposed,
    status: this,
    directory: () => directory,
    refresh: _refreshAfterChange,
    onChanged: notifyListeners,
  );

  /// Updates every view after the library changed.
  Future<void> _refreshAfterChange({
    required bool coversChanged,
    required bool Function() current,
  }) async {
    if (coversChanged) _covers.clear();
    await _invalidateBrowse();
    if (!current()) return;
    await load();
  }

  Future<bool> organize(
    List<CloudFile> files,
    String operation, {
    List<String>? destination,
    String? newName,
    bool favorite = true,
  }) => _ops.organize(
    files,
    operation,
    destination: destination,
    newName: newName,
    favorite: favorite,
  );

  Future<List<TrashEntry>> trash() => _ops.trash();
  Future<void> restore(TrashEntry entry) => _ops.restore(entry);
  Future<void> favorite(CloudFile file) => _ops.favorite(file);
  Future<void> createFolder(String name) => _ops.createFolder(name);
  Future<void> upload(String name, Stream<List<int>> bytes, int size) =>
      _ops.upload(name, bytes, size);

  void _clearPreviews() {
    _prefetch.clear();
    _fileResolver.clear();
    _thumbnails.clear();
  }

  CloudFile? _applyResolved(CloudFile original, CloudFile? real) {
    final result = reconcileFileLocation(
      fileStore,
      {..._listings.values, ?_activeListing},
      original,
      real,
    );
    if (!result.listingsChanged) return result.file;
    if (_activeListing case final listing?) {
      items = listing.resolve(fileStore);
      if (destination == Destination.timeline) _libraryFiles = items;
    }
    _persistStore();
    notifyListeners();
    return result.file;
  }

  /// Resolved location of [file]; actions call this before touching paths.
  Future<CloudFile> resolve(CloudFile file) => _fileResolver.resolve(file);

  ShareSession shareSession(CloudFile file) {
    final session = account;
    if (session == null || _disposed) {
      throw const CloudException('Sign in to manage share links.');
    }
    return ShareSession(
      client: client,
      account: session,
      file: file,
      isCurrent: () => !_disposed && identical(account, session),
      resolve: resolve,
    );
  }

  PhotoMapSession photoMapSession() {
    final session = account;
    if (session == null || _disposed) {
      throw const CloudException('Sign in to browse your photo map.');
    }
    return PhotoMapSession(
      client: client,
      account: session,
      isCurrent: () => !_disposed && identical(account, session),
    );
  }

  /// Thumbnail already in memory, possibly from an older file revision.
  Uint8List? cachedPreview(CloudFile file, {int size = 384}) =>
      _thumbnails.cached(file, size: size);

  /// Whether [cachedPreview] matches the file's current revision.
  bool previewCurrent(CloudFile file, {int size = 384}) =>
      _thumbnails.current(file, size: size);

  /// See [ThumbnailRepository.preview].
  Future<Uint8List> preview(
    CloudFile file, {
    bool retry = false,
    int size = 384,
    void Function(Uint8List bytes)? stale,
  }) => _thumbnails.preview(file, retry: retry, size: size, stale: stale);

  static const _hydrateLimit = 120;

  /// Brings stored thumbnails for restored content into memory.
  void _hydrate(Iterable<CloudFile> files) =>
      unawaited(_thumbnails.hydrate(files.where((f) => f.isMedia)));

  /// A tile no longer needs [file]'s thumbnail.
  void releasePreview(CloudFile file, {int size = 384}) =>
      _thumbnails.release(file, size: size);

  /// Previously saved original for offline replay, if any.
  Future<File?> offlineCopy(CloudFile file) async {
    final session = account;
    if (cache == null || session == null) return null;
    if (file.pending) {
      // Never block a tile on a path lookup; unresolved items have no copy.
      final known = _fileResolver.cached(file);
      if (known == null) return null;
      file = known;
    }
    return _originalTransfers.offlineCopy(session, file);
  }

  /// Prepares either a saved original or an authenticated seekable stream.
  Future<({File? offline, PlaybackSource? source})> preparePlayback(
    CloudFile file, {
    bool preferStream = false,
  }) async {
    final session = account;
    if (session == null) {
      throw const CloudException('Reconnect to stream this video.');
    }
    final copy = preferStream
        ? null
        : await _originalTransfers.playbackCopy(session, file);
    if (_disposed || !identical(account, session)) {
      throw const CloudException('The account changed. Open this video again.');
    }
    final source = copy == null
        ? await client.playbackSource(session, file)
        : null;
    if (_disposed || !identical(account, session)) {
      throw const CloudException('The account changed. Open this video again.');
    }
    return (offline: copy, source: source);
  }

  /// Explicitly saved original, outside the bounded browsing cache.
  Future<File> saveOffline(CloudFile file) =>
      _ops.download(file, offline: true);

  String get _offlineListingKey =>
      'offline|${account?.storageKey ?? 'null|null'}';

  Future<int> cacheSize() async => await cache?.size() ?? 0;
  Future<int> downloadSize() async => await cache?.downloadSize() ?? 0;

  Future<void> clearCache() async {
    if (busy) {
      throw const CloudException('Wait for the current transfer to finish.');
    }
    _loadVersion++;
    _cacheGeneration++;
    warmUp.cancel();
    loading = false;
    refreshing = false;
    loadingMore = false;
    _dayRequests.clear();
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

  Future<File> download(CloudFile file) => _ops.download(file);

  @override
  void changed() => notifyListeners();

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _backup?.dispose();
    _disposed = true;
    _thumbnails.dispose();
    warmUp.cancel();
    _prefetch.clear();
    _loadVersion++;
    _session.invalidate();
    client.close();
    unawaited(cache?.close());
    super.dispose();
  }
}

/// One load of the library: the view it was started for, and what it needs to
/// tell whether it has been superseded.
class _LoadRun {
  _LoadRun({
    required this.version,
    required this.session,
    required this.view,
    required this.refresh,
    required this.listingKey,
  });

  final int version;
  final Account? session;
  final BrowseTarget view;
  final bool refresh;
  final String? listingKey;

  Destination get destination => view.destination;
  List<String> get path => view.path;
}

/// What was remembered for a view before loading it again. [fresh] means it
/// was current and has already been shown, so there is nothing to fetch.
class _CachedListing {
  _CachedListing(this.previous, this.known, {this.fresh = false});

  final MediaListing? previous;
  final List<CloudFile>? known;
  final bool fresh;
}
