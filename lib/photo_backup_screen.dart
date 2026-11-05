import 'dart:io';

import 'package:flutter/material.dart';
import 'app_controller.dart';
import 'folder_sync.dart';
import 'library_actions.dart' show chooseFolder;
import 'photo_backup.dart';
import 'screens.dart' show showError;

class PhotoBackupScreen extends StatefulWidget {
  const PhotoBackupScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<PhotoBackupScreen> createState() => _PhotoBackupScreenState();
}

class _PhotoBackupScreenState extends State<PhotoBackupScreen>
    with WidgetsBindingObserver {
  final source = PhotoLibraryAccess();
  FolderSyncController get sync => widget.controller.folderSync;
  String permission = 'checking';
  bool wifiOnly = true;
  bool busy = true;
  bool consent = false;
  List<String>? destination;
  FolderPair? get pair => sync.pairs.where((p) => p.photoBackup).singleOrNull;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sync.photoAccess = source;
    _load();
  }

  Future<void> _load() async {
    try {
      await sync.load();
      final status = await source.permission();
      if (!mounted) return;
      setState(() {
        permission = status;
        destination = pair?.remote;
        wifiOnly = pair?.wifiOnly ?? true;
        consent = pair != null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => permission = 'unavailable');
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) {
      source.permission().then(
        (value) {
          if (mounted) setState(() => permission = value);
        },
        onError: (Object error, StackTrace _) {
          if (mounted) showError(context, error);
        },
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _permission() async {
    setState(() => busy = true);
    try {
      final status = await source.permission(request: true);
      if (mounted) setState(() => permission = status);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _start() async {
    setState(() => busy = true);
    try {
      await sync.enablePhotos(
        source,
        wifiOnly: wifiOnly,
        destination: destination!,
      );
      if (mounted) setState(() => busy = false);
      await sync.run(pair!);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) {
      final active = sync.activeId != null;
      return Scaffold(
        appBar: AppBar(title: const Text('Photo backup')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.backup_outlined, size: 32),
                    const SizedBox(height: 12),
                    Text(
                      Platform.isAndroid
                          ? 'DCIM + Pictures → your Nextcloud'
                          : 'Photos library → your Nextcloud',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      Platform.isAndroid
                          ? 'Back up all indexed photos and videos under DCIM and Pictures, including their subfolders. No folder-by-folder selection.'
                          : 'Back up all accessible photos and videos, including Live Photo stills and motion. Full Photos access includes future additions on your next backup.',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${Platform.isAndroid ? 'DCIM and Pictures keep their existing subfolder structure under the cloud folder you choose.' : 'Everything goes directly into the cloud folder you choose. No date subfolders.'} '
                      'Originals are preserved; conflicting filenames get separate copies. '
                      'Deleting locally never deletes your backup.',
                    ),
                  ],
                ),
              ),
            ),
            if (permission == 'denied' || permission == 'limited')
              TextButton(
                onPressed: busy || active
                    ? null
                    : () async {
                        try {
                          await source.openSettings();
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                child: const Text('Open device permission settings'),
              ),
            ListTile(
              leading: Icon(
                permission == 'full'
                    ? Icons.check_circle_outline
                    : Icons.photo_library_outlined,
              ),
              title: Text(switch (permission) {
                'full' => 'Photos access: Full',
                'limited' => 'Photos access: Limited',
                'checking' => 'Checking Photos access',
                _ => 'Photos access required',
              }),
              subtitle: permission == 'limited'
                  ? const Text(
                      'Only approved items are accessible. Allow full access to back up the entire source.',
                    )
                  : null,
              trailing: permission == 'full'
                  ? null
                  : TextButton(
                      onPressed: busy || active ? null : _permission,
                      child: const Text('Allow access'),
                    ),
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('Nextcloud destination'),
              subtitle: Text(
                destination == null
                    ? 'Choose a folder once'
                    : '/${destination!.join('/')}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy || active
                  ? null
                  : () async {
                      final selected = await chooseFolder(
                        context,
                        widget.controller,
                        [],
                      );
                      if (mounted && selected != null) {
                        setState(() {
                          if (destination?.join('/') != selected.join('/')) {
                            consent = false;
                          }
                          destination = selected;
                        });
                      }
                    },
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Wi-Fi only'),
              subtitle: const Text('Checked before each original is prepared.'),
              value: wifiOnly,
              onChanged: busy || active
                  ? null
                  : (value) => setState(() => wifiOnly = value),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Keep ncloud open during backup. Tap Back up now again to include new items. '
                'Completed uploads are remembered across restarts. An interrupted original restarts in full. '
                'iCloud-only originals must download first and need temporary device space. '
                'This saves originals, not Apple Photos edit history or album organisation.',
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I understand existing files stay safe; name conflicts or a changed destination may create extra copies.',
              ),
              value: consent,
              onChanged: busy || active
                  ? null
                  : (value) => setState(() => consent = value!),
            ),
            if (sync.error case final error?)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (sync.phase.isNotEmpty) ...[
              if (active) const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(sync.phase),
              Text('${sync.transferred} originals confirmed this run'),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: active
                  ? sync.pause
                  : busy ||
                        !consent ||
                        destination == null ||
                        !['full', 'limited'].contains(permission)
                  ? null
                  : _start,
              icon: Icon(active ? Icons.pause : Icons.backup_outlined),
              label: Text(
                active ? 'Pause after current original' : 'Back up now',
              ),
            ),
            if (pair?.lastRun case final date?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Last completed: ${MaterialLocalizations.of(context).formatCompactDate(date.toLocal())}',
                ),
              ),
          ],
        ),
      );
    },
  );
}
