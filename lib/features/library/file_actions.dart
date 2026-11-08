import 'package:flutter/material.dart';
import '../../app/app_controller.dart';
import '../../diagnostics.dart';
import '../../models.dart';
import '../../core/ui/messages.dart';
import 'library_dialogs.dart';
import 'share_panel.dart';
import '../../shared/ui/folder_picker.dart';

Future<bool> confirmDelete(BuildContext context, List<CloudFile> files) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Delete ${files.length == 1 ? files.single.name : '${files.length} items'}?',
        ),
        content: const Text(
          'This deletes the originals from your server, not just this view. Folder contents are included. Recovery depends on your server’s trash and retention settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

Future<void> fileActions(
  BuildContext context,
  AppController c,
  CloudFile file,
) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(file.name, maxLines: 2),
              subtitle: Text(
                file.isDirectory ? 'Folder' : formatBytes(file.size),
              ),
            ),
            for (final (value, icon, label) in [
              if (!file.readOnly)
                (
                  'favorite',
                  file.favorite ? Icons.favorite : Icons.favorite_border,
                  file.favorite ? 'Remove favorite' : 'Add favorite',
                ),
              if (!file.readOnly) ('link', Icons.link, 'Manage share links'),
              if (!file.isDirectory)
                ('download', Icons.ios_share, 'Download original & share'),
              if (!file.isDirectory)
                ('offline', Icons.download_outlined, 'Save offline'),
              if (!file.readOnly) ('rename', Icons.edit_outlined, 'Rename'),
              if (!file.readOnly)
                ('move', Icons.drive_file_move_outlined, 'Move to folder'),
              if (!file.readOnly)
                ('copy', Icons.copy_outlined, 'Copy to folder'),
              ('details', Icons.info_outline, 'Details'),
              if (!file.readOnly)
                ('delete', Icons.delete_outline, 'Delete from server'),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted || action == null || c.busy) return;
  if (action == 'details' ||
      ((action == 'move' || action == 'copy') && file.isDirectory)) {
    try {
      file = await c.resolve(file);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorMessage(e))));
      }
      return;
    }
  }
  if (!context.mounted) return;
  switch (action) {
    case 'offline':
      try {
        await c.saveOffline(file);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved for offline access')),
          );
        }
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    case 'favorite':
      await c.organize([file], 'favorite', favorite: !file.favorite);
    case 'link':
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SharePanel(controller: c, file: file),
      );
    case 'download':
      await shareFile(context, c, file);
    case 'rename':
      final name = await showDialog<String>(
        context: context,
        builder: (_) => NameDialog(title: 'Rename', initial: file.name),
      );
      if (name != null && name != file.name) {
        await c.organize([file], 'rename', newName: name);
      }
    case 'move' || 'copy':
      final destination = await chooseFolder(
        context,
        loadFolders: c.folderContents,
        sources: [file],
      );
      if (destination != null) {
        await c.organize([file], action, destination: destination);
      }
    case 'delete':
      if (await confirmDelete(context, [file])) {
        await c.organize([file], 'delete');
      }
    case 'details':
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(file.name, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 20),
                SelectableText('/${file.path.join('/')}'),
                const SizedBox(height: 12),
                Text(
                  file.isDirectory
                      ? 'Folder'
                      : '${file.contentType} · ${formatBytes(file.size)}',
                ),
                if (file.modified case final date?)
                  Text(
                    'Modified ${MaterialLocalizations.of(context).formatFullDate(date.toLocal())}',
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Timeline dates currently use file modification time, not EXIF capture time.',
                ),
              ],
            ),
          ),
        ),
      );
  }
}
