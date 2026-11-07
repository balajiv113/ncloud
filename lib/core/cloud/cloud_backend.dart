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
  const CloudDownload(this.stream);
  final Stream<List<int>> stream;
}

/// An indexed timeline request. A null [dayIds] requests the day index;
/// otherwise only the specified days are loaded. [optional] and
/// [existenceOnly] apply to index requests; [resolvePaths] applies to items.
class TimelineQuery {
  const TimelineQuery({
    this.dayIds,
    this.path = const [],
    this.recursive = true,
    this.favorites = false,
    this.optional = false,
    this.existenceOnly = false,
    this.resolvePaths = true,
    this.person,
    this.mapBounds,
  });

  final List<int>? dayIds;
  final List<String> path;
  final bool recursive;
  final bool favorites;
  final bool optional;
  final bool existenceOnly;
  final bool resolvePaths;
  final RecognizedPerson? person;

  /// Null means no geographic filter; an empty list is invalid.
  final List<PhotoMapBounds>? mapBounds;
}

class TimelineResult {
  const TimelineResult.index(this.days) : items = null;
  const TimelineResult.items(this.items) : days = null;

  /// Only the field corresponding to the request is populated.
  final List<TimelineDay>? days;
  final List<CloudFile>? items;
}

class MediaPage {
  const MediaPage({required this.items, this.nextCursor});

  final List<CloudFile> items;

  /// Opaque continuation token; null indicates the end of the listing.
  final String? nextCursor;
}

/// Server operations used by browsing, discovery, transfers and folder sync.
///
/// Paths are account-relative names; album references are opaque to consumers.
/// Optional discovery returns null only when unsupported, never on auth or
/// connection failure. Implementations retain their own protocol fallbacks.
abstract interface class CloudBackend {
  void close();

  Future<LoginFlow> startLogin(Uri server);
  Future<Account?> pollLogin(Uri server, LoginFlow flow);
  Future<Account> authenticate(
    Uri server,
    String loginName,
    String appPassword,
  );

  PlaybackSource playbackSource(Account account, CloudFile file);
  Future<({CloudFile? self, List<CloudFile> children})> listFolder(
    Account account,
    List<String> path,
  );
  Future<String?> folderEtag(
    Account account,
    List<String> path, {
    bool optional = false,
  });

  /// The cursor is meaningful only for the same account and query.
  Future<MediaPage> mediaPage(
    Account account, {
    bool favorites = false,
    List<String> path = const [],
    String? cursor,
    int limit = 200,
    bool recursive = true,
  });
  Future<Map<String, CloudFile>> resolveFileIds(
    Account account,
    List<String> ids, {
    int concurrency = 4,
  });

  Future<List<CloudAlbum>> albums(Account account, {bool shared = false});
  Future<List<CloudFile>> albumFiles(
    Account account,
    CloudAlbum album,
    List<CloudFile> library,
  );
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
  /// are successful responses; other failures must be surfaced.
  Future<TimelineResult?> timeline(Account account, TimelineQuery query);
  Future<List<TimelineFolder>> timelineFolders(
    Account account,
    List<String> path,
  );
  Future<List<CloudFile>> timelineCover(
    Account account,
    List<String> path,
    int day,
  );

  Future<Uint8List> preview(Account account, CloudFile file, {int size = 384});
  Future<Map<String, Uint8List>> multipreview(
    Account account,
    List<String> fileIds, {
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

  /// If [expectedRevision] is supplied, fails unless that revision is read.
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
