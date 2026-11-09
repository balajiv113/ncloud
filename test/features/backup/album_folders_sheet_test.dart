import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/platform/album_folders.dart';
import 'package:ncloud/features/backup/ui/album_folders_sheet.dart';

void main() {
  const w1 = AlbumChoice('t1', 'W1');
  const trips = AlbumChoice('t2', 'Trips');

  Future<List<AlbumChoice>?> open(
    WidgetTester tester, {
    List<AlbumChoice> chosen = const [],
  }) async {
    List<AlbumChoice>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => AlbumFoldersSheet(
                available: const [w1, trips],
                chosen: chosen,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('adds albums in the order they are tapped', (tester) async {
    List<AlbumChoice>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) =>
                  const AlbumFoldersSheet(available: [w1, trips], chosen: []),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add an album'), findsOneWidget);
    await tester.tap(find.text('Trips'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('W1'));
    await tester.pumpAndSettle();
    expect(find.text('Add an album'), findsNothing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect([for (final a in result!) a.name], ['Trips', 'W1']);
  });

  testWidgets('removes an album and starts from what was chosen', (
    tester,
  ) async {
    await open(tester, chosen: const [w1]);
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove W1'));
    await tester.pumpAndSettle();
    expect(find.text('Add an album'), findsOneWidget);
    expect(find.text('Trips'), findsOneWidget);
  });
}
