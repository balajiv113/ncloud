import 'dart:async';
import 'dart:io';

import '../core/cloud/cloud_backend.dart';
import '../core/storage/file_store.dart';
import '../core/storage/local_cache.dart';
import '../core/storage/media_listing.dart';
import '../diagnostics.dart';
import '../features/albums/album_members.dart';
import '../features/files/file_resolver.dart';
import '../features/timeline/change_detection.dart';
import '../features/timeline/day_batches.dart';
import '../features/timeline/timeline_fetcher.dart';
import '../features/timeline/view_query.dart';
import '../models.dart';
import 'browse_target.dart';
import 'status_sink.dart';

/// What the library browser needs from the app around it. Errors and notices
/// go to the [StatusSink]; everything else is a question or a request.
abstract interface class BrowserHost implements StatusSink {
  Account? get account;
  bool get disposed;

  /// Whether the app is in the foreground and should fetch.
  bool get browsingActive;

  /// Whether a file operation or transfer is running.
  bool get transferring;

  /// The folder the account keeps its photos in.
  List<String> get photoRoot;

  /// Brings stored thumbnails for restored files into memory.
  void hydrate(Iterable<CloudFile> files);

  /// Offers the Timeline's files to the background thumbnail prefetcher.
  void queuePrefetch(List<CloudFile> files);

  void clearFileResolver();

  /// A saved original for offline replay, if there is one.
  Future<File?> offlineCopy(CloudFile file);

  /// Loads the albums, shared albums and people the Albums list shows.
  Future<void> loadCatalogue({required bool refresh});

  /// Marks the albums, shared albums and people as needing a refresh.
  void invalidateCatalogue();
}

/// What the library shows and how it is loaded: the current target, its files
/// and paging, the listings remembered for other views, the shared file store,
/// the Timeline's day requests, and the checks that notice server changes.
class LibraryBrowser {
  LibraryBrowser({
    required this.client,
    required this.cache,
    required this.host,
    required this.pathlessTimeline,
  });

  final CloudBackend client;
  final LocalCache? cache;
  final BrowserHost host;

  /// Paints the Timeline straight from indexed day rows and resolves real paths
  /// only when an action needs them.
  final bool pathlessTimeline;

  /// What the library is showing. The getters below read it.
  BrowseTarget target = const TimelineTarget();
  Destination get destination => target.destination;
  List<String> get directory => target.path;

  List<CloudFile> items = [];

  /// True while showing locally cached results that are being refreshed.
  bool refreshing = false;
  bool loading = false;
  bool loadingMore = false;
  bool hasMore = false;

  /// True while days requested by the scrolling timeline are downloading.
  bool fetchingDays = false;
  bool? timelineIndexAvailable;

  /// The one cache of files shared by Timeline, Albums, Shared and Drive.
  final FileStore fileStore = FileStore();
  final Map<String, MediaListing> _listings = {};
  MediaListing? _activeListing;
  String? _visibleListingKey;
  List<CloudFile> _libraryFiles = [];
  List<TimelineDay>? _initialDays;
  Future<void>? _detectingTimelineIndex;
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
  int _loadVersion = 0;
  int _cacheGeneration = 0;

  static const _hydrateLimit = 120;

  List<TimelineDay> get indexedDays => _activeListing?.days ?? [];
  List<CloudFile> get libraryFiles => _libraryFiles;
  MediaListing? get activeListing => _activeListing;

  /// Completes when the library's pending metadata write has finished.
  Future<void>? get storeWritten => _storeWrite;

  /// Opens [next] and loads it.
  Future<void> open(BrowseTarget next) {
    target = next;
    return load(refresh: false);
  }

  /// After a change, every view keeps showing its (already patched) files
  /// from the shared store and quietly revalidates when next shown.
  Future<void> invalidate() async {
    host.clearFileResolver();
    fileStore.markStale();
    if (_activeListing case final listing?) {
      items = listing.resolve(fileStore);
      if (destination == Destination.timeline) _libraryFiles = items;
    }
    host.invalidateCatalogue();
    _initialDays = null;
    host.changed();
    _persistStore();
  }

  /// Applies a file's resolved location to the store and every listing, and
  /// returns the file to use.
  CloudFile? reconcile(CloudFile original, CloudFile? real) {
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
    host.changed();
    return result.file;
  }

  /// Lets go of the saved store before it is deleted from disk.
  Future<void> releaseStore() async {
    _storeOwner = null;
    await _storeWrite;
  }

  /// Forgets everything about the signed-in account.
  void reset() {
    _loadVersion++;
    forgetChangeTracking();
    _libraryFiles = [];
    _listings.clear();
    fileStore.clear();
    _storeOwner = null;
    _restoringStore = null;
    _dayRequests.clear();
    _activeListing = null;
    _visibleListingKey = null;
    timelineIndexAvailable = null;
    _initialDays = null;
    _detectingTimelineIndex = null;
    items = [];
    target = const TimelineTarget();
    loading = false;
  }

  /// Drops every loaded and remembered file and stops loads in progress, ahead
  /// of the on-disk cache being cleared.
  Future<void> clear() async {
    _loadVersion++;
    _cacheGeneration++;
    loading = false;
    refreshing = false;
    loadingMore = false;
    _dayRequests.clear();
    _initialDays = null;
    _detectingTimelineIndex = null;
    host.clearFileResolver();
    await invalidate();
    _listings.clear();
    fileStore.clear();
    _activeListing = null;
    hasMore = false;
    await _storeWrite;
  }

  /// Resumes loading days the Timeline asked for while the app was away.
  void resumeDayRequests() {
    if (!fetchingDays && _dayRequests.isNotEmpty && host.error == null) {
      unawaited(_drainDays());
    }
  }

  /// Ends loads still running; used when the app is shutting down.
  void cancelLoads() => _loadVersion++;

  Future<void> load({bool refresh = true}) async {
    final run = _LoadRun(
      version: ++_loadVersion,
      session: host.account,
      view: target,
      refresh: refresh,
      listingKey: listingKey(),
    );
    if (refresh) _initialDays = null;
    final keepItems =
        run.listingKey != null && run.listingKey == _visibleListingKey;
    _startLoad(run, keepItems: keepItems);
    try {
      final session = run.session;
      if (session == null) return;
      if (run.view is AlbumHomeTarget) {
        await host.loadCatalogue(refresh: refresh);
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
      if (run.version == _loadVersion) host.error = errorMessage(e);
    } finally {
      if (run.version == _loadVersion) {
        loading = false;
        refreshing = false;
        loadingMore = false;
        if (destination == Destination.timeline) host.queuePrefetch(items);
        host.changed();
      }
    }
  }

  /// Whether [run] is still the load that should publish: nothing newer has
  /// started and the account is unchanged.
  bool _isCurrent(_LoadRun run) =>
      run.version == _loadVersion &&
      !host.disposed &&
      host.account == run.session;

  /// Shows what is already known for the view while the load runs.
  void _startLoad(_LoadRun run, {required bool keepItems}) {
    loading = true;
    refreshing = keepItems && items.isNotEmpty;
    loadingMore = false;
    hasMore = false;
    host.error = null;
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
    host.changed();
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
      host.hydrate(items.take(_hydrateLimit));
      host.changed();
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
        host.hydrate(items.take(_hydrateLimit));
        host.changed();
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

  String get offlineListingKey =>
      'offline|${host.account?.storageKey ?? 'null|null'}';

  Future<bool> _loadOffline(_LoadRun run, MediaListing listing) async {
    final saved = await cache?.readOfflineListing(offlineListingKey) ?? [];
    final available = <CloudFile>[];
    for (final file in saved) {
      if (await host.offlineCopy(file) != null) available.add(file);
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
    final files = await listFolder(
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
      await ensureTimelineIndex(session);
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
          !host.disposed) {
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
    final session = host.account;
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
  Future<List<CloudFile>> listFolder(
    Account session,
    List<String> path, {
    bool force = false,
    bool Function()? isCurrent,
  }) async {
    final generation = _cacheGeneration;
    bool current() =>
        host.account == session &&
        !host.disposed &&
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

  Future<void> ensureTimelineIndex(Account session) async {
    if (timelineIndexAvailable != null) return;
    final pending = _detectingTimelineIndex;
    if (pending != null) return pending;
    final generation = _cacheGeneration;
    final detection = () async {
      final days = (await client.timeline(
        session,
        const TimelineQuery(optional: true),
      ))?.days;
      if (host.account != session ||
          host.disposed ||
          generation != _cacheGeneration) {
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

  ViewQuery _queryFor(BrowseTarget view) => ViewQuery(
    view,
    pathlessTimeline: pathlessTimeline,
    photoRoot: host.photoRoot,
  );

  ViewQuery get _query => _queryFor(target);

  /// Whether the loaded view is still the one a request was made for.
  bool _stillShowing(MediaListing listing, Account session, int version) =>
      !host.disposed &&
      version == _loadVersion &&
      host.account == session &&
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
    if (destination == Destination.timeline) host.queuePrefetch(items);
    if (key != null) {
      _listings[key] = listing;
      if (_listings.length > 20) _listings.remove(_listings.keys.first);
      _persistStore();
      await cache?.writeDocument(key, listing.toJson());
    }
  }

  Future<void> loadNextPage() async {
    final listing = _activeListing;
    final session = host.account;
    if (listing == null ||
        session == null ||
        !listing.more ||
        _fetchingAny ||
        host.transferring ||
        host.error != null) {
      return;
    }
    final version = _loadVersion;
    final query = _query;
    final key = listingKey();
    loadingMore = true;
    host.changed();
    try {
      final page = await _fetcher.next(
        listing,
        session,
        query,
        _storeKey(session),
      );
      if (version != _loadVersion || host.account != session || host.disposed) {
        return;
      }
      _mergePage(listing, page, query);
      await _publishListing(listing, key);
    } catch (e) {
      if (version == _loadVersion) host.error = errorMessage(e);
    } finally {
      if (version == _loadVersion) {
        loadingMore = false;
        host.changed();
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

  void forgetChangeTracking() {
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
    final session = host.account;
    if (_checkingChanges ||
        session == null ||
        _fetchingAny ||
        host.transferring ||
        !host.browsingActive) {
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
      if (!host.disposed && host.account == session) {
        host.notice = 'Could not check for library updates. ${errorMessage(e)}';
        host.changed();
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
    if (host.disposed || host.account != session) return false;
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
      if (host.disposed || host.account != session || host.error != null) {
        return false;
      }
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
        await cache?.writeDocument(listingKey()!, listing.toJson());
        host.changed();
      }
      return plan.stale;
    }
    _timelineChanges = (
      days: days,
      changed: changes.days,
      added: changes.added,
    );
    host.changed();
    return true;
  }

  /// A changed tree makes everything cached about it suspect; only the days
  /// a push named stay trusted when it named files this device knows.
  Future<void> _invalidateAfterTreeChange(
    Account session,
    Set<String>? hintedIds,
  ) async {
    host.clearFileResolver();
    await cache?.invalidateListings(_storeKey(session));
    await invalidate();
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
      host.changed();
      return;
    }
    final reload = listing.applyIndex(fileStore, changes.days, changes.changed);
    unawaited(_publishListing(listing, listingKey()));
    host.changed();
    ensureDays(reload);
  }

  /// Loads specific indexed days, such as those the timeline scrolled or was
  /// scrubbed to.
  void ensureDays(Iterable<int> days) {
    final listing = _activeListing;
    if (loading ||
        listing?.days == null ||
        host.account == null ||
        host.error != null) {
      return;
    }
    for (final day in days) {
      if (listing!.loaded.contains(day) && !listing.staleDays.contains(day)) {
        continue;
      }
      _dayRequests.request(day);
    }
    if (host.browsingActive && !fetchingDays && _dayRequests.isNotEmpty) {
      unawaited(_drainDays());
    }
  }

  Future<void> _drainDays() async {
    fetchingDays = true;
    host.changed();
    MediaListing? requestListing;
    Account? requestSession;
    var requestVersion = _loadVersion;
    try {
      while (_dayRequests.isNotEmpty && !host.disposed && host.browsingActive) {
        final listing = _activeListing;
        final session = host.account;
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
        final key = listingKey();
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
        host.changed();
      }
    } catch (e) {
      if (requestListing != null &&
          _stillShowing(requestListing, requestSession!, requestVersion)) {
        host.error ??= errorMessage(e);
        _dayRequests.clear();
      }
    } finally {
      fetchingDays = false;
      host.changed();
      if (!host.disposed &&
          host.browsingActive &&
          _dayRequests.isNotEmpty &&
          host.error == null) {
        unawaited(_drainDays());
      }
    }
  }

  String? listingKey() {
    final session = host.account;
    if (session == null) return null;
    return 'browse-v6|${session.storageKey}|${target.cacheKey}';
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
