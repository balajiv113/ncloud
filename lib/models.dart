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
    etag: revision,
  );

  CloudFile withCaptureDate(
    DateTime date,
    String? revision, {
    required int day,
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

class PublicShare {
  const PublicShare({
    required this.id,
    required this.url,
    this.passwordProtected = false,
    this.expiration,
  });
  final String id;
  final Uri url;
  final bool passwordProtected;
  final String? expiration;
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
