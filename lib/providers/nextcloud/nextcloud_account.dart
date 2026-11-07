import 'dart:convert';

import '../../models.dart';

class NextcloudAccount extends Account {
  const NextcloudAccount({
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
  @override
  final String displayName;
  @override
  final List<String>? photoRoot;

  @override
  String get storageKey => '$server|$userId';
  @override
  String get serverLabel => server.toString();

  @override
  bool sameOwner(Account other) =>
      other is NextcloudAccount &&
      server == other.server &&
      userId == other.userId;

  @override
  NextcloudAccount withPhotoRoot(List<String> path) => NextcloudAccount(
    server: server,
    loginName: loginName,
    appPassword: appPassword,
    userId: userId,
    displayName: displayName,
    photoRoot: List.unmodifiable(path),
  );

  @override
  String encode() => jsonEncode({
    'provider': 'nextcloud',
    'server': server.toString(),
    'loginName': loginName,
    'appPassword': appPassword,
    'userId': userId,
    'displayName': displayName,
    'photoRoot': photoRoot,
  });

  factory NextcloudAccount.decode(Map<String, dynamic> json) =>
      NextcloudAccount(
        server: normalizeServer(json['server'] as String),
        loginName: json['loginName'] as String,
        appPassword: json['appPassword'] as String,
        userId: json['userId'] as String,
        displayName: json['displayName'] as String,
        photoRoot: (json['photoRoot'] as List<dynamic>?)?.cast<String>(),
      );
}

extension NextcloudAccountFields on Account {
  NextcloudAccount get nextcloud {
    final account = this;
    if (account is! NextcloudAccount) {
      throw StateError('Account does not belong to the Nextcloud provider.');
    }
    return account;
  }

  Uri get server => nextcloud.server;
  String get loginName => nextcloud.loginName;
  String get appPassword => nextcloud.appPassword;
  String get userId => nextcloud.userId;
}
