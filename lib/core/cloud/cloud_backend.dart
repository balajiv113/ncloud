import 'dart:typed_data';

import '../../discovery_models.dart';
import '../../models.dart';

class CloudException implements Exception {
  const CloudException(this.message, {this.statusCode, this.retryable = false});
  final String message;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() => message;
}

/// Browser authorization URL; adapter-specific polling state stays private.
abstract interface class LoginFlow {
  Uri get login;
}

typedef PlaybackSource = ({Uri uri, Map<String, String> headers});

class CloudDownload {
  const CloudDownload(this.file, this.stream);

  /// Metadata of the downloaded file, including its account-relative path.
  final CloudFile file;
  final Stream<List<int>> stream;
}

class FolderListing {
  const FolderListing({this.self, this.children = const [], this.revision});

  final CloudFile? self;
  final List<CloudFile> children;
  final String? revision;
}

/// Sparse provider metadata for an album member. Missing fields are unknown,
/// rather than zero, false or empty, and can be reconciled with cached files.
class CloudAlbumMember {
  const CloudAlbumMember({
    required this.reference,
    this.id,
    this.originalName,
    this.displayName,
    this.contentType,
    this.size,
    this.modified,
    this.revision,
    this.favorite,
  });

  final List<String> reference;
  final String? id;
  final String? originalName;
  final String? displayName;
  final String? contentType;
  final int? size;
  final DateTime? modified;
  final String? revision;
  final bool? favorite;
}

/// A timeline request. A null [dayIds] requests the day index; otherwise only
/// the specified days are loaded. Use [TimelineQuery.page] for unindexed
/// browsing. [optional] applies to index requests; [resolvePaths] applies to
/// indexed items.
class TimelineQuery {
  const TimelineQuery({
    this.dayIds,
    this.path = const [],
    this.recursive = true,
    this.favorites = false,
    this.optional = false,
    this.resolvePaths = true,
    this.person,
    this.mapBounds,
  }) : paged = false,
       cursor = null,
       limit = 200;

  const TimelineQuery.page({
    this.path = const [],
    this.recursive = true,
    this.favorites = false,
    this.cursor,
    this.limit = 200,
  }) : dayIds = null,
       optional = false,
       resolvePaths = true,
       person = null,
       mapBounds = null,
       paged = true;

  final List<int>? dayIds;
  final List<String> path;
  final bool recursive;
  final bool favorites;
  final bool optional;
  final bool resolvePaths;
  final RecognizedPerson? person;

  /// Null means no geographic filter; an empty list is invalid.
  final List<PhotoMapBounds>? mapBounds;
  final bool paged;
  final String? cursor;
  final int limit;
}

class TimelineResult {
  const TimelineResult.index(List<TimelineDay> this.days)
    : items = null,
      nextCursor = null;
  const TimelineResult.items(List<CloudFile> this.items)
    : days = null,
      nextCursor = null;
  const TimelineResult.page(List<CloudFile> this.items, this.nextCursor)
    : days = null;

  /// Only the field corresponding to the request is populated.
  final List<TimelineDay>? days;
  final List<CloudFile>? items;

  /// Opaque page continuation, scoped to the same account and query.
  final String? nextCursor;
}

/// Server operations used by browsing, discovery, transfers and folder sync.
///
/// Paths are account-relative names; album references are opaque to consumers.
/// Optional discovery returns null only when unsupported, never on auth or
/// connection failure. Implementations retain their own protocol fallbacks.
abstract interface class CloudBackend {
  void close();

  /// Decode a session written by this provider; reject other providers.
  Account restoreAccount(String value);
  Future<LoginFlow> startLogin(Uri server);
  Future<Account?> pollLogin(Uri server, LoginFlow flow);
  Future<Account> authenticate(
    Uri server,
    String loginName,
    String appPassword,
  );

  /// A seekable authenticated stream. Providers accept pathless timeline items.
  Future<PlaybackSource> playbackSource(Account account, CloudFile file);

  /// Metadata-only inspection need not enumerate children. With [optional],
  /// an unsupported inspection returns a null revision; failures still throw.
  Future<FolderListing> listFolder(
    Account account,
    List<String> path, {
    bool metadataOnly = false,
    bool optional = false,
  });

  Future<Map<String, CloudFile>> resolveFileIds(
    Account account,
    List<String> ids,
  );

  Future<List<CloudAlbum>> albums(Account account, {bool shared = false});
  Future<List<CloudAlbumMember>> albumFiles(Account account, CloudAlbum album);
  Future<List<List<String>>> incomingSharedFolders(Account account);
  Future<List<RecognizedPerson>?> people(
    Account account, {
    List<String> path = const [],
    bool optional = false,
  });
  Future<Uint8List> personPreview(Account account, RecognizedPerson person);
  Future<PhotoLocation?> mapPosition(Account account);
  Future<List<PhotoMapCluster>> mapClusters(
    Account account, {
    required PhotoMapBounds bounds,
    required int zoom,
    List<String> path = const [],
  });

  /// Null means the optional indexed timeline is unsupported. Empty results
  /// are successful responses; other failures must be surfaced. Page cursors
  /// are valid only for the same account and query.
  Future<TimelineResult?> timeline(Account account, TimelineQuery query);

  /// Inspects an indexed folder for direct media and descendant candidates.
  /// [includeChildrenWithMedia] keeps walking the source root even if it has
  /// loose photos; returned children contain media in their subtrees.
  Future<({List<CloudFile> covers, List<PhotoFolder> children})> photoFolder(
    Account account,
    PhotoFolder folder, {
    bool includeChildrenWithMedia = false,
  });

  /// Results correspond positionally to the requested files. Null entries may
  /// be retried singly; request failures must throw rather than appear empty.
  Future<List<Uint8List?>> previews(
    Account account,
    List<CloudFile> files, {
    int size = 384,
  });
  Future<void> move(Account account, CloudFile file, List<String> destination);
  Future<void> copy(Account account, CloudFile file, List<String> destination);
  Future<void> delete(Account account, CloudFile file);
  Future<void> createFolder(Account account, List<String> path);
  Future<void> setFavorite(Account account, CloudFile file, bool value);

  /// Atomically creates a new file and fails if the destination exists.
  Future<void> uploadNew(
    Account account,
    List<String> path,
    Stream<List<int>> bytes,
    int size,
  );

  /// Accepts pathless items. If [expectedRevision] is supplied, fails unless
  /// that revision is read; returned metadata identifies the downloaded file.
  Future<CloudDownload> download(
    Account account,
    CloudFile file, {
    String? expectedRevision,
  });
  Future<List<TrashEntry>> trash(Account account);
  Future<void> restore(Account account, TrashEntry entry);
  Future<List<PublicShare>> shares(Account account, CloudFile file);
  Future<PublicShare> createShare(
    Account account,
    CloudFile file, {
    String? password,
    DateTime? expires,
  });
  Future<void> revokeShare(Account account, PublicShare share);

  /// Optional server hints. Polling remains active when the stream is empty.
  /// A null event invalidates the scope; a set identifies changed file IDs.
  Stream<Set<String>?> changes(Account account);
}
