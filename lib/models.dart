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
  });

  final Uri server;
  final String loginName;
  final String appPassword;
  final String userId;
  final String displayName;

  String get authorization =>
      'Basic ${base64Encode(utf8.encode('$loginName:$appPassword'))}';

  String encode() => jsonEncode({
    'server': server.toString(),
    'loginName': loginName,
    'appPassword': appPassword,
    'userId': userId,
    'displayName': displayName,
  });

  factory Account.decode(String value) {
    final json = jsonDecode(value) as Map<String, dynamic>;
    return Account(
      server: normalizeServer(json['server'] as String),
      loginName: json['loginName'] as String,
      appPassword: json['appPassword'] as String,
      userId: json['userId'] as String,
      displayName: json['displayName'] as String,
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
  );
}

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
