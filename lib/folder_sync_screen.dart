import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'folder_sync.dart';
import 'library_actions.dart' show chooseFolder;
import 'screens.dart' show showError;
import 'android_folder_sync_screen.dart';
import 'sync_schedule.dart';

class FolderSyncScreen extends StatelessWidget {
  const FolderSyncScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => controller.folderSync.android
      ? AndroidFolderSyncScreen(controller: controller)
      : _IosFolderSyncScreen(controller: controller);
}

class _IosFolderSyncScreen extends StatefulWidget {
  const _IosFolderSyncScreen({required this.controller});
  final AppController controller;
  @override
  State<_IosFolderSyncScreen> createState() => _FolderSyncScreenState();
}

class _FolderSyncScreenState extends State<_IosFolderSyncScreen> {
  FolderSyncController get sync => widget.controller.folderSync;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    sync.load().whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _edit({FolderPair? pair}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _PairSetup(controller: widget.controller, pair: pair),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Folder sync'),
        actions: [
          IconButton(
            tooltip: 'Add sync pair',
            onPressed: _loading || sync.activeId != null ? null : () => _edit(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.shield_outlined),
                  const SizedBox(height: 12),
                  Text(
                    'Your files stay protected',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'No deletions or overwrites. Existing names get separate copies. '
                    'Removing a pair only removes its sync settings.',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    sync.ios
                        ? 'iPhone: select a Files folder for manual transfers, or an entire Apple Photos album for upload-only backup. '
                              'Saved access can be reused, but the provider may ask you to select it again. '
                              'Albums require full Photos access; individual photos cannot be selected here.'
                        : 'Android: select a folder using the system picker. '
                              'Scheduled backups are configured in Folder sync.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Wi-Fi only is on by default. Allowing mobile data can incur charges. '
                    'Files folders run while ncloud is open. Automatic albums also request iOS background opportunities, '
                    'but iOS decides when and how long they run. Force-quitting prevents background runs until reopening. '
                    'An interrupted file restarts on the next run.',
                  ),
                ],
              ),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (sync.error case final error?)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () async {
                              setState(() => _loading = true);
                              await sync.load();
                              if (mounted) setState(() => _loading = false);
                            },
                      child: const Text('Retry loading sync settings'),
                    ),
                  ],
                ),
              ),
            ),
          if (sync.activeId == null && sync.phase.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '${sync.phase}\n'
                '${sync.transferred} transferred · ${sync.conflicts} name conflicts',
              ),
            ),
          for (final pair in sync.pairs) _pair(pair),
          if (!_loading && sync.pairs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No sync pairs yet. Choose a device folder and a cloud destination.',
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loading || sync.activeId != null ? null : () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('Add sync pair'),
          ),
        ],
      ),
    ),
  );

  Widget _pair(FolderPair pair) {
    final active = sync.activeId == pair.id;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    pair.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Remove pair settings',
                  onPressed: sync.activeId != null
                      ? null
                      : () async {
                          final remove = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Remove sync pair?'),
                              content: const Text(
                                'Only settings and transfer history are removed. '
                                'Device and cloud files are not deleted. '
                                'Adding this pair again may create duplicate copies.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Keep'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Remove settings'),
                                ),
                              ],
                            ),
                          );
                          if (remove == true) {
                            try {
                              await sync.forget(pair);
                            } catch (e) {
                              if (mounted) showError(context, e);
                            }
                          }
                        },
                  icon: const Icon(Icons.link_off),
                ),
              ],
            ),
            Text(pair.mode.label),
            const SizedBox(height: 12),
            Text('Device: ${pair.folder.name}'),
            Text('Cloud: /${pair.cloudRoot.join('/')}'),
            if (pair.folder.kind == DeviceSourceKind.photoAlbum)
              Text(
                pair.schedule == null
                    ? 'Apple Photos album · manual upload'
                    : 'Apple Photos album · automatic every 15 minutes while open and on resume; iOS background is best effort.',
              ),
            if (sync.results[pair.id] case final result?)
              Text(
                'Last result: ${result['status'] ?? 'Not run yet'}'
                '${result['transferred'] == null ? '' : ' · ${result['transferred']} uploaded'}'
                '${result['error'] == null ? '' : '\n${result['error']}'}',
              ),
            if (!active && sync.results[pair.id]?['status'] == 'running')
              TextButton.icon(
                onPressed: () async {
                  try {
                    await sync.pauseScheduled(pair);
                  } catch (e) {
                    if (mounted) showError(context, e);
                  }
                },
                icon: const Icon(Icons.pause),
                label: const Text('Pause current background run'),
              ),
            Text(
              '${pair.wifiOnly ? 'Wi-Fi only' : 'Mobile data allowed'}'
              '${pair.chargingOnly ? ' · charging only' : ''}',
            ),
            const SizedBox(height: 12),
            if (active) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(sync.phase),
              Text(
                '${sync.transferred} transferred · ${sync.conflicts} name conflicts',
              ),
            ] else
              Text(
                pair.lastRun == null
                    ? 'Not synced yet'
                    : 'Last completed: ${MaterialLocalizations.of(context).formatCompactDate(pair.lastRun!.toLocal())} '
                          '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(pair.lastRun!.toLocal()))}',
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: active
                    ? sync.pause
                    : sync.activeId != null
                    ? null
                    : () => sync.run(pair),
                icon: Icon(active ? Icons.pause : Icons.sync),
                label: Text(active ? 'Pause after current file' : 'Sync now'),
              ),
            ),
            TextButton(
              onPressed: sync.activeId != null ? null : () => _edit(pair: pair),
              child: const Text('Edit sync settings'),
            ),
            if (pair.folder.kind == DeviceSourceKind.folder)
              TextButton(
                onPressed: sync.activeId != null
                    ? null
                    : () async {
                        try {
                          await sync.reconnect(pair);
                        } catch (e) {
                          if (mounted) showError(context, e);
                        }
                      },
                child: const Text('Reconnect device folder'),
              ),
          ],
        ),
      ),
    );
  }
}

class _PairSetup extends StatefulWidget {
  const _PairSetup({required this.controller, this.pair});
  final AppController controller;
  final FolderPair? pair;
  @override
  State<_PairSetup> createState() => _PairSetupState();
}

class _PairSetupState extends State<_PairSetup> {
  final _name = TextEditingController();
  DeviceFolder? _source;
  List<String>? _destination;
  SyncMode _mode = SyncMode.backup;
  bool _wifiOnly = true;
  bool _chargingOnly = false;
  bool _busy = false;
  bool _acknowledged = false;
  bool _automatic = false;
  FolderSyncController get sync => widget.controller.folderSync;
  bool get _album => _source?.kind == DeviceSourceKind.photoAlbum;

  @override
  void initState() {
    super.initState();
    final pair = widget.pair;
    if (pair != null) {
      _name.text = pair.name;
      _source = pair.folder;
      _destination = pair.remote;
      _mode = pair.mode;
      _wifiOnly = pair.wifiOnly;
      _chargingOnly = pair.chargingOnly;
      _automatic = pair.schedule != null;
      _acknowledged = true;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() => _busy = true);
    try {
      final selected = await sync.access.pick();
      if (mounted && selected != null) {
        setState(() {
          _source = selected;
          _automatic = false;
          if (_name.text.isEmpty) _name.text = selected.name;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAlbum() async {
    setState(() => _busy = true);
    try {
      final albums = await sync.photoAlbums();
      if (!mounted) return;
      final selected = await showModalBottomSheet<DeviceFolder>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: albums.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No accessible albums. Create an album in Photos and retry.',
                  ),
                )
              : ListView(
                  children: [
                    const ListTile(
                      title: Text('Choose an entire Photos album'),
                    ),
                    for (final album in albums)
                      ListTile(
                        leading: const Icon(Icons.photo_album_outlined),
                        title: Text(album.name),
                        onTap: () => Navigator.pop(context, album),
                      ),
                  ],
                ),
        ),
      );
      if (mounted && selected != null) {
        setState(() {
          _source = selected;
          _mode = SyncMode.backup;
          if (_name.text.isEmpty) _name.text = selected.name;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await sync.add(
        _name.text,
        _source!,
        _destination!,
        _mode,
        false,
        wifiOnly: _wifiOnly,
        chargingOnly: _chargingOnly,
        replacing: widget.pair,
        schedule: _album && _automatic
            ? widget.pair?.schedule ??
                  BackupSchedule(
                    kind: ScheduleKind.interval,
                    created: DateTime.now(),
                    minutes: 15,
                  )
            : null,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.pair == null ? 'Add sync pair' : 'Edit sync pair'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _name,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: 'Pair name'),
        ),
        const SizedBox(height: 16),
        ListTile(
          leading: const Icon(Icons.folder_open),
          title: const Text('Files folder on this device'),
          subtitle: Text(
            !_album
                ? _source?.name ?? 'Choose a folder in the system picker'
                : 'Choose a Files folder instead',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _pick,
        ),
        if (sync.ios)
          ListTile(
            leading: const Icon(Icons.photo_album_outlined),
            title: const Text('Apple Photos album'),
            subtitle: Text(
              _album
                  ? _source!.name
                  : 'Choose an entire album, not individual files',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _pickAlbum,
          ),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('On cloud'),
          subtitle: Text(
            _destination == null
                ? 'Choose an existing folder'
                : '/${_destination!.join('/')}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy
              ? null
              : () async {
                  final destination = await chooseFolder(
                    context,
                    widget.controller,
                    [],
                  );
                  if (mounted && destination != null) {
                    setState(() => _destination = destination);
                  }
                },
        ),
        const SizedBox(height: 16),
        if (!_album)
          DropdownButtonFormField<SyncMode>(
            initialValue: _mode,
            decoration: const InputDecoration(labelText: 'Transfer direction'),
            items: [
              for (final mode in SyncMode.values)
                DropdownMenuItem(value: mode, child: Text(mode.label)),
            ],
            onChanged: _busy ? null : (value) => setState(() => _mode = value!),
          ),
        if (_album) ...[
          const Text(
            'Upload only. Original photos, videos and Live Photo components stay in Photos.',
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Automatic album backup'),
            subtitle: const Text(
              'Starts when saved. Checks while open and on resume, and requests best-effort iOS background runs.',
            ),
            value: _automatic,
            onChanged: _busy
                ? null
                : (value) => setState(() => _automatic = value),
          ),
        ],
        const SizedBox(height: 16),
        if (!_album)
          const Text(
            'Includes all files and subfolders, not just photos. '
            'Changed files and name conflicts create separate copies; '
            'even two-way mode never propagates deletions. Empty folders are not copied.',
          ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Wi-Fi only'),
          value: _wifiOnly,
          onChanged: _busy
              ? null
              : (value) => setState(() => _wifiOnly = value),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Only while charging'),
          value: _chargingOnly,
          onChanged: _busy
              ? null
              : (value) => setState(() => _chargingOnly = value),
        ),
        const SizedBox(height: 16),
        const Text(
          'Select folders that do not overlap other pairs. Do not select a Files provider '
          'that already mirrors this cloud destination. The first run may create '
          'duplicate copies when names already exist. Large files require temporary '
          'device space; staging is separate from the browsing cache.',
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'I understand existing files stay unchanged and conflicts keep both copies.',
          ),
          value: _acknowledged,
          onChanged: _busy
              ? null
              : (value) => setState(() => _acknowledged = value!),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed:
              _busy || !_acknowledged || _source == null || _destination == null
              ? null
              : _save,
          child: const Text('Save pair'),
        ),
        const SizedBox(height: 12),
        Text(
          _album && _automatic
              ? 'Uploads start after saving. iOS controls background timing; Wi-Fi and charging restrictions always apply. No originals are deleted.'
              : 'No transfers start until you tap Sync now.',
        ),
      ],
    ),
  );
}
