Uri normalizeServer(String input) {
  if (RegExp(
    r'/(?:\.|%2e){1,2}(?:/|$)',
    caseSensitive: false,
  ).hasMatch(input.trim())) {
    throw const FormatException('The server address contains an invalid path.');
  }
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Enter a full HTTPS server address, such as https://cloud.example.com.',
    );
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.any((s) => s == '.' || s == '..')) {
    throw const FormatException('The server address contains an invalid path.');
  }
  return uri.replace(pathSegments: segments);
}

abstract class Account {
  const Account();

  /// Stable namespace, formatted as two non-secret components separated by
  /// `|`, with no additional separators. Storage uses those components to
  /// isolate an account's collections.
  String get storageKey;
  String get displayName;
  String get serverLabel;
  List<String>? get photoRoot;
  Account withPhotoRoot(List<String> path);
  String encode();

  bool sameOwner(Account other) => storageKey == other.storageKey;
}

/// Whether a file or folder is shared, and in which direction.
enum Sharing {
  none,

  /// This account shares it with others.
  byMe,

  /// Someone else shares it with this account.
  withMe,
}

class CloudFile {
  const CloudFile({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.contentType = '',
    this.size = 0,
    this.modified,
    this.id,
    this.favorite = false,
    this.albumReference,
    this.taken,
    this.captureDay,
    this.etag,
    this.sharing = Sharing.none,
    this.liveId,
  });

  final List<String> path;
  final String name;
  final bool isDirectory;
  final String contentType;
  final int size;
  final DateTime? modified;
  final String? id;
  final bool favorite;

  /// Backend-owned location for an album member without an account file path.
  final List<String>? albumReference;
  final DateTime? taken;
  final int? captureDay;
  final String? etag;
  final Sharing sharing;

  /// Identifies the short video that goes with this photo, when it is a Live
  /// Photo (an iPhone Live Photo or an Android motion photo).
  final String? liveId;
  bool get isLive => liveId != null;
  DateTime? get timelineDate {
    if (captureDay case final day?) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        day * 86400000,
        isUtc: true,
      );
      return DateTime(date.year, date.month, date.day);
    }
    return taken ?? modified;
  }

  bool get readOnly => albumReference != null;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'dir': isDirectory,
    'type': contentType,
    'size': size,
    'modified': modified?.toUtc().toIso8601String(),
    'id': id,
    'favorite': favorite,
    'albumReference': albumReference,
    'taken': taken?.toIso8601String(),
    'captureDay': captureDay,
    'etag': etag,
    'sharing': sharing.name,
    'liveId': liveId,
  };

  factory CloudFile.fromJson(Map<String, dynamic> json) => CloudFile(
    path: (json['path'] as List<dynamic>).cast<String>(),
    name: json['name'] as String,
    isDirectory: json['dir'] as bool,
    contentType: json['type'] as String,
    size: json['size'] as int,
    modified: json['modified'] == null
        ? null
        : DateTime.parse(json['modified'] as String),
    id: json['id'] as String?,
    favorite: json['favorite'] as bool,
    albumReference: (json['albumReference'] as List<dynamic>?)?.cast<String>(),
    taken: json['taken'] == null
        ? null
        : DateTime.parse(json['taken'] as String),
    captureDay: json['captureDay'] as int?,
    etag: json['etag'] as String?,
    sharing: Sharing.values.byName(json['sharing'] as String? ?? 'none'),
    liveId: json['liveId'] as String?,
  );

  /// Root of placeholder paths for timeline items whose real file path is
  /// still being looked up; such files are addressed by [id] only.
  static const pendingRoot = '\u0001pending';
  bool get pending => path.length == 2 && path.first == pendingRoot;

  String get key => path.map(Uri.encodeComponent).join('/');
  bool get isImage => contentType.startsWith('image/');
  bool get isVideo => contentType.startsWith('video/');
  bool get isMedia => isImage || isVideo;

  CloudFile withFavorite(bool value) => CloudFile(
    path: path,
    name: name,
    isDirectory: isDirectory,
    contentType: contentType,
    size: size,
    modified: modified,
    id: id,
    favorite: value,
    albumReference: albumReference,
    taken: taken,
    captureDay: captureDay,
    sharing: sharing,
    liveId: liveId,
    etag: etag,
  );

  CloudFile atPath(List<String> value) => CloudFile(
    path: value,
    name: value.last,
    isDirectory: isDirectory,
    contentType: contentType,
    size: size,
    modified: modified,
    id: id,
    favorite: favorite,
    albumReference: albumReference,
    taken: taken,
    captureDay: captureDay,
    sharing: sharing,
    liveId: liveId,
    etag: etag,
  );

  CloudFile withRevision(String? revision) => CloudFile(
    path: path,
    name: name,
    isDirectory: isDirectory,
    contentType: contentType,
    size: size,
    modified: modified,
    id: id,
    favorite: favorite,
    albumReference: albumReference,
    taken: taken,
    captureDay: captureDay,
    sharing: sharing,
    liveId: liveId,
    etag: revision,
  );

  CloudFile withCaptureDate(
    DateTime date,
    String? revision, {
    required int day,
    String? liveId,
  }) => CloudFile(
    path: path,
    name: name,
    isDirectory: isDirectory,
    contentType: contentType,
    size: size,
    modified: modified,
    id: id,
    favorite: favorite,
    albumReference: albumReference,
    taken: date,
    captureDay: day,
    sharing: sharing,
    liveId: liveId ?? this.liveId,
    etag: revision,
  );
}

class CloudAlbum {
  const CloudAlbum({
    required this.name,
    required this.reference,
    required this.count,
    this.coverId,
    this.shared = false,
  });
  final String name;

  /// Opaque backend reference, not an account-relative folder path.
  final List<String> reference;
  final int count;
  final String? coverId;
  final bool shared;

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': reference,
    'count': count,
    'coverId': coverId,
    'shared': shared,
  };

  factory CloudAlbum.fromJson(Map<String, dynamic> json) => CloudAlbum(
    name: json['name'] as String,
    reference: (json['path'] as List).cast<String>(),
    count: json['count'] as int,
    coverId: json['coverId'] as String?,
    shared: json['shared'] as bool,
  );

  /// The cover as a file known only by id; its revision and path are unknown
  /// until a listing provides them.
  CloudFile? get cover => coverId == null
      ? null
      : CloudFile(
          path: ['album-cover', ...reference],
          name: name,
          isDirectory: false,
          id: coverId,
          contentType: 'image/jpeg',
        );
}

class SmartAlbum {
  const SmartAlbum({required this.path, required this.files});
  final List<String> path;
  final List<CloudFile> files;
  String get name => path.isEmpty ? 'Photos at root' : path.last;
  String get key => path.map(Uri.encodeComponent).join('/');
  Map<String, dynamic> toJson() => {
    'path': path,
    'covers': files.map((f) => f.toJson()).toList(),
  };
  factory SmartAlbum.fromJson(Map<String, dynamic> json) => SmartAlbum(
    path: (json['path'] as List).cast<String>(),
    files: (json['covers'] as List)
        .map((f) => CloudFile.fromJson((f as Map).cast<String, dynamic>()))
        .toList(),
  );
}

class TimelineDay {
  const TimelineDay(this.id, this.count);

  /// Calendar day as a count of days since the UTC Unix epoch.
  final int id;
  final int count;
  Map<String, dynamic> toJson() => {'id': id, 'count': count};
  factory TimelineDay.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final count = json['count'];
    if (id is! int || count is! int || count < 0) {
      throw const FormatException('Invalid timeline day.');
    }
    return TimelineDay(id, count);
  }
}

class PhotoFolder {
  const PhotoFolder(this.path, this.previews);
  final List<String> path;
  final List<CloudFile> previews;
}

class TrashEntry {
  const TrashEntry({
    required this.key,
    required this.name,
    required this.originalPath,
    this.deleted,
  });
  final String key;
  final String name;
  final String originalPath;
  final DateTime? deleted;
}

/// Who a share is for.
enum ShareKind { link, user, group }

/// One way a file or folder is shared by this account: a public link, or
/// access given to a person or a group.
class FileShare {
  const FileShare({
    required this.id,
    required this.kind,
    this.isFolder = false,
    this.url,
    this.recipient,
    this.recipientName,
    this.canEdit = false,
    this.passwordProtected = false,
    this.expiration,
  });

  final String id;
  final ShareKind kind;
  final bool isFolder;

  /// The public address; set only for a link.
  final Uri? url;

  /// The account or group id the share is for; unset for a link.
  final String? recipient;
  final String? recipientName;

  /// Whether the recipient can change the content, not only view it.
  final bool canEdit;
  final bool passwordProtected;
  final String? expiration;

  FileShare withEdit(bool value) => FileShare(
    id: id,
    kind: kind,
    isFolder: isFolder,
    url: url,
    recipient: recipient,
    recipientName: recipientName,
    canEdit: value,
    passwordProtected: passwordProtected,
    expiration: expiration,
  );
}

/// A person or group the server offers to share with.
class Sharee {
  const Sharee({required this.kind, required this.id, required this.name});

  final ShareKind kind;
  final String id;
  final String name;
}

bool pathStartsWith(List<String> path, List<String> prefix) =>
    path.length >= prefix.length &&
    List.generate(prefix.length, (i) => path[i] == prefix[i]).every((v) => v);

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

void validateName(String name) {
  if (name.trim().isEmpty ||
      name == '.' ||
      name == '..' ||
      RegExp(r'[/\\\x00-\x1f]').hasMatch(name)) {
    throw const FormatException(
      'Choose a name without slashes or control characters.',
    );
  }
}
