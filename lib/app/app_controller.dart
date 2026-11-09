import '../features/backup/background/backup_scheduler.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../features/account/account_session.dart';
import '../features/albums/album_catalogue.dart';
import '../features/timeline/change_monitor.dart';
import '../diagnostics.dart';
import 'status_sink.dart';
import '../discovery_models.dart';
import '../core/storage/file_store.dart';
import '../features/backup/state/backup_controller.dart';
import '../core/storage/local_cache.dart';
import '../models.dart';
import '../features/files/library_operations.dart';
import '../features/timeline/library_warm_up.dart';
import '../features/files/file_resolver.dart';
import '../features/files/original_transfers.dart';
import '../features/files/share_session.dart';
import '../features/map/photo_map_session.dart';
import '../features/viewer/live_photo_clips.dart';
import 'browse_target.dart';
import 'library_browser.dart';
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

  Account? account;
  bool get starting => _session.starting;
  set starting(bool value) => _session.starting = value;
  bool get signingIn => _session.signingIn;
  bool get busy => _ops.busy;
  set busy(bool value) => _ops.busy = value;

  /// What is on screen and how it is loaded.
  late final LibraryBrowser _browser = LibraryBrowser(
    client: client,
    cache: cache,
    host: _BrowserHost(this),
    pathlessTimeline: pathlessTimeline,
  );
  List<CloudFile> get items => _browser.items;
  bool get loading => _browser.loading;
  bool get loadingMore => _browser.loadingMore;
  @visibleForTesting
  set loadingMore(bool value) => _browser.loadingMore = value;

  /// True while showing locally cached results that are being refreshed.
  bool get refreshing => _browser.refreshing;
  @visibleForTesting
  set refreshing(bool value) => _browser.refreshing = value;
  bool get hasMore => _browser.hasMore;

  /// True while days requested by the scrolling timeline are downloading.
  bool get fetchingDays => _browser.fetchingDays;
  bool? get timelineIndexAvailable => _browser.timelineIndexAvailable;
  set timelineIndexAvailable(bool? value) =>
      _browser.timelineIndexAvailable = value;

  /// The one cache of files shared by Timeline, Albums, Shared and Drive.
  FileStore get fileStore => _browser.fileStore;
  bool get discoveringAlbums => _albums.discovering;
  int get discoveredFolders => _albums.discovered;
  bool get albumHome => target is AlbumHomeTarget;
  List<RecognizedPerson> get people => _people.value;
  @visibleForTesting
  set people(List<RecognizedPerson> value) => _people.value = value;
  bool get loadingPeople => _people.loading;
  bool? get peopleAvailable => _people.available;
  String? get peopleError => _people.error;
  List<TimelineDay> get indexedDays => _browser.indexedDays;
  List<CloudAlbum> get nativeAlbums => _albums.server;
  String? get nativeAlbumError => _albums.serverError;
  String? get catalogueError => _albums.error;
  List<SmartAlbum> get sharedAlbums => _shared.value;
  String? get sharedAlbumError => _shared.error;
  bool get loadingSharedAlbums => _shared.loading;
  List<CloudFile> get libraryFiles => _browser.libraryFiles;
  List<String> get photoRoot =>
      account?.photoRoot ??
      _albums.autoRoot ??
      (libraryFiles.any((f) => f.path.firstOrNull == 'Photos')
          ? ['Photos']
          : []);
  List<SmartAlbum> get smartAlbums => _albums.smart;
  int get completed => _ops.completed;
  int get total => _ops.total;

  /// What the library is showing. The fields below read it.
  BrowseTarget get target => _browser.target;
  set target(BrowseTarget value) => _browser.target = value;
  Destination get destination => target.destination;
  List<String> get directory => target.path;
  bool get smartAlbumOpen => target is SmartAlbumTarget;
  CloudAlbum? get activeCloudAlbum => target.serverAlbum;
  RecognizedPerson? get activePerson => target.person;
  List<PhotoMapBounds>? get activeMapBounds => target.mapBounds;
  @override
  String? error;
  @override
  String? notice;
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
    listFolder: _browser.listFolder,
    ensureIndex: _browser.ensureTimelineIndex,
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
    apply: _browser.reconcile,
  );
  late final LivePhotoClips _liveClips = LivePhotoClips(
    client: client,
    directory: () async =>
        await cache?.folder('live-photos') ??
        Directory('${Directory.systemTemp.path}/ncloud-live'),
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
      _browser.resumeDayRequests();
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
        await cache?.readOfflineListing(_browser.offlineListingKey);
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
    listingKey: () => _browser.listingKey()!,
    load: () => _browser.load(refresh: false),
    activeListing: () => _browser.activeListing,
    loadNextPage: _browser.loadNextPage,
    loadCatalogue: () =>
        Future.wait([_albums.load(), _shared.load(), loadPeople()]),
    items: () => _browser.items,
    preview: (file) => preview(file),
    storeWritten: () => _browser.storeWritten,
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
    await step(_browser.releaseStore);
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
      _session.invalidate();
      _clearPreviews();
      _covers.clear();
      warmUp.cancel();
      account = null;
      Diagnostics.session.clear();
      _browser.reset();
      _albums.reset();
      _shared.reset();
      _people.reset();
      notice = null;
    } catch (e) {
      error =
          'Could not completely clear local session data. ${errorMessage(e)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Opens [next] and loads it.
  Future<void> open(BrowseTarget next) => _browser.open(next);

  Future<void> load({bool refresh = true}) => _browser.load(refresh: refresh);
  Future<void> loadNextPage() => _browser.loadNextPage();
  Future<bool> checkForChanges({
    Set<String>? changedFileIds,
    bool force = false,
  }) => _browser.checkForChanges(changedFileIds: changedFileIds, force: force);
  void applyChanges() => _browser.applyChanges();
  void ensureDays(Iterable<int> days) => _browser.ensureDays(days);
  bool dayLoaded(int day) => _browser.dayLoaded(day);
  bool dayNeedsRefresh(int day) => _browser.dayNeedsRefresh(day);
  ({int loaded, int stale}) get dayLoadState => _browser.dayLoadState;

  /// True when the server's Timeline differs from what is on screen.
  bool get timelineChanged => _browser.timelineChanged;

  /// Photos added on the server since the Timeline was shown.
  int get newPhotos => _browser.newPhotos;

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

  Future<List<CloudFile>> folderContents(List<String> path) async {
    return _browser.listFolder(account!, path);
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
    await _browser.invalidate();
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

  /// The short video of a Live Photo, as a local file ready to play.
  Future<File> livePhotoClip(CloudFile file) async {
    final session = account;
    if (session == null) {
      throw const CloudException('Reconnect to play this Live Photo.');
    }
    final clip = await _liveClips.clip(session, file);
    if (_disposed || !identical(account, session)) {
      throw const CloudException('The account changed. Open this photo again.');
    }
    return clip;
  }

  /// Explicitly saved original, outside the bounded browsing cache.
  Future<File> saveOffline(CloudFile file) =>
      _ops.download(file, offline: true);

  Future<int> cacheSize() async => await cache?.size() ?? 0;
  Future<int> downloadSize() async => await cache?.downloadSize() ?? 0;

  Future<void> clearCache() async {
    if (busy) {
      throw const CloudException('Wait for the current transfer to finish.');
    }
    warmUp.cancel();
    _clearPreviews();
    _covers.clear();
    await _browser.clear();
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
    _browser.cancelLoads();
    _session.invalidate();
    client.close();
    unawaited(cache?.close());
    super.dispose();
  }
}

/// What the library browser asks of the app controller, without making those
/// calls part of the controller's own interface.
class _BrowserHost implements BrowserHost {
  _BrowserHost(this._c);

  final AppController _c;

  @override
  Account? get account => _c.account;
  @override
  bool get disposed => _c._disposed;
  @override
  bool get browsingActive => _c._browsingActive;
  @override
  bool get transferring => _c.busy;
  @override
  List<String> get photoRoot => _c.photoRoot;
  @override
  String? get error => _c.error;
  @override
  set error(String? value) => _c.error = value;
  @override
  String? get notice => _c.notice;
  @override
  set notice(String? value) => _c.notice = value;
  @override
  void changed() => _c.notifyListeners();
  @override
  void hydrate(Iterable<CloudFile> files) => _c._hydrate(files);
  @override
  void queuePrefetch(List<CloudFile> files) => _c._prefetch.queue(files);
  @override
  void clearFileResolver() => _c._fileResolver.clear();
  @override
  Future<File?> offlineCopy(CloudFile file) => _c.offlineCopy(file);
  @override
  Future<void> loadCatalogue({required bool refresh}) => Future.wait([
    _c._albums.load(refresh: refresh),
    _c._shared.load(refresh: refresh),
    _c.loadPeople(refresh: refresh),
  ]);
  @override
  void invalidateCatalogue() {
    _c._albums.invalidate();
    _c._shared.invalidate();
    _c._people.invalidate();
  }
}
