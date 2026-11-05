import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'app_controller.dart';
import 'models.dart';
import 'screens.dart';

Future<bool> confirmDelete(BuildContext context, List<CloudFile> files) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Delete ${files.length == 1 ? files.single.name : '${files.length} items'}?',
        ),
        content: const Text(
          'This deletes the originals from Nextcloud, not just this view. Folder contents are included. Recovery depends on your server’s trash and retention settings.',
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
                file.isDirectory ? 'Folder album' : formatBytes(file.size),
              ),
            ),
            for (final (value, icon, label) in [
              (
                'favorite',
                file.favorite ? Icons.favorite : Icons.favorite_border,
                file.favorite ? 'Remove favorite' : 'Add favorite',
              ),
              ('link', Icons.link, 'Manage share links'),
              if (!file.isDirectory)
                ('download', Icons.ios_share, 'Download original & share'),
              ('rename', Icons.edit_outlined, 'Rename'),
              ('move', Icons.drive_file_move_outlined, 'Move to folder'),
              ('copy', Icons.copy_outlined, 'Copy to folder'),
              ('details', Icons.info_outline, 'Details'),
              ('delete', Icons.delete_outline, 'Delete from Nextcloud'),
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
  switch (action) {
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
      final destination = await chooseFolder(context, c, [file]);
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

Future<List<String>?> chooseFolder(
  BuildContext context,
  AppController c,
  List<CloudFile> sources,
) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => FolderPicker(controller: c, sources: sources),
);

class FolderPicker extends StatefulWidget {
  const FolderPicker({
    super.key,
    required this.controller,
    required this.sources,
  });
  final AppController controller;
  final List<CloudFile> sources;
  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  List<String> _path = [];
  late Future<List<CloudFile>> _folders = widget.controller.folderContents(
    _path,
  );
  void _open(List<String> value) => setState(() {
    _path = value;
    _folders = widget.controller.folderContents(_path);
  });
  bool _blocked(List<String> path) =>
      widget.sources.any((f) => f.isDirectory && pathStartsWith(path, f.path));

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: Column(
        children: [
          ListTile(
            title: const Text('Choose destination'),
            subtitle: Text(_path.isEmpty ? 'All files' : '/${_path.join('/')}'),
            leading: IconButton(
              tooltip: 'Parent folder',
              onPressed: _path.isEmpty
                  ? null
                  : () => _open(_path.sublist(0, _path.length - 1)),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<CloudFile>>(
              future: _folders,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: MessageCard(
                      message: errorMessage(snapshot.error!),
                      isError: true,
                      onRetry: () => _open(_path),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final folders = snapshot.data!
                    .where((f) => f.isDirectory)
                    .toList();
                return folders.isEmpty
                    ? const Center(
                        child: Text('No subfolders. You can use this folder.'),
                      )
                    : ListView(
                        children: [
                          for (final folder in folders)
                            ListTile(
                              enabled: !_blocked(folder.path),
                              leading: const Icon(Icons.folder_outlined),
                              title: Text(folder.name),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(folder.path),
                            ),
                        ],
                      );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _blocked(_path)
                  ? null
                  : () => Navigator.pop(context, _path),
              icon: const Icon(Icons.check),
              label: const Text('Use this folder'),
            ),
          ),
        ],
      ),
    ),
  );
}

class SharePanel extends StatefulWidget {
  const SharePanel({super.key, required this.controller, required this.file});
  final AppController controller;
  final CloudFile file;
  @override
  State<SharePanel> createState() => _SharePanelState();
}

class _SharePanelState extends State<SharePanel> {
  final _password = TextEditingController();
  DateTime? _expires;
  List<PublicShare> _links = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    if (widget.controller.demo) {
      if (mounted) setState(() => _links = []);
      return;
    }
    final links = await widget.controller.client.shares(
      widget.controller.account!,
      widget.file,
    );
    if (mounted) setState(() => _links = links);
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Share a little of your world',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(widget.file.name, maxLines: 2),
          const SizedBox(height: 16),
          const Text(
            'Anyone with a public link can view and download. Links are read-only; server policies may require a password or expiry.',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            MessageCard(
              message: _error!,
              isError: true,
              onRetry: _busy ? null : _load,
            ),
          if (widget.controller.demo)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'Connect a Nextcloud server to create real share links.',
              ),
            ),
          for (final link in _links)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      link.url.toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${link.passwordProtected ? 'Password protected' : 'No password'}${link.expiration == null ? '' : ' · ${link.expiration}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Wrap(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy'),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: link.url.toString()),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Link copied')),
                              );
                            }
                          },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.ios_share, size: 18),
                          label: const Text('Share'),
                          onPressed: () async {
                            try {
                              final box =
                                  context.findRenderObject() as RenderBox?;
                              await SharePlus.instance.share(
                                ShareParams(
                                  uri: link.url,
                                  sharePositionOrigin: box == null
                                      ? null
                                      : box.localToGlobal(Offset.zero) &
                                            box.size,
                                ),
                              );
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          },
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await widget.controller.client.revokeShare(
                                    widget.controller.account!,
                                    link,
                                  );
                                  if (mounted) {
                                    setState(
                                      () => _links.removeWhere(
                                        (s) => s.id == link.id,
                                      ),
                                    );
                                  }
                                }),
                          child: const Text('Revoke'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            enabled: !_busy && !widget.controller.demo,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Link password (optional)',
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy || widget.controller.demo
                ? null
                : () async {
                    final now = DateTime.now();
                    final date = await showDatePicker(
                      context: context,
                      firstDate: now.add(const Duration(days: 1)),
                      lastDate: now.add(const Duration(days: 365 * 5)),
                      initialDate: _expires ?? now.add(const Duration(days: 7)),
                    );
                    if (mounted && date != null) {
                      setState(() => _expires = date);
                    }
                  },
            icon: const Icon(Icons.schedule),
            label: Text(
              _expires == null
                  ? 'Set expiry date'
                  : 'Expires ${MaterialLocalizations.of(context).formatMediumDate(_expires!)}',
            ),
          ),
          if (_expires != null)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _expires = null),
              child: const Text('Remove expiry'),
            ),
          FilledButton.icon(
            onPressed: _busy || widget.controller.demo
                ? null
                : () => _run(() async {
                    final result = await widget.controller.client.createShare(
                      widget.controller.account!,
                      widget.file,
                      password: _password.text,
                      expires: _expires,
                    );
                    if (mounted) {
                      setState(() {
                        _links.add(result);
                        _password.clear();
                      });
                    }
                  }),
            icon: const Icon(Icons.add_link),
            label: const Text('Create read-only link'),
          ),
        ],
      ),
    ),
  );
}

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late Future<List<TrashEntry>> _items = widget.controller.trash();
  bool _busy = false;
  void _reload() => setState(() => _items = widget.controller.trash());
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Recently deleted'),
      actions: [
        IconButton(
          tooltip: 'Refresh trash',
          onPressed: _busy ? null : _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Recovery follows Nextcloud retention and naming rules. If the original folder is gone, items may restore to your root folder.',
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: FutureBuilder<List<TrashEntry>>(
            future: _items,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: MessageCard(
                    message: errorMessage(snapshot.error!),
                    isError: true,
                    onRetry: _reload,
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.data!.isEmpty) {
                return const Center(
                  child: Text('A clean slate. Nothing in trash.'),
                );
              }
              return ListView(
                children: [
                  for (final entry in snapshot.data!)
                    ListTile(
                      leading: const Icon(Icons.restore_from_trash_outlined),
                      title: Text(entry.name),
                      subtitle: Text(entry.originalPath),
                      trailing: TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                setState(() => _busy = true);
                                try {
                                  await widget.controller.restore(entry);
                                  _reload();
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                } finally {
                                  if (mounted) setState(() => _busy = false);
                                }
                              },
                        child: const Text('Restore'),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}

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
                    controller.demo
                        ? 'Welcome, explorer'
                        : controller.account?.displayName ?? 'Disconnected',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    controller.demo
                        ? 'Demo changes reset when you disconnect.'
                        : controller.account?.server.toString() ?? '',
                  ),
                ],
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('Private by design'),
            subtitle: Text(
              'Encrypted device credentials. Direct to your Nextcloud. No analytics or image proxy.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.photo_library_outlined),
            title: Text('Timeline & folder albums'),
            subtitle: Text(
              'Dates use file modification time. Load older pages as you browse. Albums are real folders, not duplicate uploads.',
            ),
          ),
          if (!controller.demo) _CacheTile(controller: controller),
          const ListTile(
            leading: Icon(Icons.construction_outlined),
            title: Text('Still on the roadmap'),
            subtitle: Text(
              'Automatic camera backup, folder sync, EXIF capture dates, maps, photo editing, Live Photos and multi-account libraries. AI features are intentionally excluded.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('ncloud 0.3 · streaming & offline cache'),
            subtitle: Text(
              'Keep the app open during transfers. Public links are read-only. Server permissions and retention rules apply.',
            ),
          ),
          if (controller.error case final error?)
            MessageCard(message: error, isError: true),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.logout),
            label: Text(
              controller.demo
                  ? 'Leave demo & connect server'
                  : 'Disconnect account',
            ),
            onPressed: controller.busy
                ? null
                : () async {
                    final yes = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Disconnect?'),
                        content: const Text(
                          'Remove local credentials and downloaded cache. Server files stay unchanged. Revoke the app password in Nextcloud to remove server access.',
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
        'thumbnails, library pages and saved videos load instantly on reopen.',
      ),
      trailing: TextButton(
        onPressed: () async {
          await widget.controller.clearCache();
          if (mounted) setState(() => _size = widget.controller.cacheSize());
        },
        child: const Text('Clear'),
      ),
    ),
  );
}
