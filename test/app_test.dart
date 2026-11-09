import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app/browse_target.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/main.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_account.dart';

import 'nextcloud_client_test.dart' show account;
import 'support/sample_library.dart';

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
      expect((controller.account! as NextcloudAccount).userId, 'alice');
      expect(controller.signingIn, isFalse);
      expect(controller.error, isNull);
      expect(store.value, isNotNull);
      final restored = AppController(store: store, client: client());
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(
        (restored.account! as NextcloudAccount).loginName,
        'alice@example.com',
      );
      expect((restored.account! as NextcloudAccount).userId, 'alice');
      expect(restored.error, isNull);
    },
  );

  test('a library supports folder creation, browsing and favorites', () async {
    final controller = sampleController();
    addTearDown(controller.dispose);
    await controller.load();
    expect(controller.items, hasLength(12));
    expect(controller.items.every((f) => f.isMedia), isTrue);
    await controller.select(Destination.drive);
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
  });

  testWidgets('signing out clears the account and returns to login', (
    tester,
  ) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('ncloud-signout-'),
    ))!;
    addTearDown(() => directory.deleteSync(recursive: true));
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => directory.path,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      ),
    );
    final store = MemoryStore()..value = 'saved';
    final c = AppController(store: store, client: SampleLibrary())
      ..timelineIndexAvailable = false
      ..account = account.withPhotoRoot(['Photos']);
    await tester.pumpWidget(NcloudApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.runAsync(() async {
      for (var i = 0; i < 300 && c.connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(c.connected, isFalse);
    expect(store.value, isNull);
    expect(find.text('Connect server'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the library opens on photos, filters and navigates folders', (
    tester,
  ) async {
    await pumpSampleLibrary(tester);
    expect(find.byTooltip('Timeline'), findsOneWidget);
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
    expect(tester.takeException(), isNull);
  });

  testWidgets('the gallery works at small phone width without overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpSampleLibrary(tester);
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
