import 'dart:convert';

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
      'Enter a full HTTPS Nextcloud address, such as https://cloud.example.com.',
    );
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.any((s) => s == '.' || s == '..')) {
    throw const FormatException('The server address contains an invalid path.');
  }
  return uri.replace(pathSegments: segments);
}

Uri serverEndpoint(
  Uri server,
  List<String> segments, [
  Map<String, String>? query,
]) => server.replace(
  pathSegments: [
    ...server.pathSegments.where((s) => s.isNotEmpty),
    ...segments,
  ],
  queryParameters: query,
);

class Account {
  const Account({
    required this.server,
    required this.loginName,
    required this.appPassword,
    required this.userId,
    required this.displayName,
    this.photoRoot,
  });

  final Uri server;
  final String loginName;
  final String appPassword;
  final String userId;
  final String displayName;
  final List<String>? photoRoot;

  Account withPhotoRoot(List<String> path) => Account(
    server: server,
    loginName: loginName,
    appPassword: appPassword,
    userId: userId,
    displayName: displayName,
    photoRoot: List.unmodifiable(path),
  );

  String get authorization =>
      'Basic ${base64Encode(utf8.encode('$loginName:$appPassword'))}';

  String encode() => jsonEncode({
    'server': server.toString(),
    'loginName': loginName,
    'appPassword': appPassword,
    'userId': userId,
    'displayName': displayName,
    'photoRoot': photoRoot,
  });

  factory Account.decode(String value) {
    final json = jsonDecode(value) as Map<String, dynamic>;
    return Account(
      server: normalizeServer(json['server'] as String),
      loginName: json['loginName'] as String,
      appPassword: json['appPassword'] as String,
      userId: json['userId'] as String,
      displayName: json['displayName'] as String,
      photoRoot: (json['photoRoot'] as List<dynamic>?)?.cast<String>(),
    );
  }
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
    this.demoColor,
    this.albumDavPath,
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
  final int? demoColor;
  final List<String>? albumDavPath;
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

  bool get readOnly => albumDavPath != null;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'dir': isDirectory,
    'type': contentType,
    'size': size,
    'modified': modified?.toUtc().toIso8601String(),
    'id': id,
    'favorite': favorite,
    'color': demoColor,
    'albumDavPath': albumDavPath,
    'taken': taken?.toIso8601String(),
    'captureDay': captureDay,
    'etag': etag,
  };

  factory CloudFile.fromJson(Map<String, dynamic> json) => CloudFile(
    path: (json['path'] as List<dynamic>).cast<String>(),
    name: json['name'] as String,
    isDirectory: json['dir'] as bool? ?? false,
    contentType: json['type'] as String? ?? '',
    size: json['size'] as int? ?? 0,
    modified: json['modified'] == null
        ? null
        : DateTime.parse(json['modified'] as String),
    id: json['id'] as String?,
    favorite: json['favorite'] as bool? ?? false,
    demoColor: json['color'] as int?,
    albumDavPath: (json['albumDavPath'] as List<dynamic>?)?.cast<String>(),
    taken: DateTime.tryParse(json['taken'] as String? ?? ''),
    captureDay: json['captureDay'] as int?,
    etag: json['etag'] as String?,
  );

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
    demoColor: demoColor,
    albumDavPath: albumDavPath,
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
    demoColor: demoColor,
    taken: taken,
    captureDay: captureDay,
    etag: etag,
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
    demoColor: demoColor,
    albumDavPath: albumDavPath,
    taken: date,
    captureDay: day,
    etag: revision,
  );
}

class NativeAlbum {
  const NativeAlbum({
    required this.name,
    required this.davPath,
    required this.count,
    this.coverId,
    this.shared = false,
  });
  final String name;
  final List<String> davPath;
  final int count;
  final String? coverId;
  final bool shared;
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

class MemoryDay {
  const MemoryDay(this.id, this.count);
  final int id;
  final int count;
  Map<String, dynamic> toJson() => {'dayid': id, 'count': count};
  factory MemoryDay.fromJson(Map<String, dynamic> json) {
    final id = json['dayid'];
    final count = json['count'];
    if (id is! int || count is! int || count < 0) {
      throw const FormatException('Unsupported Memories day index.');
    }
    return MemoryDay(id, count);
  }
}

class MemoryFolder {
  const MemoryFolder(this.path, this.previews);
  final List<String> path;
  final List<CloudFile> previews;
}

List<SmartAlbum> buildSmartAlbums(List<CloudFile> files, List<String> root) {
  final media = files
      .where((f) => f.isMedia && pathStartsWith(f.path, root))
      .toList();
  final parents = <String, SmartAlbum>{};
  for (final file in media) {
    final path = file.path.length == root.length + 1
        ? root
        : file.path.take(root.length + 1).toList();
    final key = path.map(Uri.encodeComponent).join('/');
    parents
        .putIfAbsent(key, () => SmartAlbum(path: path, files: []))
        .files
        .add(file);
  }
  return parents.values.toList()..sort((a, b) {
    final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return name == 0 ? a.key.compareTo(b.key) : name;
  });
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
