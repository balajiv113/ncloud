import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app/app_controller.dart';
import '../../diagnostics.dart';
import '../backup/ui/folder_backup_screen.dart';
import '../../core/ui/messages.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Your space')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.cloud_done_outlined, size: 36),
                  const SizedBox(height: 16),
                  Text(
                    controller.account?.displayName ?? 'Disconnected',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(controller.account?.serverLabel ?? ''),
                ],
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('Private by design'),
            subtitle: Text(
              'Encrypted device credentials. Direct to your server. No analytics or image proxy.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.photo_library_outlined),
            title: Text('Timeline & folder albums'),
            subtitle: Text(
              'Dates use capture dates when available, otherwise file modification time. Albums group existing photos without duplicate uploads.',
            ),
          ),
          if (Platform.isAndroid || Platform.isIOS)
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Folder backup'),
              subtitle: Text(
                Platform.isIOS
                    ? 'Choose Photos albums'
                    : 'Choose device folders',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => FolderBackupScreen(controller: controller),
                ),
              ),
            ),
          _CacheTile(controller: controller),
          const ListTile(
            leading: Icon(Icons.construction_outlined),
            title: Text('Still on the roadmap'),
            subtitle: Text(
              'Unattended backup scheduling, photo editing, Live Photos playback and multi-account libraries.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('ncloud 0.5.5 · Instant timeline'),
            subtitle: Text(
              'Keep the app open during transfers. Public links are read-only. Server permissions and retention rules apply.',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Support diagnostics'),
            subtitle: const Text(
              'Current session only. No account details, filenames, URLs or credentials. Nothing is sent automatically.',
            ),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Support diagnostics'),
                content: SingleChildScrollView(
                  child: SelectableText(Diagnostics.session.report()),
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      try {
                        await Clipboard.setData(
                          ClipboardData(text: Diagnostics.session.report()),
                        );
                        if (context.mounted) Navigator.pop(context);
                      } catch (error) {
                        if (context.mounted) showError(context, error);
                      }
                    },
                    child: const Text('Copy'),
                  ),
                  TextButton(
                    onPressed: () {
                      Diagnostics.session.clear();
                      Navigator.pop(context);
                    },
                    child: const Text('Clear'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ),
          if (controller.error case final error?)
            MessageCard(message: error, isError: true),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('Disconnect account'),
            onPressed: controller.busy
                ? null
                : () async {
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Disconnect?'),
                        content: const Text(
                          'Remove local credentials and downloaded cache. Server files stay unchanged. Revoke the app password in your server’s security settings to remove server access.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Disconnect'),
                          ),
                        ],
                      ),
                    );
                    if (yes == true) {
                      await controller.signOut();
                      if (context.mounted && !controller.connected) {
                        Navigator.pop(context);
                      }
                    }
                  },
          ),
        ],
      ),
    ),
  );
}

class _CacheTile extends StatefulWidget {
  const _CacheTile({required this.controller});
  final AppController controller;
  @override
  State<_CacheTile> createState() => _CacheTileState();
}

class _CacheTileState extends State<_CacheTile> {
  late Future<int> _size = widget.controller.cacheSize();

  String _format(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : bytes < 1024 * 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';

  @override
  Widget build(BuildContext context) => FutureBuilder<int>(
    future: _size,
    builder: (context, snapshot) => ListTile(
      leading: const Icon(Icons.offline_bolt_outlined),
      title: const Text('Offline cache'),
      subtitle: Text(
        '${snapshot.hasData ? _format(snapshot.data!) : 'Measuring…'} · '
        '500 MB shared limit for previews and library metadata. '
        'Saved offline files are separate, uncapped, and kept when clearing cache.',
      ),
      trailing: TextButton(
        onPressed: () async {
          try {
            await widget.controller.clearCache();
            if (mounted) setState(() => _size = widget.controller.cacheSize());
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        },
        child: const Text('Clear'),
      ),
    ),
  );
}
