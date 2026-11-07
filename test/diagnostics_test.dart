import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/diagnostics.dart';
import 'package:ncloud/library_actions.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;

void main() {
  testWidgets('support information is visible and explicitly clearable', (
    tester,
  ) async {
    Diagnostics.session.clear();
    addTearDown(Diagnostics.session.clear);
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(),
    )..demo = true;
    addTearDown(controller.dispose);
    errorMessage(const CloudException('private server body', statusCode: 403));
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(controller: controller)),
    );
    await tester.scrollUntilVisible(find.text('Support diagnostics'), 200);
    await tester.tap(find.text('Support diagnostics'));
    await tester.pumpAndSettle();
    expect(find.textContaining('permission HTTP 403'), findsOneWidget);
    expect(find.textContaining('private server body'), findsNothing);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(Diagnostics.session.events, isEmpty);
  });

  test('support diagnostics never retain private exception content', () {
    final diagnostics = Diagnostics();
    const private = 'https://private.example/user/password-secret/photo.jpg';
    for (final error in [
      const CloudException(private, statusCode: 401),
      const FileSystemException(private, private),
      const FormatException(private),
      PlatformException(code: private, message: private),
      StateError(private),
    ]) {
      diagnostics.record(error);
    }
    final report = diagnostics.report();
    expect(report, isNot(contains('private.example')));
    expect(report, isNot(contains('password-secret')));
    expect(report, isNot(contains('photo.jpg')));
    expect(report, contains('authentication HTTP 401'));
    expect(diagnostics.events.map((event) => event.category), [
      FailureCategory.authentication,
      FailureCategory.storage,
      FailureCategory.invalidData,
      FailureCategory.device,
      FailureCategory.unexpected,
    ]);
  });

  test(
    'support events are bounded, immutable, clearable and session-local',
    () {
      final diagnostics = Diagnostics();
      for (var i = 0; i < Diagnostics.capacity + 10; i++) {
        diagnostics.record(TimeoutException('private data'));
      }
      expect(diagnostics.events, hasLength(Diagnostics.capacity));
      expect(diagnostics.events.last.category, FailureCategory.network);
      expect(() => diagnostics.events.clear(), throwsUnsupportedError);
      expect(Diagnostics().events, isEmpty);
      diagnostics.clear();
      expect(diagnostics.events, isEmpty);
      expect(diagnostics.report(), contains('Events: 0'));
    },
  );
}
