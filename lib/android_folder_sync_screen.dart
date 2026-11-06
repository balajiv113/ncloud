import 'dart:async';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'folder_sync.dart';
import 'library_actions.dart' show chooseFolder;
import 'sync_background.dart';
import 'cloud_backend.dart' show CloudException;
import 'screens.dart' show showError;
import 'sync_rules.dart';
import 'sync_schedule.dart';

class AndroidFolderSyncScreen extends StatefulWidget {
  const AndroidFolderSyncScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<AndroidFolderSyncScreen> createState() =>
      _AndroidFolderSyncScreenState();
}

class _AndroidFolderSyncScreenState extends State<AndroidFolderSyncScreen> {
  FolderSyncController get sync => widget.controller.folderSync;
  bool loading = true;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    sync.load().whenComplete(() {
      if (mounted) setState(() => loading = false);
    });
    _refresh = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!loading) unawaited(sync.refreshResults());
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _edit({FolderPair? pair}) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          AndroidSyncSetup(controller: widget.controller, pair: pair),
    ),
  );

  Future<void> _add() => _edit();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: sync,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Folder sync'),
        actions: [
          IconButton(
            tooltip: 'Add folder',
            onPressed: loading || sync.activeId != null ? null : _add,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Choose folders. Decide what gets uploaded.'),
          const SizedBox(height: 20),
          if (loading) const LinearProgressIndicator(),
          if (sync.error case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          for (final pair in sync.pairs) _card(pair),
          if (!loading && sync.pairs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Text(
                'No folders added. Choose a device folder and a cloud location.',
              ),
            ),
          const SizedBox(height: 16),
          const Text('No deletions or overwrites. Conflicts keep both.'),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: loading || sync.activeId != null ? null : _add,
            icon: const Icon(Icons.add),
            label: const Text('Add folder'),
          ),
        ],
      ),
    ),
  );

  Widget _card(FolderPair pair) {
    final active = sync.activeId == pair.id;
    final schedule = pair.schedule;
    final result = sync.results[pair.id];
    final slot = schedule?.dueSlot(DateTime.now());
    final due =
        slot != null &&
        !(result?['revision'] == pair.revision &&
            schedule!.handled(slot, result?['slot'] as String?));
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
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
                  tooltip: 'Edit ${pair.name}',
                  onPressed: sync.activeId != null
                      ? null
                      : () => _edit(pair: pair),
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
            Text(pair.folder.name),
            const SizedBox(height: 8),
            Text('Cloud: /${pair.cloudRoot.join('/')}'),
            const SizedBox(height: 10),
            if (pair.schedule case final schedule?) ...[
              Text('Schedule: ${schedule.kind.name} · Android best effort'),
              Text(
                due
                    ? 'Due now · waiting for Android'
                    : 'Next due: ${schedule.next(DateTime.now()).toLocal()}',
              ),
              if (sync.results[pair.id] case final result?)
                Text(
                  'Last result: ${result['status'] ?? 'Not run yet'}'
                  '${result['transferred'] == null ? '' : ' · ${result['transferred']} confirmed'}'
                  '${result['error'] == null ? '' : '\n${result['error']}'}',
                ),
              if (sync.results[pair.id]?['status'] == 'running' && !active)
                TextButton.icon(
                  onPressed: () async {
                    try {
                      await sync.pauseScheduled(pair);
                    } catch (e) {
                      if (mounted) showError(context, e);
                    }
                  },
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause scheduled run'),
                ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Chip(
                  label: Text(
                    pair.mode == SyncMode.backup
                        ? 'Upload only'
                        : pair.mode.label,
                  ),
                ),
                Chip(label: Text(pair.rules.types.label)),
                if (pair.rules.excluded.isNotEmpty)
                  Chip(label: Text('${pair.rules.excluded.length} excluded')),
                if (pair.background) const Chip(label: Text('Background on')),
              ],
            ),
            const SizedBox(height: 10),
            if (active) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(sync.phase),
              Text(
                '${sync.transferred} confirmed · ${pair.uploadConcurrency} upload lanes',
              ),
            ] else
              Text(
                pair.lastRun == null
                    ? 'Ready to back up'
                    : 'Last completed: ${MaterialLocalizations.of(context).formatCompactDate(pair.lastRun!.toLocal())}',
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: active
                    ? sync.pause
                    : sync.activeId != null
                    ? null
                    : () => sync.run(pair),
                icon: Icon(active ? Icons.pause : Icons.upload_outlined),
                label: Text(
                  active
                      ? 'Pause after current files'
                      : pair.mode == SyncMode.backup
                      ? 'Back up now'
                      : 'Sync now',
                ),
              ),
            ),
            if (!active &&
                sync.activeId == null &&
                sync.statusPairId == pair.id &&
                sync.phase.isNotEmpty)
              Text(sync.phase, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class AndroidSyncSetup extends StatefulWidget {
  const AndroidSyncSetup({super.key, required this.controller, this.pair});
  final AppController controller;
  final FolderPair? pair;
  @override
  State<AndroidSyncSetup> createState() => _AndroidSyncSetupState();
}

class _AndroidSyncSetupState extends State<AndroidSyncSetup> {
  FolderSyncController get sync => widget.controller.folderSync;
  late final TextEditingController name;
  DeviceFolder? source;
  List<String>? destination;
  late SyncRules rules;
  late SyncMode mode;
  late bool wifiOnly, chargingOnly, background;
  ScheduleKind? scheduleKind;
  late final TextEditingController interval;
  late TimeOfDay scheduleTime;
  late int weekday;
  late int concurrency;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    final pair = widget.pair;
    name = TextEditingController(text: pair?.name ?? '');
    source = pair?.folder;
    destination = pair?.remote;
    rules = pair?.rules ?? const SyncRules.all();
    mode = pair?.mode ?? SyncMode.backup;
    wifiOnly = pair?.wifiOnly ?? true;
    chargingOnly = pair?.chargingOnly ?? false;
    scheduleKind = pair?.schedule?.kind;
    interval = TextEditingController(text: '${pair?.schedule?.minutes ?? 60}');
    scheduleTime = TimeOfDay(
      hour: pair?.schedule?.hour ?? 2,
      minute: pair?.schedule?.minute ?? 0,
    );
    weekday = pair?.schedule?.weekday ?? DateTime.monday;
    background = pair?.background ?? false;
    concurrency = pair?.uploadConcurrency ?? 3;
  }

  @override
  void dispose() {
    name.dispose();
    interval.dispose();
    super.dispose();
  }

  Future<void> _pickSource() async {
    setState(() => busy = true);
    try {
      final selected = await sync.access.pick();
      if (mounted && selected != null) {
        setState(() {
          if (source?.identity != selected.identity) {
            rules = const SyncRules.all();
          }
          source = selected;
          if (name.text.isEmpty) name.text = selected.name;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _selectRules(bool inclusion) async {
    setState(() => busy = true);
    try {
      if (!mounted) return;
      Future<List<String>> children(List<String> path) async {
        return [
          for (final entry in await sync.access.list(source!.token, path))
            if (entry.directory) entry.name,
        ]..sort();
      }

      final selected = await Navigator.of(context).push<List<List<String>>>(
        MaterialPageRoute(
          builder: (_) => SyncFolderRulesScreen(
            inclusion: inclusion,
            rootName: source!.name,
            initial: inclusion ? rules.included : rules.excluded,
            included: rules.included,
            children: children,
          ),
        ),
      );
      if (selected != null && mounted) {
        setState(
          () => rules = SyncRules(
            included: inclusion ? selected : rules.included,
            excluded: inclusion ? rules.excluded : selected,
            types: rules.types,
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _types() async {
    final value = await showModalBottomSheet<SyncFileTypes>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final type in SyncFileTypes.values)
              ListTile(
                title: Text(type.label),
                trailing: rules.types == type ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, type),
              ),
          ],
        ),
      ),
    );
    if (value != null && mounted) {
      setState(
        () => rules = SyncRules(
          included: rules.included,
          excluded: rules.excluded,
          types: value,
        ),
      );
    }
  }

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      if ((background || scheduleKind != null) &&
          !await sync.backgroundService.permission()) {
        throw const CloudException(
          'Allow ncloud notifications in device Settings, or turn off Continue in background.',
        );
      }
      final minutes = int.tryParse(interval.text);
      if (scheduleKind == ScheduleKind.interval &&
          (minutes == null || minutes < 15)) {
        throw const FormatException(
          'Enter an interval of at least 15 minutes.',
        );
      }
      final original = widget.pair?.schedule;
      final unchanged =
          original?.kind == scheduleKind &&
          original?.minutes == minutes &&
          original?.hour == scheduleTime.hour &&
          original?.minute == scheduleTime.minute &&
          original?.weekday == weekday;
      final schedule = scheduleKind == null
          ? null
          : BackupSchedule(
              kind: scheduleKind!,
              created: unchanged ? original!.created : DateTime.now(),
              minutes: scheduleKind == ScheduleKind.interval ? minutes! : 60,
              hour: scheduleTime.hour,
              minute: scheduleTime.minute,
              weekday: weekday,
            );
      await sync.add(
        name.text,
        source!,
        destination!,
        mode,
        false,
        wifiOnly: wifiOnly,
        chargingOnly: chargingOnly,
        rules: rules,
        uploadConcurrency: concurrency,
        background: background,
        replacing: widget.pair,
        schedule: schedule,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove folder settings?'),
        content: const Text(
          'Device and cloud files stay untouched. Adding this folder again may create extra copies.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove settings'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    try {
      await sync.forget(widget.pair!);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSource = source != null;
    final canRules = hasSource;
    final ready =
        !busy && destination != null && canRules && rules.included.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.pair == null ? 'Add folder' : 'Edit folder'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Device folder'),
            subtitle: Text(source?.name ?? 'Choose a folder'),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : _pickSource,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('Cloud location'),
            subtitle: Text(
              destination == null
                  ? 'Choose a folder'
                  : '/${destination!.join('/')}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy
                ? null
                : () async {
                    final path = await chooseFolder(
                      context,
                      widget.controller,
                      [],
                    );
                    if (mounted && path != null) {
                      setState(() => destination = path);
                    }
                  },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Included subfolders'),
            subtitle: Text(_includedLabel(rules)),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy || !canRules ? null : () => _selectRules(true),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('File types'),
            subtitle: Text(rules.types.label),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : _types,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Excluded folders'),
            subtitle: Text(
              rules.excluded.isEmpty
                  ? 'None'
                  : rules.excluded
                        .map((p) => p.isEmpty ? 'Entire source' : p.join(' / '))
                        .join('\n'),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy || !canRules ? null : () => _selectRules(false),
          ),
          if (hasSource && destination != null)
            SyncCloudPreview(
              destination: destination!,
              source: source?.name ?? '',
              rules: rules,
              download: mode == SyncMode.download,
            ),
          if (sync.scheduler.supported) ...[
            DropdownButtonFormField<String>(
              initialValue: scheduleKind?.name ?? 'off',
              decoration: const InputDecoration(labelText: 'Scheduled backup'),
              items: [
                const DropdownMenuItem(
                  value: 'off',
                  child: Text('Off · manual only'),
                ),
                for (final kind in ScheduleKind.values)
                  DropdownMenuItem(value: kind.name, child: Text(kind.name)),
              ],
              onChanged: busy
                  ? null
                  : (value) => setState(() {
                      scheduleKind = value == 'off'
                          ? null
                          : ScheduleKind.values.byName(value!);
                      if (scheduleKind != null) mode = SyncMode.backup;
                    }),
            ),
            if (scheduleKind == ScheduleKind.interval)
              TextField(
                controller: interval,
                enabled: !busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Interval in minutes (minimum 15)',
                ),
              ),
            if (scheduleKind == ScheduleKind.daily ||
                scheduleKind == ScheduleKind.weekly)
              ListTile(
                title: const Text('Local device time'),
                subtitle: Text(scheduleTime.format(context)),
                onTap: busy
                    ? null
                    : () async {
                        final time = await showTimePicker(
                          context: context,
                          initialTime: scheduleTime,
                        );
                        if (mounted && time != null) {
                          setState(() => scheduleTime = time);
                        }
                      },
              ),
            if (scheduleKind == ScheduleKind.weekly)
              DropdownButtonFormField<int>(
                initialValue: weekday,
                decoration: const InputDecoration(labelText: 'Weekday'),
                items: [
                  for (var day = 1; day <= 7; day++)
                    DropdownMenuItem(
                      value: day,
                      child: Text(
                        const [
                          'Monday',
                          'Tuesday',
                          'Wednesday',
                          'Thursday',
                          'Friday',
                          'Saturday',
                          'Sunday',
                        ][day - 1],
                      ),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => weekday = value!),
              ),
            if (scheduleKind != null) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Android best effort, not an alarm. Battery restrictions, force-stop, '
                  'network and charging can delay backups. Uses current device timezone; '
                  'missed times coalesce into one run. Originals are never deleted.',
                ),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          if (!await sync.backgroundService.permission(
                            request: true,
                          )) {
                            throw const CloudException(
                              'Enable ncloud notifications in device Settings.',
                            );
                          }
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                child: const Text('Allow scheduled backup notifications'),
              ),
            ],
          ],
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Continue in background'),
            subtitle: const Text('Ongoing Android notification with Pause'),
            value: background,
            onChanged: busy
                ? null
                : (value) async {
                    setState(() => busy = true);
                    try {
                      if (value &&
                          !await sync.backgroundService.permission(
                            request: true,
                          )) {
                        throw const CloudException(
                          'Notifications were denied. Allow ncloud notifications in Settings to use background uploads.',
                        );
                      }
                      if (mounted) setState(() => background = value);
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('More options'),
            subtitle: Text(
              '${wifiOnly ? 'Wi-Fi only' : 'Mobile data allowed'} · $concurrency parallel uploads',
            ),
            children: [
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          await NativeSyncBackground.openSettings();
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                child: const Text('Device notification settings'),
              ),
              ...[
                TextField(
                  controller: name,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: 'Folder name'),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<SyncMode>(
                  initialValue: mode,
                  decoration: const InputDecoration(
                    labelText: 'Transfer direction',
                  ),
                  items: [
                    for (final m in SyncMode.values)
                      DropdownMenuItem(value: m, child: Text(m.label)),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setState(() => mode = value!),
                ),
              ],
              SwitchListTile.adaptive(
                title: const Text('Wi-Fi only'),
                value: wifiOnly,
                onChanged: busy ? null : (v) => setState(() => wifiOnly = v),
              ),
              SwitchListTile.adaptive(
                title: const Text('Only while charging'),
                value: chargingOnly,
                onChanged: busy
                    ? null
                    : (v) => setState(() => chargingOnly = v),
              ),
              DropdownButtonFormField<int>(
                initialValue: concurrency,
                decoration: const InputDecoration(
                  labelText: 'Parallel uploads',
                ),
                items: [
                  for (final n in [1, 2, 3])
                    DropdownMenuItem(
                      value: n,
                      child: Text('$n ${n == 1 ? 'upload' : 'uploads'}'),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() => concurrency = v!),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Each upload needs temporary space for an original. '
                  'Completed files are remembered; interrupted files restart in full. '
                  'Android can limit or stop background work. Rules apply in both directions; '
                  'exclusions win and never remove existing cloud copies.',
                ),
              ),
              if (widget.pair != null)
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          try {
                            await sync.reconnect(widget.pair!);
                            if (mounted) {
                              setState(
                                () => source = sync.pairs
                                    .firstWhere((p) => p.id == widget.pair!.id)
                                    .folder,
                              );
                            }
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                  child: const Text('Reconnect device folder'),
                ),
              if (widget.pair != null)
                TextButton(
                  onPressed: busy ? null : _remove,
                  child: const Text('Remove folder settings'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('No deletions or overwrites. Conflicts keep both.'),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: ready ? _save : null,
            child: const Text('Save backup'),
          ),
          const SizedBox(height: 10),
          Text(
            background
                ? 'Background transfers start when you tap Back up now.'
                : 'Keep ncloud open during transfers.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  String _includedLabel(SyncRules value) => value.included.isEmpty
      ? 'None selected'
      : value.included.any((p) => p.isEmpty)
      ? 'Entire folder, including subfolders'
      : value.included.map((p) => p.join(' / ')).join('\n');
}

class SyncCloudPreview extends StatelessWidget {
  const SyncCloudPreview({
    super.key,
    required this.destination,
    required this.source,
    required this.rules,
    this.download = false,
  });
  final List<String> destination;
  final bool download;
  final String source;
  final SyncRules rules;

  @override
  Widget build(BuildContext context) {
    final roots = [source];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            download ? 'Cloud source' : 'Saved in cloud',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 10),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  tileColor: Theme.of(context).colorScheme.primaryContainer,
                  leading: const Icon(Icons.cloud_outlined),
                  title: Text(
                    destination.isEmpty
                        ? 'Cloud root'
                        : destination.join('  /  '),
                  ),
                  subtitle: const Text('Your chosen location'),
                ),
                if (download)
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: Text('Into $source'),
                    subtitle: const Text('Selected cloud contents'),
                  )
                else
                  for (final root in roots)
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(root),
                      subtitle: Text('/${[...destination, root].join('/')}'),
                    ),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    rules.excluded.isEmpty
                        ? 'Existing subfolders are preserved.'
                        : '${rules.excluded.length} excluded folder selections are skipped.',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SyncFolderRulesScreen extends StatefulWidget {
  const SyncFolderRulesScreen({
    super.key,
    required this.inclusion,
    required this.rootName,
    required this.initial,
    required this.included,
    required this.children,
  });
  final bool inclusion;
  final String rootName;
  final List<List<String>> initial, included;
  final Future<List<String>> Function(List<String>) children;
  @override
  State<SyncFolderRulesScreen> createState() => _SyncFolderRulesScreenState();
}

class _SyncFolderRulesScreenState extends State<SyncFolderRulesScreen> {
  late List<List<String>> selected;
  List<String> path = [];
  List<String> folders = [];
  bool loading = true;
  Object? error;
  String search = '';
  @override
  void initState() {
    super.initState();
    selected = [...widget.initial];
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
      folders = [];
    });
    try {
      final values = await widget.children(path);
      for (final value in values) {
        checkSyncPath([value]);
      }
      if (mounted) setState(() => folders = values);
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _toggle(List<String> folder) {
    setState(() {
      if (selected.any(
        (p) => p.length == folder.length && syncPathContains(p, folder),
      )) {
        selected.removeWhere(
          (p) => p.length == folder.length && syncPathContains(p, folder),
        );
      } else {
        selected.removeWhere(
          (p) => syncPathContains(folder, p) || syncPathContains(p, folder),
        );
        selected.add(List.of(folder));
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: path.isEmpty,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !loading) {
        setState(() {
          path = path.take(path.length - 1).toList();
          search = '';
        });
        _load();
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.inclusion ? 'Included folders' : 'Excluded folders'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.inclusion
                      ? 'Choose folders to upload, including their subfolders.'
                      : 'Choose folders to skip. Existing backups stay untouched.',
                ),
                const SizedBox(height: 12),
                TextField(
                  key: ValueKey(path.join('/')),
                  decoration: const InputDecoration(
                    labelText: 'Search folders',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => search = v),
                ),
                const SizedBox(height: 8),
                Text([widget.rootName, ...path].join(' / ')),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final folder in selected)
                      InputChip(
                        label: Text(
                          folder.isEmpty ? 'Entire source' : folder.join('/'),
                        ),
                        onDeleted: () =>
                            setState(() => selected.remove(folder)),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    'Could not read folders (${error.runtimeType}). Check device access and retry.',
                  ),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            ),
          Expanded(
            child: ListView(
              children: [
                if (widget.inclusion && path.isEmpty)
                  CheckboxListTile(
                    title: const Text('Entire source'),
                    subtitle: const Text('Including future subfolders'),
                    value: selected.any((p) => p.isEmpty),
                    onChanged: loading ? null : (_) => _toggle([]),
                  ),
                for (final name in folders)
                  if (name.toLowerCase().contains(search.toLowerCase()) &&
                      (widget.inclusion ||
                          widget.included.any(
                            (p) =>
                                syncPathContains(p, [...path, name]) ||
                                syncPathContains([...path, name], p),
                          )))
                    ListTile(
                      leading: Checkbox(
                        value: selected.any(
                          (p) => syncPathContains(p, [...path, name]),
                        ),
                        onChanged:
                            loading ||
                                (!widget.inclusion &&
                                    selected.any(
                                      (p) =>
                                          p.length < path.length + 1 &&
                                          syncPathContains(p, [...path, name]),
                                    ))
                            ? null
                            : (_) => _toggle([...path, name]),
                      ),
                      title: Text(name),
                      subtitle: Text([...path, name].join(' / ')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: loading
                          ? null
                          : () {
                              setState(() {
                                path = [...path, name];
                                search = '';
                              });
                              _load();
                            },
                    ),
                if (!loading && error == null && folders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No subfolders here.'),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed:
                      loading ||
                          error != null ||
                          (widget.inclusion && selected.isEmpty)
                      ? null
                      : () => Navigator.pop(context, selected),
                  child: Text(
                    widget.inclusion ? 'Apply inclusions' : 'Apply exclusions',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
