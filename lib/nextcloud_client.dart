import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'models.dart';
import 'discovery_models.dart';
import 'cloud_backend.dart';
import 'nextcloud_change_feed.dart';
import 'nextcloud_discovery.dart';

class _NextcloudLoginFlow implements LoginFlow {
  _NextcloudLoginFlow(
    this.login,
    this.poll,
    this.token,
    this.server,
    this.owner,
  );

  @override
  final Uri login;
  final Uri poll;
  final String token;
  final Uri server;
  final NextcloudClient owner;
  Account? exchanged;
  Account? verified;
  Future<Account?>? polling;
}

extension NextcloudAuthorization on Account {
  String get authorization =>
      'Basic ${base64Encode(utf8.encode('$loginName:$appPassword'))}';
}

class NextcloudClient implements CloudBackend {
  NextcloudClient({
    http.Client? transport,
    Future<WebSocket> Function(Uri)? connectPush,
  }) : _transport = transport ?? http.Client(),
       _connectPush = connectPush;

  final http.Client _transport;
  final Future<WebSocket> Function(Uri)? _connectPush;
  final _pushEndpoints = <Account, Future<Uri?>>{};
  final _previewQueue = Queue<Completer<void>>();
  int _activePreviews = 0;
  static const _timeout = Duration(seconds: 45);
  static const photoLimit = 200;
  @override
  int get pageSize => photoLimit;
  // Nextcloud's DAV FileSearchBackend rejects more than 100 comparisons.
  static const fileIdLimit = 100;
  static const _properties = '''
    <d:displayname/><d:resourcetype/><d:getcontenttype/>
    <d:getcontentlength/><d:getlastmodified/><d:getetag/><oc:fileid/><oc:favorite/>
  ''';

  @override
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
        'User-Agent': 'ncloud/0.5.5',
        if (account != null) 'Authorization': account.authorization,
        ...headers,
      });
    if (body != null) request.body = body;
    try {
      return await http.Response.fromStream(
        await _transport.send(request).timeout(_timeout),
      ).timeout(_timeout);
    } on TimeoutException {
      throw const CloudException(
        'The server timed out. Please try again.',
        retryable: true,
      );
    } on http.ClientException {
      throw const CloudException(
        'Cannot reach the server. Check your connection and HTTPS certificate.',
        retryable: true,
      );
    } on SocketException {
      throw const CloudException(
        'Cannot reach the server. Check your connection.',
        retryable: true,
      );
    }
  }

  void _expect(http.Response response, Set<int> statuses) {
    if (statuses.contains(response.statusCode)) return;
    throw statusError(response.statusCode);
  }

  static CloudException statusError(int status) => CloudException(
    switch (status) {
      301 ||
      302 ||
      307 ||
      308 => 'The server redirected this request. Use its final HTTPS address.',
      401 =>
        'Sign-in expired or credentials are incorrect. Reconnect in Settings.',
      403 => 'Your account does not have permission for this action.',
      404 => 'This item or API is not available on the server.',
      405 || 501 => 'This server does not support this operation.',
      409 => 'The parent folder no longer exists. Refresh and try again.',
      412 => 'An item with that name already exists. Choose a different name.',
      413 => 'The server rejected the file size. Check its upload limits.',
      423 => 'This file is locked. Please try again later.',
      429 => 'Too many requests. Wait a moment and try again.',
      507 => 'Your server storage is full.',
      _ => 'The server returned HTTP $status. Please try again.',
    },
    statusCode: status,
    retryable:
        status == 408 || status == 429 || (status >= 500 && status < 600),
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

  @override
  Future<LoginFlow> startLogin(Uri server) async {
    final response = await _request(
      'POST',
      serverEndpoint(server, ['index.php', 'login', 'v2']),
    );
    _expect(response, {200});
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final poll = data['poll'] as Map<String, dynamic>;
    return _NextcloudLoginFlow(
      _trustedUri(server, data['login'] as String),
      _trustedUri(server, poll['endpoint'] as String),
      poll['token'] as String,
      server,
      this,
    );
  }

  @override
  Future<Account?> pollLogin(Uri server, LoginFlow flow) async {
    if (flow is! _NextcloudLoginFlow ||
        !identical(flow.owner, this) ||
        flow.server != server) {
      throw const CloudException(
        'The login flow is not valid for this server.',
      );
    }
    if (flow.verified case final account?) return account;
    return flow.polling ??= _pollLogin(
      server,
      flow,
    ).whenComplete(() => flow.polling = null);
  }

  Future<Account?> _pollLogin(Uri server, _NextcloudLoginFlow flow) async {
    if (flow.exchanged == null) {
      final response = await _request(
        'POST',
        flow.poll,
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: Uri(queryParameters: {'token': flow.token}).query,
      );
      if (response.statusCode == 404) return null;
      _expect(response, {200});
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      flow.exchanged = Account(
        server: _trustedUri(server, data['server'] as String),
        loginName: data['loginName'] as String,
        appPassword: data['appPassword'] as String,
        userId: '',
        displayName: '',
      );
    }
    final credentials = flow.exchanged!;
    try {
      return flow.verified = await authenticate(
        credentials.server,
        credentials.loginName,
        credentials.appPassword,
      );
    } on CloudException catch (error) {
      if (error.statusCode == 401) {
        throw CloudException(
          error.message,
          statusCode: error.statusCode,
          retryable: true,
        );
      }
      rethrow;
    }
  }

  @override
  Future<Account> authenticate(
    Uri server,
    String loginName,
    String appPassword,
  ) async {
    if (loginName.trim().isEmpty ||
        appPassword.isEmpty ||
        loginName.contains(':')) {
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
      serverEndpoint(
        server,
        ['ocs', 'v2.php', 'cloud', 'user'],
        {'format': 'json'},
      ),
      account: pending,
      headers: {'OCS-APIRequest': 'true', 'Accept': 'application/json'},
    );
    _expect(response, {200});
    final ocs =
        (jsonDecode(response.body) as Map<String, dynamic>)['ocs']
            as Map<String, dynamic>;
    final meta = ocs['meta'] as Map<String, dynamic>;
    if (meta['status'] != 'ok') {
      final code = int.tryParse('${meta['statuscode']}');
      if (code == 997 || code == 401) throw statusError(401);
      if (code == 403) throw statusError(403);
      throw const CloudException('Nextcloud could not verify this account.');
    }
    final data = ocs['data'] as Map<String, dynamic>;
    final id = data['id'] as String;
    if (id.isEmpty) {
      throw const CloudException('The server returned an empty user ID.');
    }
    return Account(
      server: server,
      loginName: pending.loginName,
      appPassword: appPassword,
      userId: id,
      displayName:
          (data['display-name'] ?? data['displayname'] ?? id) as String,
    );
  }

  Uri davUri(Account account, List<String> path) => serverEndpoint(
    account.server,
    ['remote.php', 'dav', 'files', account.userId, ...path],
  );

  Uri fileUri(Account account, CloudFile file) => file.albumReference == null
      ? davUri(account, file.path)
      : serverEndpoint(account.server, [
          'remote.php',
          'dav',
          ...file.albumReference!,
        ]);

  @override
  MediaSource streamSource(Account account, CloudFile file) => (
    uri: fileUri(account, file),
    headers: {'Authorization': account.authorization},
  );

  @override
  Stream<Set<String>?> changes(Account account) =>
      nextcloudChanges(account, () async {
        try {
          return await _pushEndpoints.putIfAbsent(
            account,
            () => pushEndpoint(account),
          );
        } catch (_) {
          _pushEndpoints.remove(account);
          rethrow;
        }
      }, connect: _connectPush);

  @override
  Future<List<CloudAlbum>> albums(
    Account account, {
    bool shared = false,
  }) async {
    final path = ['photos', account.userId, shared ? 'sharedalbums' : 'albums'];
    final response = await _request(
      'PROPFIND',
      serverEndpoint(account.server, ['remote.php', 'dav', ...path]),
      account: account,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body: '''<d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
        <d:prop><d:displayname/><nc:original-name/><nc:nbItems/><nc:last-photo/></d:prop>
      </d:propfind>''',
    );
    if (response.statusCode == 404 || response.statusCode == 405) return [];
    _expect(response, {207});
    final root = serverEndpoint(account.server, [
      'remote.php',
      'dav',
      ...path,
    ]).pathSegments;
    final result = <CloudAlbum>[];
    for (final entry in XmlDocument.parse(
      response.body,
    ).findAllElements('response', namespace: 'DAV:')) {
      final href = entry.getElement('href', namespace: 'DAV:')?.innerText;
      if (href == null) continue;
      final uri = Uri.parse(href);
      if (uri.hasAuthority && uri.origin != account.server.origin) continue;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length != root.length + 1 ||
          !pathStartsWith(segments, root) ||
          segments.any((s) => s == '.' || s == '..' || s.contains('/'))) {
        continue;
      }
      final props = _successfulProps(entry);
      if (props.isEmpty) continue;
      String value(String name, String ns) =>
          props
              .map((p) => p.getElement(name, namespace: ns)?.innerText)
              .nonNulls
              .firstOrNull ??
          '';
      final name = value('original-name', 'http://nextcloud.org/ns');
      final display = value('displayname', 'DAV:');
      final cover = value('last-photo', 'http://nextcloud.org/ns');
      result.add(
        CloudAlbum(
          name: name.isNotEmpty
              ? name
              : display.isNotEmpty
              ? display
              : segments.last,
          reference: [...path, segments.last],
          count: int.tryParse(value('nbItems', 'http://nextcloud.org/ns')) ?? 0,
          coverId: cover.isEmpty || cover == '0' ? null : cover,
          shared: shared,
        ),
      );
    }
    return result;
  }

  static List<XmlElement> _successfulProps(XmlElement entry) => entry
      .findElements('propstat', namespace: 'DAV:')
      .where(
        (p) => RegExp(
          r'\s200(?:\s|$)',
        ).hasMatch(p.getElement('status', namespace: 'DAV:')?.innerText ?? ''),
      )
      .map((p) => p.getElement('prop', namespace: 'DAV:'))
      .nonNulls
      .toList();

  @override
  Future<List<CloudFile>> albumFiles(
    Account account,
    CloudAlbum album,
    List<CloudFile> library,
  ) async {
    final response = await _request(
      'PROPFIND',
      serverEndpoint(account.server, ['remote.php', 'dav', ...album.reference]),
      account: account,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body:
          '''<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"
        xmlns:nc="http://nextcloud.org/ns"><d:prop>$_properties
        <nc:file-name/><nc:photos-collection-file-original-filename/></d:prop></d:propfind>''',
    );
    _expect(response, {207});
    final root = serverEndpoint(account.server, [
      'remote.php',
      'dav',
      ...album.reference,
    ]).pathSegments;
    final known = {
      for (final file in library)
        if (file.id != null) file.id!: file,
    };
    final result = <CloudFile>[];
    for (final entry in XmlDocument.parse(
      response.body,
    ).findAllElements('response', namespace: 'DAV:')) {
      final href = entry.getElement('href', namespace: 'DAV:')?.innerText;
      if (href == null) continue;
      final uri = Uri.parse(href);
      if (uri.hasAuthority && uri.origin != account.server.origin) continue;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length != root.length + 1 ||
          !pathStartsWith(segments, root) ||
          segments.any((s) => s == '.' || s == '..' || s.contains('/'))) {
        continue;
      }
      final props = _successfulProps(entry);
      if (props.isEmpty) continue;
      String value(String name, [String ns = 'DAV:']) =>
          props
              .map((p) => p.getElement(name, namespace: ns)?.innerText)
              .nonNulls
              .firstOrNull ??
          '';
      final id = value('fileid', 'http://owncloud.org/ns');
      final existing = known[id];
      final type = value('getcontenttype').isEmpty
          ? existing?.contentType ?? ''
          : value('getcontenttype');
      if (!type.startsWith('image/') && !type.startsWith('video/')) continue;
      final filename = value('file-name', 'http://nextcloud.org/ns');
      final name = filename.isEmpty
          ? existing?.name ?? value('displayname')
          : filename;
      result.add(
        CloudFile(
          path: existing == null
              ? ['Albums', ...album.reference, segments.last]
              : name != existing.name && !existing.readOnly
              ? [CloudFile.pendingRoot, id]
              : existing.path,
          name: name.isEmpty ? segments.last : name,
          isDirectory: false,
          contentType: type,
          id: id.isEmpty ? null : id,
          size: int.tryParse(value('getcontentlength')) ?? existing?.size ?? 0,
          modified:
              _parseModified(value('getlastmodified')) ?? existing?.modified,
          etag: value('getetag').isEmpty ? existing?.etag : value('getetag'),
          albumReference: existing == null
              ? [...album.reference, segments.last]
              : existing.albumReference,
          favorite: value('favorite', 'http://owncloud.org/ns').isEmpty
              ? existing?.favorite ?? false
              : value('favorite', 'http://owncloud.org/ns') == '1',
          taken: existing?.taken,
          captureDay: existing?.captureDay,
        ),
      );
    }
    return result;
  }

  @override
  Future<List<CloudFile>> listFiles(Account account, List<String> path) async =>
      (await listFolder(account, path)).children;

  @override
  Future<String?> folderEtag(
    Account account,
    List<String> path, {
    bool optional = false,
  }) async {
    final response = await _request(
      'PROPFIND',
      davUri(account, path),
      account: account,
      headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
      body:
          '<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/>'
          '</d:prop></d:propfind>',
    );
    if (optional && {404, 405, 501}.contains(response.statusCode)) return null;
    _expect(response, {207});
    final root = XmlDocument.parse(response.body);
    for (final propstat in root.findAllElements(
      'propstat',
      namespace: 'DAV:',
    )) {
      if (!RegExp(r'\s200(?:\s|$)').hasMatch(
        propstat.getElement('status', namespace: 'DAV:')?.innerText ?? '',
      )) {
        continue;
      }
      final etag = propstat
          .getElement('prop', namespace: 'DAV:')
          ?.getElement('getetag', namespace: 'DAV:')
          ?.innerText
          .trim();
      if (etag != null && etag.isNotEmpty) return etag;
    }
    return null;
  }

  /// Never send account credentials to another origin advertised by a server.
  Future<Uri?> pushEndpoint(Account account) async {
    final response = await _request(
      'GET',
      serverEndpoint(
        account.server,
        ['ocs', 'v2.php', 'cloud', 'capabilities'],
        {'format': 'json'},
      ),
      account: account,
      headers: {'OCS-APIRequest': 'true', 'Accept': 'application/json'},
    );
    if ({404, 405, 501}.contains(response.statusCode)) return null;
    _expect(response, {200});
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final ocs = body['ocs'] as Map<String, dynamic>;
    final meta = ocs['meta'] as Map<String, dynamic>?;
    if (meta != null &&
        meta['statuscode'] != 100 &&
        meta['statuscode'] != 200) {
      throw const CloudException('Could not discover Nextcloud push support.');
    }
    final data = ocs['data'] as Map<String, dynamic>;
    final capabilities = data['capabilities'] as Map<String, dynamic>;
    final push = capabilities['notify_push'] as Map<String, dynamic>?;
    final endpoints = push?['endpoints'] as Map<String, dynamic>?;
    final value = endpoints?['websocket'];
    if (value == null) return null;
    if (value is! String) {
      throw const CloudException('The push endpoint is invalid.');
    }
    final uri = Uri.parse(value);
    final https = uri.replace(scheme: 'https');
    if (uri.scheme != 'wss' ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        https.origin != account.server.origin) {
      throw const CloudException(
        'Push requires a secure endpoint on the same server. Using change checks instead.',
      );
    }
    return uri;
  }

  /// Lists direct children plus the folder's own entry, whose recursive etag
  /// lets cached listings be reused while nothing below it changed.
  @override
  Future<({CloudFile? self, List<CloudFile> children})> listFolder(
    Account account,
    List<String> path,
  ) async {
    final response = await _request(
      'PROPFIND',
      davUri(account, path),
      account: account,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body:
          '''
        <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:prop>$_properties</d:prop>
        </d:propfind>
      ''',
    );
    _expect(response, {207});
    final entries = parseFiles(response.body, account);
    return (
      self: entries.where((f) => f.path.length == path.length).firstOrNull,
      children: entries.where((file) => file.path.length > path.length).toList()
        ..sort((a, b) {
          if (a.isDirectory != b.isDirectory) {
            return a.isDirectory ? -1 : 1;
          }
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }),
    );
  }

  @override
  Future<List<CloudFile>> search(
    Account account, {
    bool favorites = false,
    List<String> path = const [],
    int offset = 0,
    int limit = photoLimit,
    List<String>? fileIds,
    bool recursive = true,
  }) async => (await searchPage(
    account,
    favorites: favorites,
    path: path,
    offset: offset,
    limit: limit,
    fileIds: fileIds,
    recursive: recursive,
  )).files;

  /// Like [search], but also reports how many results the server returned
  /// before client-side filtering, which is what paging offsets must use.
  @override
  Future<({List<CloudFile> files, int scanned})> searchPage(
    Account account, {
    bool favorites = false,
    List<String> path = const [],
    int offset = 0,
    int limit = photoLimit,
    List<String>? fileIds,
    bool recursive = true,
  }) async {
    // Relative SEARCH scopes are literal DAV paths, not URI-encoded URLs.
    final scope = XmlText(
      ['', 'files', account.userId, ...path].join('/'),
    ).toXmlString();
    final where = fileIds != null
        ? '<d:or>${fileIds.map((id) => '<d:eq><d:prop><oc:fileid/></d:prop><d:literal>${XmlText(id).toXmlString()}</d:literal></d:eq>').join()}</d:or>'
        : favorites
        ? '<d:eq><d:prop><oc:favorite/></d:prop><d:literal>1</d:literal></d:eq>'
        : '''<d:or>
            <d:like><d:prop><d:getcontenttype/></d:prop><d:literal>image/%</d:literal></d:like>
            <d:like><d:prop><d:getcontenttype/></d:prop><d:literal>video/%</d:literal></d:like>
          </d:or>''';
    final response = await _request(
      'SEARCH',
      serverEndpoint(account.server, ['remote.php', 'dav', '']),
      account: account,
      headers: {'Content-Type': 'application/xml; charset=utf-8'},
      body:
          '''
        <d:searchrequest xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:sd="https://github.com/icewind1991/SearchDAV/ns">
          <d:basicsearch>
            <d:select><d:prop>$_properties</d:prop></d:select>
            <d:from><d:scope><d:href>$scope</d:href><d:depth>${recursive ? 'infinity' : '1'}</d:depth></d:scope></d:from>
            <d:where>$where</d:where>
            <d:orderby><d:order><d:prop><d:getlastmodified/></d:prop><d:descending/></d:order></d:orderby>
            <d:limit><d:nresults>$limit</d:nresults><sd:firstresult>$offset</sd:firstresult></d:limit>
          </d:basicsearch>
        </d:searchrequest>
      ''',
    );
    _expect(response, {207});
    final files = parseFiles(response.body, account);
    return (
      files: files
          .where((f) => favorites ? f.favorite : f.isMedia)
          // Nextcloud ignores SEARCH depth 1 and returns nested files too.
          .where((f) => recursive || f.path.length == path.length + 1)
          .toList(),
      scanned: files.length,
    );
  }

  Future<List<dynamic>?> _memories(
    Account account,
    List<String> endpoint,
    Map<String, String> query, {
    bool optional = false,
    String? disabledMessage,
  }) async {
    final response = await _request(
      'GET',
      serverEndpoint(account.server, [
        'index.php',
        'apps',
        'memories',
        'api',
        ...endpoint,
      ], query),
      account: account,
      headers: {'Accept': 'application/json', 'OCS-APIRequest': 'true'},
    );
    if (optional &&
        (response.statusCode == 404 || response.statusCode == 405)) {
      return null;
    }
    if (response.statusCode == 412 && disabledMessage != null) {
      throw CloudException(disabledMessage);
    }
    _expect(response, {200});
    final json = jsonDecode(response.body);
    if (json is! List) {
      throw const FormatException('Unsupported Memories API response.');
    }
    return json;
  }

  @override
  Future<List<RecognizedPerson>?> people(
    Account account, {
    List<String> path = const [],
    bool optional = false,
  }) async {
    final rows = await _memories(
      account,
      ['clusters', 'recognize'],
      {'folder': '/${path.join('/')}', 'recursive': '1'},
      optional: optional,
      disabledMessage:
          'Recognize face recognition is not enabled or needs an update on this server.',
    );
    if (rows == null) return null;
    final people = [
      for (final row in rows)
        if (row is Map<String, dynamic>)
          parseNextcloudPerson(row)
        else
          throw const FormatException('Unsupported Recognize person record.'),
    ];
    people.sort(RecognizedPerson.compareByCount);
    return people;
  }

  @override
  Future<Uint8List> personPreview(
    Account account,
    RecognizedPerson person,
  ) async {
    final response = await _request(
      'GET',
      serverEndpoint(
        account.server,
        [
          'index.php',
          'apps',
          'memories',
          'api',
          'clusters',
          'recognize',
          'preview',
        ],
        {
          'name': '${person.id}',
          if (person.cover != null) 'cover': '${person.cover}',
          if (person.coverEtag != null) 'cover_etag': person.coverEtag!,
        },
      ),
      account: account,
      headers: {'Accept': 'image/*'},
    );
    _expect(response, {200});
    if (response.bodyBytes.isEmpty) {
      throw const CloudException(
        'No face preview is available for this person.',
      );
    }
    return response.bodyBytes;
  }

  @override
  Future<PhotoLocation?> mapPosition(Account account) async {
    final response = await _request(
      'GET',
      serverEndpoint(
        account.server,
        ['index.php', 'apps', 'memories', 'api', 'map', 'init'],
        {'folder': '/', 'recursive': '1'},
      ),
      account: account,
      headers: {'Accept': 'application/json', 'OCS-APIRequest': 'true'},
    );
    _expect(response, {200});
    final data = jsonDecode(response.body);
    if (data is! Map<String, dynamic> || !data.containsKey('pos')) {
      throw const FormatException('Unsupported map position response.');
    }
    final position = data['pos'];
    if (position == null) return null;
    if (position is! Map<String, dynamic>) {
      throw const FormatException('Unsupported map position response.');
    }
    return parseNextcloudLocation(position);
  }

  @override
  Future<List<PhotoMapCluster>> mapClusters(
    Account account, {
    required PhotoMapBounds bounds,
    required int zoom,
    List<String> path = const [],
  }) async {
    if (zoom < 0 || zoom > 22) {
      throw const FormatException('Map zoom must be between 0 and 22.');
    }
    final rows = await _memories(
      account,
      ['map', 'clusters'],
      {
        'bounds': bounds.query,
        'zoom': '$zoom',
        'folder': '/${path.join('/')}',
        'recursive': '1',
      },
    );
    return [
      for (final row in rows!)
        if (row is Map<String, dynamic>)
          parseNextcloudMapCluster(row)
        else
          throw const FormatException('Unsupported photo map cluster.'),
    ];
  }

  @override
  Future<List<TimelineDay>> mapDays(
    Account account,
    List<PhotoMapBounds> bounds,
  ) async {
    if (bounds.isEmpty) throw const FormatException('Choose a map area.');
    final counts = <int, int>{};
    for (final area in bounds) {
      final days = await timelineDays(account, mapBounds: area);
      for (final day in days!) {
        counts.update(
          day.id,
          (count) => count + day.count,
          ifAbsent: () => day.count,
        );
      }
    }
    return [
      for (final id in counts.keys.toList()..sort((a, b) => b.compareTo(a)))
        TimelineDay(id, counts[id]!),
    ];
  }

  @override
  Future<List<CloudFile>> mapDayFiles(
    Account account,
    List<int> dayIds,
    List<PhotoMapBounds> bounds,
  ) async {
    if (bounds.isEmpty) throw const FormatException('Choose a map area.');
    final files = <String, CloudFile>{};
    for (final area in bounds) {
      for (final file in await timelineDayFiles(
        account,
        dayIds,
        mapBounds: area,
        resolvePaths: false,
      )) {
        files[file.key] = file;
      }
    }
    return files.values.toList();
  }

  /// Thumbnails for many files in one streamed Memories request. Files whose
  /// preview is not generated yet are omitted; callers fetch those singly.
  @override
  Future<Map<String, Uint8List>> multipreview(
    Account account,
    List<String> fileIds, {
    int size = 384,
  }) async {
    if (fileIds.isEmpty) return {};
    final response = await _request(
      'POST',
      serverEndpoint(account.server, [
        'index.php',
        'apps',
        'memories',
        'api',
        'image',
        'multipreview',
      ]),
      account: account,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/octet-stream',
      },
      body: jsonEncode({
        'files': [
          for (final id in fileIds)
            {
              'reqid': id,
              'fileid': int.parse(id),
              'x': size,
              'y': size,
              'a': '1',
            },
        ],
      }),
    );
    _expect(response, {200});
    return parseMultipreview(response.bodyBytes);
  }

  /// Parses `[1-byte header length][JSON header][image bytes]` records.
  static Map<String, Uint8List> parseMultipreview(Uint8List body) {
    final previews = <String, Uint8List>{};
    var offset = 0;
    while (offset < body.length) {
      final length = body[offset++];
      if (offset + length > body.length) {
        throw const FormatException('Truncated Memories preview header.');
      }
      final header =
          jsonDecode(utf8.decode(body.sublist(offset, offset + length))) as Map;
      offset += length;
      final size = header['len'];
      if (size is! int || size <= 0 || offset + size > body.length) {
        throw const FormatException('Truncated Memories preview.');
      }
      previews['${header['reqid']}'] = Uint8List.sublistView(
        body,
        offset,
        offset + size,
      );
      offset += size;
    }
    return previews;
  }

  @override
  Future<List<TimelineDay>?> timelineDays(
    Account account, {
    List<String> path = const [],
    bool recursive = true,
    bool favorites = false,
    bool optional = false,
    bool existenceOnly = false,
    RecognizedPerson? person,
    PhotoMapBounds? mapBounds,
  }) async {
    final rows = await _memories(
      account,
      ['days'],
      {
        'folder': '/${path.join('/')}',
        if (recursive) 'recursive': '1',
        if (favorites) 'fav': '1',
        'nopreload': '1',
        if (existenceOnly) 'limit': '1',
        if (person != null) 'recognize': '${account.userId}/${person.id}',
        if (mapBounds != null) 'mapbounds': mapBounds.query,
      },
      optional: optional,
    );
    if (rows == null) return null;
    return rows
        .map((r) => parseNextcloudDay((r as Map).cast<String, dynamic>()))
        .where((d) => d.count > 0)
        .toList();
  }

  @override
  Future<List<CloudFile>> timelineDayFiles(
    Account account,
    List<int> dayIds, {
    List<String> path = const [],
    bool favorites = false,
    bool recursive = true,
    bool resolvePaths = true,
    RecognizedPerson? person,
    PhotoMapBounds? mapBounds,
  }) async {
    if (dayIds.isEmpty) return [];
    final rows = await _memories(
      account,
      ['days', dayIds.join(',')],
      {
        'folder': '/${path.join('/')}',
        if (recursive) 'recursive': '1',
        if (favorites) 'fav': '1',
        'nopreload': '1',
        if (person != null) 'recognize': '${account.userId}/${person.id}',
        if (mapBounds != null) 'mapbounds': mapBounds.query,
      },
    );
    final metadata = <String, Map<String, dynamic>>{};
    for (final row in rows!) {
      final data = (row as Map).cast<String, dynamic>();
      final id = data['fileid'];
      if (id is! int || id <= 0 || data['dayid'] is! int) {
        throw const FormatException('Unsupported Memories photo record.');
      }
      metadata[id.toString()] = data;
    }
    if (!resolvePaths) {
      return [
        for (final MapEntry(key: id, value: data) in metadata.entries)
          _memoryFile(id, data),
      ];
    }
    final found = await resolveFileIds(account, metadata.keys.toList());
    return [
      for (final MapEntry(key: id, value: data) in metadata.entries)
        if (found[id] case final file?) withMemoryDate(file, data),
    ];
  }

  /// Applies the capture date and revision from a Memories day row.
  static CloudFile withMemoryDate(CloudFile file, Map<String, dynamic> data) =>
      file.withCaptureDate(
        DateTime.fromMillisecondsSinceEpoch(
          (int.tryParse(data['epoch']?.toString() ?? '') ??
                  (data['dayid'] as int) * 86400) *
              1000,
          isUtc: true,
        ),
        data['etag'] as String?,
        day: data['dayid'] as int,
      );

  /// A grid-ready file built purely from a Memories row; its path is a
  /// placeholder until [resolveFileIds] finds the real location.
  static CloudFile _memoryFile(String id, Map<String, dynamic> data) {
    final name = data['basename']?.toString() ?? id;
    final video = data['isvideo'] == 1 || data['isvideo'] == true;
    final type = data['mimetype']?.toString();
    return withMemoryDate(
      CloudFile(
        path: [CloudFile.pendingRoot, id],
        name: name,
        isDirectory: false,
        contentType: type != null && type.contains('/')
            ? type
            : video
            ? 'video/mp4'
            : 'image/jpeg',
        size: data['size'] is int ? data['size'] as int : 0,
        id: id,
        favorite: data['isfavorite'] == 1 || data['isfavorite'] == true,
      ),
      data,
    );
  }

  /// Looks up real files for [ids] with a few concurrent search batches,
  /// never one request per photo.
  @override
  Future<Map<String, CloudFile>> resolveFileIds(
    Account account,
    List<String> ids, {
    int concurrency = 4,
  }) async {
    final batches = [
      for (var start = 0; start < ids.length; start += fileIdLimit)
        ids.skip(start).take(fileIdLimit).toList(),
    ];
    final found = <String, CloudFile>{};
    var next = 0;
    Future<void> worker() async {
      while (next < batches.length) {
        final batch = batches[next++];
        for (final file in await search(
          account,
          fileIds: batch,
          limit: batch.length,
        )) {
          if (file.id case final id?) found[id] = file;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < batches.length; i++) worker(),
    ]);
    return found;
  }

  @override
  Future<List<TimelineFolder>> timelineFolders(
    Account account,
    List<String> path,
  ) async {
    final rows = await _memories(
      account,
      ['folders', 'sub'],
      {'folder': '/${path.join('/')}'},
    );
    return rows!.map((row) {
      final data = (row as Map).cast<String, dynamic>();
      final name = data['name'] as String;
      validateName(name);
      final folder = [...path, name];
      final previews = (data['previews'] as List).map((value) {
        final item = (value as Map).cast<String, dynamic>();
        final id = item['fileid'].toString();
        return CloudFile(
          path: [...folder, 'cover-$id'],
          name: name,
          isDirectory: false,
          contentType: 'image/jpeg',
          id: id,
          etag: item['etag'] as String?,
        );
      }).toList();
      return TimelineFolder(folder, previews);
    }).toList();
  }

  @override
  Future<List<CloudFile>> timelineCover(
    Account account,
    List<String> path,
    int day,
  ) async {
    final rows = await _memories(
      account,
      ['days', '$day'],
      {'folder': '/${path.join('/')}', 'limit': '1', 'nopreload': '1'},
    );
    return rows!.map((row) {
      final item = (row as Map).cast<String, dynamic>();
      return CloudFile(
        path: [...path, 'cover-${item['fileid']}'],
        name: path.lastOrNull ?? 'Photos',
        isDirectory: false,
        contentType: 'image/jpeg',
        id: item['fileid'].toString(),
        etag: item['etag'] as String?,
      );
    }).toList();
  }

  @override
  Future<void> transfer(
    Account account,
    CloudFile file,
    List<String> destination, {
    bool copy = false,
  }) async {
    if (destination.isEmpty || destination.any((s) => s == '.' || s == '..')) {
      throw const CloudException('Choose a valid destination.');
    }
    validateName(destination.last);
    if (file.isDirectory && pathStartsWith(destination, file.path)) {
      throw const CloudException('A folder cannot be placed inside itself.');
    }
    final response = await _request(
      copy ? 'COPY' : 'MOVE',
      davUri(account, file.path),
      account: account,
      headers: {
        'Destination': davUri(account, destination).toString(),
        'Overwrite': 'F',
      },
    );
    _expect(response, {201, 204});
  }

  @override
  Future<void> delete(Account account, CloudFile file) async {
    final response = await _request(
      'DELETE',
      davUri(account, file.path),
      account: account,
    );
    _expect(response, {204});
  }

  Uri _trashUri(Account account, List<String> path) => serverEndpoint(
    account.server,
    ['remote.php', 'dav', 'trashbin', account.userId, ...path],
  );

  @override
  Future<List<TrashEntry>> trash(Account account) async {
    final root = _trashUri(account, ['trash']);
    final response = await _request(
      'PROPFIND',
      root,
      account: account,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body: '''
      <d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
        <d:prop><nc:trashbin-filename/><nc:trashbin-original-location/><nc:trashbin-deletion-time/></d:prop>
      </d:propfind>''',
    );
    _expect(response, {207});
    final result = <TrashEntry>[];
    for (final item in XmlDocument.parse(
      response.body,
    ).findAllElements('response', namespace: 'DAV:')) {
      final href = Uri.tryParse(
        item.getElement('href', namespace: 'DAV:')?.innerText ?? '',
      );
      if (href == null ||
          (href.hasAuthority && href.origin != account.server.origin)) {
        continue;
      }
      final segments = href.pathSegments.where((s) => s.isNotEmpty).toList();
      if (!pathStartsWith(segments, root.pathSegments) ||
          segments.length != root.pathSegments.length + 1) {
        continue;
      }
      final key = segments.last;
      validateName(key);
      final props = item
          .findElements('propstat', namespace: 'DAV:')
          .where(
            (p) => RegExp(r'\s200(?:\s|$)').hasMatch(
              p.getElement('status', namespace: 'DAV:')?.innerText ?? '',
            ),
          )
          .expand((p) => p.findElements('prop', namespace: 'DAV:'));
      String value(String name) =>
          props
              .expand(
                (p) =>
                    p.findElements(name, namespace: 'http://nextcloud.org/ns'),
              )
              .map((e) => e.innerText)
              .firstOrNull ??
          '';
      final name = value('trashbin-filename');
      if (name.isEmpty) continue;
      final time = int.tryParse(value('trashbin-deletion-time'));
      result.add(
        TrashEntry(
          key: key,
          name: name,
          originalPath: value('trashbin-original-location'),
          deleted: time == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(time * 1000),
        ),
      );
    }
    result.sort(
      (a, b) =>
          (b.deleted ?? DateTime(1970)).compareTo(a.deleted ?? DateTime(1970)),
    );
    return result;
  }

  @override
  Future<void> restore(Account account, TrashEntry entry) async {
    validateName(entry.key);
    final response = await _request(
      'MOVE',
      _trashUri(account, ['trash', entry.key]),
      account: account,
      headers: {
        // The virtual restore target requires DAV's default overwrite behavior.
        'Destination': _trashUri(account, ['restore', entry.key]).toString(),
      },
    );
    _expect(response, {201, 204});
  }

  Future<dynamic> _sharesRequest(
    Account account,
    String method, {
    String? id,
    Map<String, String> parameters = const {},
  }) async {
    final response = await _request(
      method,
      serverEndpoint(
        account.server,
        ['ocs', 'v2.php', 'apps', 'files_sharing', 'api', 'v1', 'shares', ?id],
        {'format': 'json', if (method == 'GET') ...parameters},
      ),
      account: account,
      headers: {
        'OCS-APIRequest': 'true',
        'Accept': 'application/json',
        if (method == 'POST')
          'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: method == 'POST' ? Uri(queryParameters: parameters).query : null,
    );
    _expect(response, {200});
    final ocs =
        (jsonDecode(response.body) as Map<String, dynamic>)['ocs']
            as Map<String, dynamic>;
    if ((ocs['meta'] as Map<String, dynamic>)['status'] != 'ok') {
      throw const CloudException(
        'Nextcloud rejected the sharing request. Check server sharing policies.',
      );
    }
    return ocs['data'];
  }

  PublicShare _share(Map<String, dynamic> data) {
    final url = Uri.parse(data['url'] as String);
    if (!url.hasAuthority || !['https', 'http'].contains(url.scheme)) {
      throw const CloudException('The server returned an invalid share URL.');
    }
    return PublicShare(
      id: data['id'].toString(),
      url: url,
      passwordProtected: data['password'] != null && data['password'] != '',
      expiration: data['expiration'] as String?,
    );
  }

  @override
  Future<List<PublicShare>> shares(Account account, CloudFile file) async {
    final data =
        await _sharesRequest(
              account,
              'GET',
              parameters: {'path': '/${file.path.join('/')}'},
            )
            as List<dynamic>;
    return data
        .cast<Map<String, dynamic>>()
        .where((s) => s['share_type'].toString() == '3')
        .map(_share)
        .toList();
  }

  @override
  Future<List<List<String>>> incomingSharedFolders(Account account) async {
    final data =
        await _sharesRequest(
              account,
              'GET',
              parameters: {'shared_with_me': 'true'},
            )
            as List<dynamic>;
    final folders = <String, List<String>>{};
    for (final item in data.cast<Map<String, dynamic>>()) {
      if (item['item_type'] != 'folder' ||
          item['uid_owner'] == account.userId ||
          item['uid_file_owner'] == account.userId ||
          item['share_type'].toString() == '3') {
        continue;
      }
      final path = item['path'];
      if (path is! String || !path.startsWith('/')) {
        throw const FormatException('Unsupported incoming shared-folder path.');
      }
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) {
        throw const FormatException('Unsupported incoming shared-folder path.');
      }
      for (final segment in segments) {
        validateName(segment);
      }
      folders[segments.map(Uri.encodeComponent).join('/')] = segments;
    }
    return folders.values
        .where(
          (path) => !folders.values.any(
            (parent) =>
                parent.length < path.length && pathStartsWith(path, parent),
          ),
        )
        .toList();
  }

  @override
  Future<PublicShare> createShare(
    Account account,
    CloudFile file, {
    String? password,
    DateTime? expires,
  }) async {
    final data = await _sharesRequest(
      account,
      'POST',
      parameters: {
        'path': '/${file.path.join('/')}',
        'shareType': '3',
        'permissions': '1',
        if (password != null && password.isNotEmpty) 'password': password,
        if (expires != null)
          'expireDate': expires.toIso8601String().split('T').first,
      },
    );
    return _share(data as Map<String, dynamic>);
  }

  @override
  Future<void> revokeShare(Account account, PublicShare share) async {
    await _sharesRequest(account, 'DELETE', id: share.id);
  }

  static List<CloudFile> parseFiles(String source, Account account) {
    final root = serverEndpoint(account.server, [
      'remote.php',
      'dav',
      'files',
      account.userId,
    ]).pathSegments;
    final document = XmlDocument.parse(source);
    final files = <CloudFile>[];
    for (final response in document.findAllElements(
      'response',
      namespace: 'DAV:',
    )) {
      final href = response.getElement('href', namespace: 'DAV:')?.innerText;
      if (href == null) continue;
      final uri = Uri.parse(href);
      if (uri.hasAuthority && uri.origin != account.server.origin) continue;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < root.length) continue;
      if (List.generate(
        root.length,
        (i) => segments[i] == root[i],
      ).contains(false)) {
        continue;
      }
      final path = segments.sublist(root.length);
      if (path.isEmpty ||
          path.any((s) => s == '.' || s == '..' || s.contains('/'))) {
        continue;
      }
      final props = response
          .findElements('propstat', namespace: 'DAV:')
          .where(
            (p) => RegExp(r'\s200(?:\s|$)').hasMatch(
              p.getElement('status', namespace: 'DAV:')?.innerText ?? '',
            ),
          )
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
      files.add(
        CloudFile(
          path: path,
          name: path.last,
          isDirectory: props.any(
            (p) =>
                p.findAllElements('collection', namespace: 'DAV:').isNotEmpty,
          ),
          contentType: value('getcontenttype'),
          size: int.tryParse(value('getcontentlength')) ?? 0,
          modified: _parseModified(value('getlastmodified')),
          id: value('fileid', 'http://owncloud.org/ns').isEmpty
              ? null
              : value('fileid', 'http://owncloud.org/ns'),
          favorite: value('favorite', 'http://owncloud.org/ns') == '1',
          etag: value('getetag').isEmpty ? null : value('getetag'),
        ),
      );
    }
    return files;
  }

  static DateTime? _parseModified(String modified) {
    final parts = modified.split(' ');
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    if (parts.length != 6) return null;
    final month = months.indexOf(parts[2]) + 1;
    final day = int.tryParse(parts[1]);
    final year = int.tryParse(parts[3]);
    final time = parts[4].split(':').map(int.tryParse).toList();
    if (month > 0 &&
        day != null &&
        year != null &&
        time.length == 3 &&
        !time.contains(null)) {
      return DateTime.utc(year, month, day, time[0]!, time[1]!, time[2]!);
    }
    return null;
  }

  @override
  Future<void> createFolder(Account account, List<String> path) async {
    validateName(path.last);
    final response = await _request(
      'MKCOL',
      davUri(account, path),
      account: account,
    );
    _expect(response, {201});
  }

  @override
  Future<void> setFavorite(Account account, CloudFile file, bool value) async {
    final response = await _request(
      'PROPPATCH',
      davUri(account, file.path),
      account: account,
      headers: {'Content-Type': 'application/xml; charset=utf-8'},
      body:
          '''
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
    if (statuses.isEmpty ||
        statuses.any((s) => !RegExp(r'\s200(?:\s|$)').hasMatch(s))) {
      throw const CloudException('The server could not update this favorite.');
    }
  }

  @override
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
        'User-Agent': 'ncloud/0.5.5',
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

  @override
  Future<CloudDownload> download(Account account, CloudFile file) async {
    final request = http.Request('GET', fileUri(account, file))
      ..followRedirects = false
      ..headers['Authorization'] = account.authorization;
    try {
      final response = await _transport.send(request).timeout(_timeout);
      if (response.statusCode != 200) {
        await response.stream.drain<void>().timeout(_timeout);
        throw statusError(response.statusCode);
      }
      return CloudDownload(response.stream);
    } on TimeoutException {
      throw const CloudException('Download timed out. Please try again.');
    } on http.ClientException {
      throw const CloudException(
        'Download interrupted. Check your connection.',
      );
    }
  }

  /// Downloads exactly the revision inventoried by folder sync.
  @override
  Future<CloudDownload> downloadVersion(Account account, CloudFile file) async {
    if (file.etag?.isNotEmpty != true) {
      throw const CloudException('A file revision is required for safe sync.');
    }
    final tag = file.etag!;
    if (tag.startsWith('W/')) {
      throw const CloudException(
        'Safe sync requires a strong server file revision.',
      );
    }
    final request = http.Request('GET', fileUri(account, file))
      ..followRedirects = false
      ..headers['Authorization'] = account.authorization
      ..headers['If-Match'] = tag.startsWith('"') ? tag : '"$tag"';
    try {
      final response = await _transport.send(request).timeout(_timeout);
      if (response.statusCode != 200) {
        await response.stream.drain<void>().timeout(_timeout);
        throw statusError(response.statusCode);
      }
      return CloudDownload(response.stream);
    } on TimeoutException {
      throw const CloudException(
        'Sync download timed out. Run again to resume.',
      );
    } on http.ClientException {
      throw const CloudException(
        'Sync download interrupted. Run again to resume.',
      );
    }
  }

  @override
  Future<Uint8List> preview(
    Account account,
    CloudFile file, {
    int size = 384,
  }) async {
    if (size < 1 || size > 2048) {
      throw ArgumentError.value(size, 'size', 'Must be between 1 and 2048');
    }
    if (_activePreviews >= 4) {
      final ready = Completer<void>();
      _previewQueue.add(ready);
      await ready.future;
    } else {
      _activePreviews++;
    }
    try {
      if (file.id == null) {
        throw const CloudException(
          'No preview is available. Download the original to view this file.',
        );
      }
      for (var attempt = 0; ; attempt++) {
        final uri = serverEndpoint(
          account.server,
          ['index.php', 'core', 'preview'],
          {'fileId': file.id!, 'x': '$size', 'y': '$size', 'a': 'true'},
        );
        final request = http.Request('GET', uri)
          ..followRedirects = false
          ..headers['Authorization'] = account.authorization;
        final response = await _transport.send(request).timeout(_timeout);
        if (response.statusCode != 200) {
          await response.stream.drain<void>().timeout(_timeout);
          if (attempt == 0 &&
              const {429, 502, 503, 504}.contains(response.statusCode)) {
            final seconds = int.tryParse(response.headers['retry-after'] ?? '');
            if (seconds == null || seconds <= 3) {
              await Future<void>.delayed(
                Duration(seconds: (seconds ?? 1).clamp(1, 3)),
              );
              continue;
            }
          }
          throw statusError(response.statusCode);
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream.timeout(_timeout)) {
          bytes.add(chunk);
          if (bytes.length > 8 * 1024 * 1024) {
            throw const CloudException('The preview is too large to display.');
          }
        }
        final result = bytes.takeBytes();
        if (result.isEmpty) {
          throw const CloudException('The server returned an empty preview.');
        }
        return result;
      }
    } on TimeoutException {
      throw const CloudException('Preview timed out. Tap to retry.');
    } on http.ClientException {
      throw const CloudException('Preview unavailable. Tap to retry.');
    } finally {
      // Newest first: after a fast scroll the tiles now on screen were
      // requested last.
      if (_previewQueue.isNotEmpty) {
        _previewQueue.removeLast().complete();
      } else {
        _activePreviews--;
      }
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
