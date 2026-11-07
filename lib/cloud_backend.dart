import 'dart:typed_data';

import 'discovery_models.dart';
import 'models.dart';

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

typedef MediaSource = ({Uri uri, Map<String, String> headers});

class CloudDownload {
  const CloudDownload(this.stream);
  final Stream<List<int>> stream;
}

/// Server operations used by browsing, discovery, transfers and folder sync.
///
/// Paths are account-relative names; album references are opaque to consumers.
/// Optional discovery returns null only when unsupported, never on auth or
/// connection failure. Implementations retain their own protocol fallbacks.
abstract interface class CloudBackend {
  /// Default page length, used by callers for both limits and continuation.
  int get pageSize;
  void close();

  Future<LoginFlow> startLogin(Uri server);
  Future<Account?> pollLogin(Uri server, LoginFlow flow);
  Future<Account> authenticate(
    Uri server,
    String loginName,
    String appPassword,
  );

  MediaSource streamSource(Account account, CloudFile file);
  Future<({CloudFile? self, List<CloudFile> children})> listFolder(
    Account account,
    List<String> path,
  );
  Future<String?> folderEtag(
    Account account,
    List<String> path, {
    bool optional = false,
  });
  Future<List<CloudFile>> search(
    Account account, {
    bool favorites = false,
    List<String> path = const [],
    int offset = 0,
    int limit = 200,
    List<String>? fileIds,
    bool recursive = true,
  });
  Future<({List<CloudFile> files, int scanned})> searchPage(
    Account account, {
    bool favorites = false,
    List<String> path = const [],
    int offset = 0,
    int limit = 200,
    List<String>? fileIds,
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
  Future<List<TimelineDay>> mapDays(
    Account account,
    List<PhotoMapBounds> bounds,
  );
  Future<List<CloudFile>> mapDayFiles(
    Account account,
    List<int> dayIds,
    List<PhotoMapBounds> bounds,
  );
  Future<List<TimelineDay>?> timelineDays(
    Account account, {
    List<String> path = const [],
    bool recursive = true,
    bool favorites = false,
    bool optional = false,
    bool existenceOnly = false,
    RecognizedPerson? person,
    PhotoMapBounds? mapBounds,
  });
  Future<List<CloudFile>> timelineDayFiles(
    Account account,
    List<int> dayIds, {
    List<String> path = const [],
    bool favorites = false,
    bool recursive = true,
    bool resolvePaths = true,
    RecognizedPerson? person,
    PhotoMapBounds? mapBounds,
  });
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
  Future<void> transfer(
    Account account,
    CloudFile file,
    List<String> destination, {
    bool copy = false,
  });
  Future<void> delete(Account account, CloudFile file);
  Future<void> createFolder(Account account, List<String> path);
  Future<void> setFavorite(Account account, CloudFile file, bool value);
  Future<void> upload(
    Account account,
    List<String> path,
    Stream<List<int>> bytes,
    int size,
  );
  Future<CloudDownload> download(Account account, CloudFile file);

  /// Downloads only [file]'s inventoried revision, failing if it has changed.
  Future<CloudDownload> downloadVersion(Account account, CloudFile file);
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
