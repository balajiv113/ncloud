import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/main.dart';
import 'package:ncloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;

void main() {
  testWidgets('login remains usable with large text on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: NcloudApp(
          controller: AppController(
            store: MemoryStore(),
            client: NextcloudClient(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      MediaQuery.textScalerOf(tester.element(find.byType(Scaffold))).scale(10),
      20,
    );
    await tester.ensureVisible(find.text('Connect server'));
    expect(find.text('Connect server').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Use an app password instead'));
    await tester.tap(find.text('Use an app password instead'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign in with app password'));
    expect(
      find.text('Sign in with app password').hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
