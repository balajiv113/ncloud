import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ui/messages.dart';
import '../files/library_dialogs.dart';

/// Offers to upload files or create a folder in the folder being browsed.
Future<void> showAddFiles(BuildContext context, AppController c) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('Upload files'),
            subtitle: Text('Destination: /${c.directory.join('/')}'),
            onTap: () => Navigator.pop(context, 'upload'),
          ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('New folder'),
            onTap: () => Navigator.pop(context, 'folder'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  if (action == 'folder') {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const NameDialog(title: 'New folder'),
    );
    if (name != null) await c.createFolder(name);
    return;
  }
  try {
    final account = c.account;
    final destination = [...c.directory];
    final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (picked == null) return;
    for (final file in picked.files) {
      if (c.account != account || !listEquals(c.directory, destination)) {
        throw const FormatException(
          'Destination changed. Select your files again.',
        );
      }
      await c.upload(file.name, file.xFile.openRead(), file.size);
      if (c.error != null) break;
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
