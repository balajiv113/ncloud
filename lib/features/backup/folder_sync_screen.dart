import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_controller.dart';
import 'folder_sync.dart';
import '../../library_actions.dart' show chooseFolder;
import '../../screens.dart' show showError;
import 'sync_rules.dart';
import 'sync_schedule.dart';

class FolderSyncScreen extends StatefulWidget {
  const FolderSyncScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<FolderSyncScreen> createState() => _FolderSyncScreenState();
}

class _FolderSyncScreenState extends State<FolderSyncScreen> {
  FolderSyncController get sync => widget.controller.folderSync;
  bool _loading = true;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_loading) unawaited(sync.refreshResults());
    });
  }

  Future<void> _load() async {
    await sync.load();
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _edit([FolderPair? pair]) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          BackupSetupScreen(controller: widget.controller, pair: pair),
    ),
  );

  Future<void> _perform(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  String _status(FolderPair pair) {
    if (pair.requiresSetup) return 'Needs setup';
    if (sync.queuedIds.contains(pair.id)) return 'Queued';
    if (sync.activeId == pair.id) {
      return 'Backing up · ${sync.transferred} files confirmed';
    }
    final state = sync.results[pair.id];
    return switch (state?['status']) {
      'running' => 'Backing up',
      'success' => 'Completed',
      'paused' || 'interrupted' => 'Paused',
      'error' => 'Failed',
      _ => 'Ready',
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Folder backup'),
        actions: [
          IconButton(
            tooltip: 'Add backup',
            onPressed: _loading || sync.busy ? null : () => _edit(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (sync.error != null && sync.statusPairId == null) ...[
            Text(
              sync.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(
              onPressed: _loading
                  ? null
                  : () {
                      setState(() => _loading = true);
                      unawaited(_load());
                    },
              child: const Text('Retry'),
            ),
          ],
          if (sync.pairs.isNotEmpty) ...[
            FilledButton(
              onPressed:
                  _loading || !sync.pairs.any((pair) => !pair.requiresSetup)
                  ? null
                  : () => _perform(sync.busy ? sync.pauseAll : sync.runAll),
              child: Text(sync.busy ? 'Pause all' : 'Back up all'),
            ),
            const SizedBox(height: 12),
          ],
          for (final pair in sync.pairs) _card(pair),
          if (!_loading && sync.pairs.isEmpty)
            Center(
              child: TextButton.icon(
                onPressed: sync.error == null ? () => _edit() : null,
                icon: const Icon(Icons.add),
                label: const Text('Add backup'),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _card(FolderPair pair) {
    final state = sync.results[pair.id];
    final active = sync.activeId == pair.id || state?['status'] == 'running';
    final failed = state?['status'] == 'error';
    final schedule = pair.schedule;
    final scheduleLabel = schedule == null
        ? 'Manual'
        : 'Daily, ${TimeOfDay(hour: schedule.hour, minute: schedule.minute).format(context)}';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    pair.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Edit ${pair.name}',
                  onPressed: sync.busy || active ? null : () => _edit(pair),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
              ],
            ),
            Text(
              '${pair.folder.name} → /${pair.cloudRoot.join('/')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$scheduleLabel · ${_status(pair)}'
                    '${schedule != null && sync.scheduler.notice != null ? ' · ${sync.scheduler.notice}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: active
                      ? () => _perform(
                          sync.activeId == pair.id
                              ? sync.pause
                              : () => sync.pauseScheduled(pair),
                        )
                      : sync.busy || pair.requiresSetup
                      ? null
                      : () => _perform(() => sync.run(pair)),
                  child: Text(
                    active
                        ? 'Pause'
                        : failed
                        ? 'Retry'
                        : 'Back up',
                  ),
                ),
              ],
            ),
            if (active) const LinearProgressIndicator(),
            if (state?['error'] case final String message)
              Padding(
                padding: const EdgeInsets.only(bottom: 6, right: 8),
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (state?['errorCode'] == 'folder_permission' ||
                state?['errorCode'] == 'photos_permission' ||
                state?['errorCode'] == 'photos_album')
              TextButton(
                onPressed: sync.busy ? null : () => _edit(pair),
                child: const Text('Reselect source'),
              ),
          ],
        ),
      ),
    );
  }
}

class BackupSetupScreen extends StatefulWidget {
  const BackupSetupScreen({super.key, required this.controller, this.pair});
  final AppController controller;
  final FolderPair? pair;

  @override
  State<BackupSetupScreen> createState() => _BackupSetupScreenState();
}

class _BackupSetupScreenState extends State<BackupSetupScreen> {
  FolderSyncController get sync => widget.controller.folderSync;
  late final TextEditingController _include;
  late final TextEditingController _exclude;
  DeviceFolder? _source;
  FolderPair? _pair;
  List<String>? _destination;
  bool _daily = false;
  bool _wifiOnly = true;
  bool _busy = false;
  TimeOfDay _time = const TimeOfDay(hour: 14, minute: 0);

  @override
  void initState() {
    super.initState();
    final pair = widget.pair;
    _pair = pair;
    _source = pair?.folder;
    _destination = pair?.remote;
    _include = TextEditingController(text: pair?.rules.includeText ?? '');
    _exclude = TextEditingController(text: pair?.rules.excludeText ?? '');
    _wifiOnly = pair?.wifiOnly ?? true;
    _daily = pair?.schedule != null;
    if (pair?.schedule case final schedule?) {
      _time = TimeOfDay(hour: schedule.hour, minute: schedule.minute);
    }
  }

  @override
  void dispose() {
    _include.dispose();
    _exclude.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() operation) async {
    setState(() => _busy = true);
    try {
      await operation();
    } catch (e) {
      if (e is BackupScheduleFailure) _pair = e.pair;
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() => _perform(() async {
    DeviceFolder? selected;
    if (sync.ios) {
      final albums = await sync.photoAlbums();
      if (!mounted) return;
      selected = await showModalBottomSheet<DeviceFolder>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: albums.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No albums available'),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final album in albums)
                      ListTile(
                        title: Text(album.name),
                        onTap: () => Navigator.pop(context, album),
                      ),
                  ],
                ),
        ),
      );
    } else {
      selected = await sync.access.pick();
    }
    if (mounted && selected != null) setState(() => _source = selected);
  });

  Future<void> _save() => _perform(() async {
    final rules = SyncRules.patterns(_include.text, _exclude.text);
    final previous = _pair?.schedule;
    final unchanged =
        previous?.hour == _time.hour && previous?.minute == _time.minute;
    final schedule = _daily
        ? BackupSchedule(
            created: unchanged ? previous!.created : DateTime.now(),
            hour: _time.hour,
            minute: _time.minute,
          )
        : null;
    await sync.add(
      _source!.name,
      _source!,
      _destination!,
      wifiOnly: _wifiOnly,
      rules: rules,
      replacing: _pair,
      schedule: schedule,
    );
    if (mounted) Navigator.pop(context);
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_pair == null ? 'New backup' : 'Edit backup'),
      actions: [
        TextButton(
          onPressed:
              _busy ||
                  _source == null ||
                  _destination == null ||
                  (sync.ios && _source!.kind != DeviceSourceKind.photoAlbum)
              ? null
              : _save,
          child: const Text('Save'),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(sync.ios ? 'Photos album' : 'Device folder'),
          subtitle: Text(_source?.name ?? 'Choose source'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _pick,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Cloud destination'),
          subtitle: Text(
            _destination == null
                ? 'Choose folder'
                : '/${[..._destination!, if (_source != null) _source!.name].join('/')}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy
              ? null
              : () => _perform(() async {
                  final selected = await chooseFolder(
                    context,
                    widget.controller,
                    [],
                  );
                  if (mounted && selected != null) {
                    setState(() => _destination = selected);
                  }
                }),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _include,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Include patterns',
            hintText: '*.jpg, *.mp4',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _exclude,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: 'Exclude patterns',
            hintText: 'Screenshots/**, *.tmp',
          ),
        ),
        if (sync.scheduler.supported) ...[
          const SizedBox(height: 20),
          DropdownButtonFormField<bool>(
            initialValue: _daily,
            decoration: InputDecoration(
              labelText: 'Schedule',
              suffixText: sync.scheduler.notice ?? 'Best effort',
            ),
            items: const [
              DropdownMenuItem(value: false, child: Text('Manual')),
              DropdownMenuItem(value: true, child: Text('Daily')),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() => _daily = value!),
          ),
          if (_daily)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Time'),
              subtitle: Text(_time.format(context)),
              trailing: const Icon(Icons.schedule),
              onTap: _busy
                  ? null
                  : () async {
                      final time = await showTimePicker(
                        context: context,
                        initialTime: _time,
                      );
                      if (context.mounted && time != null) {
                        setState(() => _time = time);
                      }
                    },
            ),
        ],
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Wi-Fi only'),
          value: _wifiOnly,
          onChanged: _busy
              ? null
              : (value) => setState(() => _wifiOnly = value),
        ),
        if (_pair case final pair?)
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: _busy
                ? null
                : () => _perform(() async {
                    await sync.forget(pair);
                    if (context.mounted) Navigator.pop(context);
                  }),
            child: const Text('Remove backup'),
          ),
      ],
    ),
  );
}
