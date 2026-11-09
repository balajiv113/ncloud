import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/files/share_panel.dart';
import 'package:ncloud/models.dart';

import '../../support/sample_library.dart';

class _SharingLibrary extends SampleLibrary {
  final given = <FileShare>[];
  final searches = <String>[];

  @override
  Future<List<FileShare>> shares(Account account, CloudFile file) async =>
      List.of(given);

  @override
  Future<List<Sharee>> findSharees(
    Account account,
    String query, {
    required bool folder,
  }) async {
    searches.add(query);
    return const [
      Sharee(kind: ShareKind.user, id: 'sam', name: 'Sam Doe'),
      Sharee(kind: ShareKind.group, id: 'family', name: 'Family'),
    ];
  }

  @override
  Future<FileShare> shareWith(
    Account account,
    CloudFile file,
    Sharee sharee, {
    bool canEdit = false,
  }) async {
    final share = FileShare(
      id: '${given.length + 1}',
      kind: sharee.kind,
      isFolder: file.isDirectory,
      recipient: sharee.id,
      recipientName: sharee.name,
      canEdit: canEdit,
    );
    given.add(share);
    return share;
  }

  @override
  Future<FileShare> setShareEditable(
    Account account,
    FileShare share,
    bool canEdit,
  ) async {
    final updated = share.withEdit(canEdit);
    given[given.indexWhere((s) => s.id == share.id)] = updated;
    return updated;
  }

  @override
  Future<void> revokeShare(Account account, FileShare share) async =>
      given.removeWhere((s) => s.id == share.id);
}

void main() {
  testWidgets('a folder is shared with a person, made editable, then removed', (
    tester,
  ) async {
    final library = _SharingLibrary();
    final controller = sampleController(library);
    addTearDown(controller.dispose);
    const folder = CloudFile(
      path: ['Photos', 'Travel'],
      name: 'Travel',
      isDirectory: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharePanel(controller: controller, file: folder),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('People'), findsOneWidget);
    expect(find.text('Public link'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'sa');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(library.searches, ['sa']);
    expect(find.text('Sam Doe'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);

    await tester.tap(find.text('Sam Doe'));
    await tester.pumpAndSettle();
    expect(library.given.single.recipient, 'sam');
    expect(library.given.single.canEdit, isFalse);
    expect(find.text('Can view'), findsOneWidget);
    expect(find.text('Family'), findsNothing);

    await tester.tap(find.text('Can view'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Can edit').last);
    await tester.pumpAndSettle();
    expect(library.given.single.canEdit, isTrue);

    await tester.tap(find.byTooltip('Stop sharing with Sam Doe'));
    await tester.pumpAndSettle();
    expect(library.given, isEmpty);
    expect(find.text('Can edit'), findsNothing);
  });

  testWidgets('people already shared with are not offered again', (
    tester,
  ) async {
    final library = _SharingLibrary()
      ..given.add(
        const FileShare(
          id: '1',
          kind: ShareKind.user,
          recipient: 'sam',
          recipientName: 'Sam Doe',
        ),
      );
    final controller = sampleController(library);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SharePanel(
            controller: controller,
            file: const CloudFile(
              path: ['Photos', 'Travel'],
              name: 'Travel',
              isDirectory: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'sa');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Sam Doe'), findsOneWidget);
  });
}
