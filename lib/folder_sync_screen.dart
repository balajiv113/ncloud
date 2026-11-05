import 'dart:io';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'folder_sync.dart';
import 'library_actions.dart' show chooseFolder;
import 'screens.dart' show showError;

class FolderSyncScreen extends StatefulWidget {
  const FolderSyncScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<FolderSyncScreen> createState() => _FolderSyncScreenState();
}

class _FolderSyncScreenState extends State<FolderSyncScreen> {
  FolderSyncController get sync => widget.controller.folderSync;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    sync.load().whenComplete(() {
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _add() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _PairSetup(controller: widget.controller),
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
            onPressed: _loading || sync.activeId != null ? null : _add,
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
                    Platform.isIOS
                        ? 'iPhone: select a Files folder, then tap Sync now when needed. '
                              'Saved access can be reused, but the provider may ask you to select it again. '
                              'This does not back up the Apple Photos library.'
                        : 'Android: select a folder using the system picker. '
                              'Optional repeat runs every 15 minutes while ncloud is open.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Wi-Fi only is on by default. Allowing mobile data can incur charges. '
                    'Keep ncloud open; leaving the app pauses after the current file. '
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
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          for (final pair in sync.pairs.where((p) => !p.photoBackup))
            _pair(pair),
          if (!_loading && !sync.pairs.any((p) => !p.photoBackup))
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No sync pairs yet. Choose a device folder and a Nextcloud destination.',
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loading || sync.activeId != null ? null : _add,
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
                                'Device and Nextcloud files are not deleted. '
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
            Text('Nextcloud: /${pair.remote.join('/')}'),
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
            if (sync.android)
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Repeat while app is open'),
                subtitle: const Text(
                  'Every 15 minutes · no background guarantee',
                ),
                value: pair.repeat,
                onChanged: active
                    ? null
                    : (value) async {
                        try {
                          await sync.toggleRepeat(pair, value);
                        } catch (e) {
                          if (mounted) showError(context, e);
                        }
                      },
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
  const _PairSetup({required this.controller});
  final AppController controller;
  @override
  State<_PairSetup> createState() => _PairSetupState();
}

class _PairSetupState extends State<_PairSetup> {
  final _name = TextEditingController();
  DeviceFolder? _source;
  List<String>? _destination;
  SyncMode _mode = SyncMode.backup;
  bool _repeat = false;
  bool _wifiOnly = true;
  bool _chargingOnly = false;
  bool _busy = false;
  bool _acknowledged = false;
  FolderSyncController get sync => widget.controller.folderSync;

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
        _repeat,
        wifiOnly: _wifiOnly,
        chargingOnly: _chargingOnly,
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
    appBar: AppBar(title: const Text('Add sync pair')),
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
          title: const Text('On this device'),
          subtitle: Text(
            _source?.name ?? 'Choose a folder in the system picker',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _pick,
        ),
        ListTile(
          leading: const Icon(Icons.cloud_outlined),
          title: const Text('On Nextcloud'),
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
        DropdownButtonFormField<SyncMode>(
          initialValue: _mode,
          decoration: const InputDecoration(labelText: 'Transfer direction'),
          items: [
            for (final mode in SyncMode.values)
              DropdownMenuItem(value: mode, child: Text(mode.label)),
          ],
          onChanged: _busy ? null : (value) => setState(() => _mode = value!),
        ),
        const SizedBox(height: 16),
        const Text(
          'Includes all files and subfolders, not just photos. '
          'Changed files and name conflicts create separate copies; '
          'even two-way mode never propagates deletions. Empty folders are not copied.',
        ),
        if (sync.android)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Repeat while app is open'),
            subtitle: const Text(
              'Every 15 minutes, using the current connection',
            ),
            value: _repeat,
            onChanged: _busy
                ? null
                : (value) => setState(() => _repeat = value),
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
          'that already mirrors this Nextcloud destination. The first run may create '
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
        const Text(
          'No transfers start until you tap Sync now or an enabled repeat run becomes due.',
        ),
      ],
    ),
  );
}
