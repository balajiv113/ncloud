import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/shared/ui/drive_list.dart' show driveSubtitle;
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

import '../../nextcloud_client_test.dart' show account;

http.Response ok(Object data) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {'status': 'ok'},
      'data': data,
    },
  }),
  200,
);

Map<String, dynamic> userShare({
  String id = '7',
  int permissions = 1,
  String type = '0',
}) => {
  'id': id,
  'share_type': type == '0' ? 0 : int.parse(type),
  'share_with': 'alice',
  'share_with_displayname': 'Alice Doe',
  'item_type': 'folder',
  'permissions': permissions,
};

void main() {
  const folder = CloudFile(
    path: ['Photos', 'Trip'],
    name: 'Trip',
    isDirectory: true,
  );
  const photo = CloudFile(
    path: ['Photos', 'a.jpg'],
    name: 'a.jpg',
    isDirectory: false,
  );

  group('shares', () {
    test('lists people, groups and links, and skips other kinds', () async {
      final client = NextcloudClient(
        transport: MockClient(
          (_) async => ok([
            userShare(),
            {...userShare(id: '8', type: '1'), 'share_with': 'family'},
            {
              'id': 9,
              'share_type': 3,
              'url': 'https://cloud.example/s/x',
              'item_type': 'folder',
              'permissions': 1,
            },
            {'id': 10, 'share_type': 4, 'item_type': 'folder'},
          ]),
        ),
      );
      addTearDown(client.close);
      final shares = await client.shares(account, folder);
      expect(shares.map((s) => s.kind), [
        ShareKind.user,
        ShareKind.group,
        ShareKind.link,
      ]);
      expect(shares.first.recipientName, 'Alice Doe');
      expect(shares.first.canEdit, isFalse);
      expect(shares.last.url.toString(), 'https://cloud.example/s/x');
    });
  });

  group('findSharees', () {
    test(
      'merges exact and fuzzy matches, once each, without yourself',
      () async {
        late Uri requested;
        final client = NextcloudClient(
          transport: MockClient((request) async {
            requested = request.url;
            return ok({
              'exact': {
                'users': [
                  {
                    'label': 'Sam Doe',
                    'value': {'shareType': 0, 'shareWith': 'sam'},
                  },
                ],
                'groups': [],
              },
              'users': [
                {
                  'label': 'Sam Doe',
                  'value': {'shareType': 0, 'shareWith': 'sam'},
                },
                {
                  'label': 'Me',
                  'value': {'shareType': 0, 'shareWith': account.userId},
                },
                {
                  'label': 'Sally',
                  'value': {'shareType': 0, 'shareWith': 'sally'},
                },
              ],
              'groups': [
                {
                  'label': 'Family',
                  'value': {'shareType': 1, 'shareWith': 'family'},
                },
              ],
            });
          }),
        );
        addTearDown(client.close);
        final found = await client.findSharees(account, 'sa', folder: true);
        expect(found.map((s) => '${s.kind.name}:${s.id}'), [
          'user:sam',
          'user:sally',
          'group:family',
        ]);
        expect(requested.path, endsWith('/files_sharing/api/v1/sharees'));
        expect(requested.queryParameters['search'], 'sa');
        expect(requested.queryParameters['itemType'], 'folder');
      },
    );
  });

  group('shareWith', () {
    Future<Map<String, String>> post(
      CloudFile file,
      Sharee sharee, {
      required bool canEdit,
    }) async {
      late Map<String, String> body;
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.method, 'POST');
          body = Uri.splitQueryString(request.body);
          return ok(userShare(permissions: int.parse(body['permissions']!)));
        }),
      );
      addTearDown(client.close);
      await client.shareWith(account, file, sharee, canEdit: canEdit);
      return body;
    }

    const alice = Sharee(kind: ShareKind.user, id: 'alice', name: 'Alice');
    const family = Sharee(kind: ShareKind.group, id: 'family', name: 'Family');

    test('shares read-only by default with the right type', () async {
      final user = await post(folder, alice, canEdit: false);
      expect(user['shareType'], '0');
      expect(user['shareWith'], 'alice');
      expect(user['path'], '/Photos/Trip');
      expect(user['permissions'], '1');
      expect((await post(folder, family, canEdit: false))['shareType'], '1');
    });

    test(
      'editing a folder allows adding and deleting, a file only changing it',
      () async {
        expect((await post(folder, alice, canEdit: true))['permissions'], '15');
        expect((await post(photo, alice, canEdit: true))['permissions'], '3');
      },
    );

    test('a link is made with createLink, not shareWith', () async {
      final client = NextcloudClient(
        transport: MockClient((_) async => ok({})),
      );
      addTearDown(client.close);
      expect(
        () => client.shareWith(
          account,
          folder,
          const Sharee(kind: ShareKind.link, id: 'x', name: 'x'),
        ),
        throwsArgumentError,
      );
    });
  });

  test('changing a share sends its new permissions with PUT', () async {
    late http.Request seen;
    final client = NextcloudClient(
      transport: MockClient((request) async {
        seen = request;
        return ok(userShare(permissions: 15));
      }),
    );
    addTearDown(client.close);
    const share = FileShare(
      id: '7',
      kind: ShareKind.user,
      isFolder: true,
      recipient: 'alice',
    );
    final updated = await client.setShareEditable(account, share, true);
    expect(seen.method, 'PUT');
    expect(seen.url.path, endsWith('/shares/7'));
    expect(Uri.splitQueryString(seen.body)['permissions'], '15');
    expect(updated.canEdit, isTrue);
  });

  group('sharing marks on listed files', () {
    String listing(String props) =>
        """
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
  <d:response>
    <d:href>/nextcloud/remote.php/dav/files/${account.userId}/Mine/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>
      <oc:permissions>RGDNVCK</oc:permissions>
      <oc:share-types><oc:share-type>0</oc:share-type></oc:share-types>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/nextcloud/remote.php/dav/files/${account.userId}/Theirs/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>
      <oc:permissions>SRGDNVCK</oc:permissions><nc:is-mount-root>true</nc:is-mount-root>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/nextcloud/remote.php/dav/files/${account.userId}/Theirs/Inner/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>
      <oc:permissions>SRGDNVCK</oc:permissions><nc:is-mount-root>false</nc:is-mount-root>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/nextcloud/remote.php/dav/files/${account.userId}/Plain/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>
      <oc:permissions>RGDNVCK</oc:permissions><oc:share-types/>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  $props
</d:multistatus>""";

    test('tell folders shared by you from those shared with you', () {
      final files = {
        for (final f in NextcloudClient.parseFiles(listing(''), account))
          f.name: f,
      };
      expect(files['Mine']!.sharing, Sharing.byMe);
      expect(files['Theirs']!.sharing, Sharing.withMe);
      expect(files['Plain']!.sharing, Sharing.none);
    });

    test('only the root of a share counts, not what is inside it', () {
      final inner = NextcloudClient.parseFiles(
        listing(''),
        account,
      ).firstWhere((f) => f.name == 'Inner');
      expect(inner.sharing, Sharing.none);
    });

    test('a server that does not name the mount root is trusted', () {
      final files = NextcloudClient.parseFiles("""
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/nextcloud/remote.php/dav/files/${account.userId}/Old/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>
      <oc:permissions>SRGDNVCK</oc:permissions>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>""", account);
      expect(files.single.sharing, Sharing.withMe);
    });

    test('the mark survives saving and the subtitle says it in words', () {
      const folder = CloudFile(
        path: ['Mine'],
        name: 'Mine',
        isDirectory: true,
        sharing: Sharing.byMe,
      );
      expect(CloudFile.fromJson(folder.toJson()).sharing, Sharing.byMe);
      expect(folder.withFavorite(true).sharing, Sharing.byMe);
      expect(driveSubtitle(folder), 'Folder · Shared by you');
      expect(
        driveSubtitle(
          const CloudFile(
            path: ['T'],
            name: 'T',
            isDirectory: true,
            sharing: Sharing.withMe,
          ),
        ),
        'Folder · Shared with you',
      );
      expect(
        driveSubtitle(
          const CloudFile(path: ['a'], name: 'a', isDirectory: true),
        ),
        'Folder',
      );
    });
  });
}
