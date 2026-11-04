import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'models.dart';

class CloudException implements Exception {
  const CloudException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LoginFlow {
  const LoginFlow(this.login, this.poll, this.token);
  final Uri login;
  final Uri poll;
  final String token;
}

class NextcloudClient {
  NextcloudClient({http.Client? transport})
      : _transport = transport ?? http.Client();

  final http.Client _transport;
  static const _timeout = Duration(seconds: 45);
  static const photoLimit = 200;
  static const _properties = '''
    <d:displayname/><d:resourcetype/><d:getcontenttype/>
    <d:getcontentlength/><d:getlastmodified/><oc:fileid/><oc:favorite/>
  ''';

  void close() => _transport.close();

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Account? account,
    String? body,
    Map<String, String> headers = const {},
  }) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'User-Agent': 'ncloud/0.1.0',
        if (account != null) 'Authorization': account.authorization,
        ...headers,
      });
    if (body != null) request.body = body;
    try {
      return await http.Response.fromStream(
        await _transport.send(request).timeout(_timeout),
      ).timeout(_timeout);
    } on TimeoutException {
      throw const CloudException('The server timed out. Please try again.');
    } on http.ClientException {
      throw const CloudException(
        'Cannot reach the server. Check your connection and HTTPS certificate.',
      );
    }
  }

  void _expect(http.Response response, Set<int> statuses) {
    if (statuses.contains(response.statusCode)) return;
    throw statusError(response.statusCode);
  }

  static CloudException statusError(int status) => CloudException(
        switch (status) {
          301 || 302 || 307 || 308 =>
            'The server redirected this request. Use its final HTTPS address.',
          401 => 'Sign-in expired or credentials are incorrect. Reconnect in Settings.',
          403 => 'Your account does not have permission for this action.',
          404 => 'This item or API is not available on the server.',
          405 || 501 => 'This server does not support this operation.',
          409 => 'The parent folder no longer exists. Refresh and try again.',
          412 => 'An item with that name already exists. Choose a different name.',
          413 => 'The server rejected the file size. Check its upload limits.',
          423 => 'This file is locked. Please try again later.',
          429 => 'Too many requests. Wait a moment and try again.',
          507 => 'Your Nextcloud storage is full.',
          _ => 'The server returned HTTP $status. Please try again.',
        },
      );

  Uri _trustedUri(Uri server, String value) {
    final uri = normalizeServer(value);
    if (uri.origin != server.origin) {
      throw const CloudException(
        'The login response points to another server. Use the final server URL.',
      );
    }
    return uri;
  }

  Future<LoginFlow> startLogin(Uri server) async {
    final response = await _request(
      'POST',
      serverEndpoint(server, ['index.php', 'login', 'v2']),
    );
    _expect(response, {200});
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final poll = data['poll'] as Map<String, dynamic>;
    return LoginFlow(
      _trustedUri(server, data['login'] as String),
      _trustedUri(server, poll['endpoint'] as String),
      poll['token'] as String,
    );
  }

  Future<Account?> pollLogin(Uri server, LoginFlow flow) async {
    final response = await _request(
      'POST',
      flow.poll,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: Uri(queryParameters: {'token': flow.token}).query,
    );
    if (response.statusCode == 404) return null;
    _expect(response, {200});
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return authenticate(
      _trustedUri(server, data['server'] as String),
      data['loginName'] as String,
      data['appPassword'] as String,
    );
  }

  Future<Account> authenticate(
    Uri server,
    String loginName,
    String appPassword,
  ) async {
    if (loginName.trim().isEmpty || appPassword.isEmpty || loginName.contains(':')) {
      throw const CloudException('Enter your username and an app password.');
    }
    final pending = Account(
      server: server,
      loginName: loginName.trim(),
      appPassword: appPassword,
      userId: '',
      displayName: '',
    );
    final response = await _request(
      'GET',
      serverEndpoint(server, ['ocs', 'v2.php', 'cloud', 'user'], {'format': 'json'}),
      account: pending,
      headers: {'OCS-APIRequest': 'true', 'Accept': 'application/json'},
    );
    _expect(response, {200});
    final ocs = (jsonDecode(response.body) as Map<String, dynamic>)['ocs']
        as Map<String, dynamic>;
    final meta = ocs['meta'] as Map<String, dynamic>;
    if (meta['status'] != 'ok') {
      throw const CloudException('Nextcloud could not verify this account.');
    }
    final data = ocs['data'] as Map<String, dynamic>;
    final id = data['id'] as String;
    if (id.isEmpty) throw const CloudException('The server returned an empty user ID.');
    return Account(
      server: server,
      loginName: pending.loginName,
      appPassword: appPassword,
      userId: id,
      displayName: (data['display-name'] ?? data['displayname'] ?? id) as String,
    );
  }

  Uri davUri(Account account, List<String> path) => serverEndpoint(
        account.server,
        ['remote.php', 'dav', 'files', account.userId, ...path],
      );

  Future<List<CloudFile>> listFiles(Account account, List<String> path) async {
    final response = await _request(
      'PROPFIND',
      davUri(account, path),
      account: account,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body: '''
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:prop>$_properties</d:prop>
        </d:propfind>
      ''',
    );
    _expect(response, {207});
    return parseFiles(response.body, account)
        .where((file) => file.path.length > path.length)
        .toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  Future<List<CloudFile>> search(Account account, {bool favorites = false}) async {
    final scope = XmlText(davUri(account, []).path).toXmlString();
    final where = favorites
        ? '<d:eq><d:prop><oc:favorite/></d:prop><d:literal>1</d:literal></d:eq>'
        : '''<d:or>
            <d:like><d:prop><d:getcontenttype/></d:prop><d:literal>image/%</d:literal></d:like>
            <d:like><d:prop><d:getcontenttype/></d:prop><d:literal>video/%</d:literal></d:like>
          </d:or>''';
    final response = await _request(
      'SEARCH',
      serverEndpoint(account.server, ['remote.php', 'dav']),
      account: account,
      headers: {'Content-Type': 'application/xml; charset=utf-8'},
      body: '''
        <d:searchrequest xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:basicsearch>
            <d:select><d:prop>$_properties</d:prop></d:select>
            <d:from><d:scope><d:href>$scope</d:href><d:depth>infinity</d:depth></d:scope></d:from>
            <d:where>$where</d:where>
            <d:orderby><d:order><d:prop><d:getlastmodified/></d:prop><d:descending/></d:order></d:orderby>
            <d:limit><d:nresults>$photoLimit</d:nresults></d:limit>
          </d:basicsearch>
        </d:searchrequest>
      ''',
    );
    _expect(response, {207});
    final files = parseFiles(response.body, account);
    return files.where((f) => favorites ? f.favorite : f.isMedia).toList();
  }

  static List<CloudFile> parseFiles(String source, Account account) {
    final root = serverEndpoint(
      account.server,
      ['remote.php', 'dav', 'files', account.userId],
    ).pathSegments;
    final document = XmlDocument.parse(source);
    final files = <CloudFile>[];
    for (final response in document.findAllElements('response', namespace: 'DAV:')) {
      final href = response.getElement('href', namespace: 'DAV:')?.innerText;
      if (href == null) continue;
      final uri = Uri.parse(href);
      if (uri.hasAuthority && uri.origin != account.server.origin) continue;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < root.length) continue;
      if (List.generate(root.length, (i) => segments[i] == root[i])
          .contains(false)) {
        continue;
      }
      final path = segments.sublist(root.length);
      if (path.isEmpty || path.any((s) => s == '.' || s == '..' || s.contains('/'))) {
        continue;
      }
      final props = response
          .findElements('propstat', namespace: 'DAV:')
          .where((p) => RegExp(r'\s200(?:\s|$)').hasMatch(
                p.getElement('status', namespace: 'DAV:')?.innerText ?? '',
              ))
          .map((p) => p.getElement('prop', namespace: 'DAV:'))
          .nonNulls
          .toList();
      String value(String name, [String ns = 'DAV:']) {
        for (final prop in props) {
          final value = prop.getElement(name, namespace: ns);
          if (value != null) return value.innerText;
        }
        return '';
      }

      if (props.isEmpty) continue;
      final modified = value('getlastmodified');
      DateTime? date;
      if (modified.isNotEmpty) {
        // HTTP dates are not ISO-8601; parse their fixed RFC 1123 components.
        final parts = modified.split(' ');
        const months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
        ];
        if (parts.length == 6) {
          final month = months.indexOf(parts[2]) + 1;
          final day = int.tryParse(parts[1]);
          final year = int.tryParse(parts[3]);
          final time = parts[4].split(':').map(int.tryParse).toList();
          if (month > 0 && day != null && year != null &&
              time.length == 3 && !time.contains(null)) {
            date = DateTime.utc(year, month, day, time[0]!, time[1]!, time[2]!);
          }
        }
      }
      files.add(CloudFile(
        path: path,
        name: path.last,
        isDirectory: props.any((p) => p
            .findAllElements('collection', namespace: 'DAV:')
            .isNotEmpty),
        contentType: value('getcontenttype'),
        size: int.tryParse(value('getcontentlength')) ?? 0,
        modified: date,
        id: value('fileid', 'http://owncloud.org/ns').isEmpty
            ? null
            : value('fileid', 'http://owncloud.org/ns'),
        favorite: value('favorite', 'http://owncloud.org/ns') == '1',
      ));
    }
    return files;
  }

  Future<void> createFolder(Account account, List<String> path) async {
    validateName(path.last);
    final response = await _request('MKCOL', davUri(account, path), account: account);
    _expect(response, {201});
  }

  Future<void> setFavorite(Account account, CloudFile file, bool value) async {
    final response = await _request(
      'PROPPATCH',
      davUri(account, file.path),
      account: account,
      headers: {'Content-Type': 'application/xml; charset=utf-8'},
      body: '''
        <d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:set><d:prop><oc:favorite>${value ? 1 : 0}</oc:favorite></d:prop></d:set>
        </d:propertyupdate>
      ''',
    );
    _expect(response, {207});
    final statuses = XmlDocument.parse(response.body)
        .findAllElements('status', namespace: 'DAV:')
        .map((element) => element.innerText)
        .toList();
    if (statuses.isEmpty || statuses.any((s) => !RegExp(r'\s200(?:\s|$)').hasMatch(s))) {
      throw const CloudException('The server could not update this favorite.');
    }
  }

  Future<void> upload(
    Account account,
    List<String> path,
    Stream<List<int>> bytes,
    int size,
  ) async {
    validateName(path.last);
    final request = _UploadRequest(davUri(account, path), bytes)
      ..contentLength = size
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': account.authorization,
        'Content-Type': 'application/octet-stream',
        'If-None-Match': '*',
        'User-Agent': 'ncloud/0.1.0',
      });
    try {
      final response = await http.Response.fromStream(
        await _transport.send(request).timeout(const Duration(minutes: 10)),
      ).timeout(_timeout);
      _expect(response, {201, 204});
    } on TimeoutException {
      throw const CloudException(
        'Upload timed out. Refresh the folder to check whether the file arrived.',
      );
    } on http.ClientException {
      throw const CloudException(
        'Upload interrupted. Refresh the folder before trying again.',
      );
    }
  }

  Future<http.StreamedResponse> download(Account account, CloudFile file) async {
    final request = http.Request('GET', davUri(account, file.path))
      ..followRedirects = false
      ..headers['Authorization'] = account.authorization;
    try {
      final response = await _transport.send(request).timeout(_timeout);
      if (response.statusCode != 200) {
        await response.stream.drain<void>().timeout(_timeout);
        throw statusError(response.statusCode);
      }
      return response;
    } on TimeoutException {
      throw const CloudException('Download timed out. Please try again.');
    } on http.ClientException {
      throw const CloudException('Download interrupted. Check your connection.');
    }
  }

  Future<Uint8List> preview(Account account, CloudFile file) async {
    if (file.id == null) throw const CloudException('No preview is available.');
    final request = http.Request(
      'GET',
      serverEndpoint(account.server, ['index.php', 'core', 'preview'], {
        'fileId': file.id!,
        'x': '720',
        'y': '720',
        'a': 'true',
      }),
    )
      ..followRedirects = false
      ..headers['Authorization'] = account.authorization;
    try {
      final response = await _transport.send(request).timeout(_timeout);
      if (response.statusCode != 200) {
        await response.stream.drain<void>().timeout(_timeout);
        throw statusError(response.statusCode);
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(_timeout)) {
        bytes.add(chunk);
        if (bytes.length > 8 * 1024 * 1024) {
          throw const CloudException('The preview is too large to display.');
        }
      }
      return bytes.takeBytes();
    } on TimeoutException {
      throw const CloudException('Preview timed out. Tap to retry.');
    } on http.ClientException {
      throw const CloudException('Preview unavailable. Tap to retry.');
    }
  }
}

class _UploadRequest extends http.BaseRequest {
  _UploadRequest(Uri uri, this.bytes) : super('PUT', uri);
  final Stream<List<int>> bytes;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(bytes);
  }
}
