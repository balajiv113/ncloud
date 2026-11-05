import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/main.dart';
import 'package:ncloud/nextcloud_client.dart';

class MemoryStore implements SessionStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
  @override
  Future<void> clear() async => value = null;
}

void main() {
  testWidgets('Nextcloud blue theme stays readable in light and dark modes', (
    tester,
  ) async {
    await tester.pumpWidget(
      NcloudApp(
        controller: AppController(
          store: MemoryStore(),
          client: NextcloudClient(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    for (final brightness in Brightness.values) {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      await tester.pumpAndSettle();
      final scheme = Theme.of(
        tester.element(find.byType(Scaffold).first),
      ).colorScheme;
      expect(
        scheme.primary,
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF0082C9),
          brightness: brightness,
        ).primary,
      );
      expect(scheme.primary.b, greaterThan(scheme.primary.r));
      final foreground = scheme.onPrimary.computeLuminance();
      final background = scheme.primary.computeLuminance();
      final contrast = foreground > background
          ? (foreground + .05) / (background + .05)
          : (background + .05) / (foreground + .05);
      expect(contrast, greaterThanOrEqualTo(4.5));
      expect(tester.takeException(), isNull);
    }
  });

  test(
    'app-password sign-in persists credentials and restores the session',
    () async {
      final store = MemoryStore();
      NextcloudClient client() => NextcloudClient(
        transport: MockClient((request) async {
          if (request.url.path.contains('/apps/memories/')) {
            return http.Response('', 404);
          }
          if (request.url.path.endsWith('/cloud/user')) {
            return http.Response(
              jsonEncode({
                'ocs': {
                  'meta': {'status': 'ok'},
                  'data': {'id': 'alice', 'display-name': 'Alice'},
                },
              }),
              200,
            );
          }
          return http.Response('<d:multistatus xmlns:d="DAV:"/>', 207);
        }),
      );
      final controller = AppController(store: store, client: client());
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.passwordLogin(
        'https://cloud.example',
        'alice@example.com',
        'app-password',
      );
      expect(controller.connected, isTrue);
      expect(controller.account!.userId, 'alice');
      expect(controller.signingIn, isFalse);
      expect(controller.error, isNull);
      expect(store.value, isNotNull);
      final restored = AppController(store: store, client: client());
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.account!.loginName, 'alice@example.com');
      expect(restored.account!.userId, 'alice');
      expect(restored.error, isNull);
    },
  );

  test(
    'demo supports folder creation, browsing, and favorites without a server',
    () async {
      final store = MemoryStore();
      final controller = AppController(store: store, client: NextcloudClient());
      addTearDown(controller.dispose);
      await controller.initialize();
      controller.enterDemo();
      await controller.load();
      expect(controller.items, hasLength(12));
      expect(controller.items.every((f) => f.isMedia), isTrue);
      await controller.selectTab(1);
      expect(controller.items.any((f) => f.name == 'Photos'), isTrue);
      await controller.createFolder('New folder');
      expect(controller.items.any((f) => f.name == 'New folder'), isTrue);
      await controller.createFolder('New folder');
      expect(controller.error, contains('already exists'));
      final photos = controller.items.firstWhere((f) => f.name == 'Photos');
      await controller.openFolder(photos);
      expect(controller.directory, ['Photos']);
      final original = controller.items.first;
      await controller.favorite(original);
      expect(controller.items.first.favorite, !original.favorite);
      await controller.signOut();
      expect(controller.connected, isFalse);
      expect(store.value, isNull);
    },
  );

  testWidgets(
    'demo opens on photos, filters, navigates folders and returns to login',
    (tester) async {
      await tester.pumpWidget(
        NcloudApp(
          controller: AppController(
            store: MemoryStore(),
            client: NextcloudClient(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try demo'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Timeline'), findsOneWidget);
      expect(find.text('DEMO'), findsOneWidget);
      await tester.tap(find.byTooltip('Drive'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Search loaded items'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Documents');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Documents'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Photos'), findsNothing);
      await tester.tap(find.widgetWithText(ListTile, 'Documents'));
      await tester.pumpAndSettle();
      expect(find.text('Travel notes.pdf'), findsOneWidget);
      await tester.tap(find.text('All files'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to ncloud.txt'), findsOneWidget);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave demo & connect server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(find.text('Try demo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('demo gallery works at small phone width without overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(),
    );
    await tester.pumpWidget(NcloudApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try demo'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Drive'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Test folder');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(find.text('Test folder'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
