import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../state/backup_controller.dart';
import '../../../core/ui/messages.dart' show showError;
import '../../../shared/ui/folder_picker.dart' show chooseFolder;
import '../model/sync_rules.dart';
import '../model/backup_schedule.dart';
import '../platform/device_library.dart';

class BackupSetupScreen extends StatefulWidget {
  const BackupSetupScreen({super.key, required this.controller, this.pair});
  final AppController controller;
  final FolderPair? pair;

  @override
  State<BackupSetupScreen> createState() => _BackupSetupScreenState();
}

class _BackupSetupScreenState extends State<BackupSetupScreen> {
  BackupController get sync => widget.controller.backup;
  late final TextEditingController _include;
  late final TextEditingController _exclude;
  DeviceFolder? _source;

  /// How much of the photo library may be read, when the source is the library.
  LibraryPermission? _libraryPermission;
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
    } else if (await sync.libraryPermission() != null) {
      if (!mounted) return;
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('All photos & videos'),
                subtitle: const Text(
                  'Everything in your phone\'s gallery, by its own folders',
                ),
                onTap: () => Navigator.pop(context, 'library'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('A folder'),
                subtitle: const Text('Any folder, such as Documents'),
                onTap: () => Navigator.pop(context, 'folder'),
              ),
            ],
          ),
        ),
      );
      if (choice == 'library') {
        selected = await sync.chooseLibrary();
      } else if (choice == 'folder') {
        selected = await sync.access.pick();
      }
    } else {
      selected = await sync.access.pick();
    }
    if (mounted && selected != null) {
      final permission = selected.kind == DeviceSourceKind.library
          ? await sync.libraryPermission()
          : null;
      if (mounted) {
        setState(() {
          _source = selected;
          _libraryPermission = permission;
        });
      }
    }
  });

  /// What the source is called: the library is not just "Phone".
  static String _sourceLabel(DeviceFolder source) =>
      source.kind == DeviceSourceKind.library
      ? 'All photos & videos'
      : source.name;

  Future<void> _save() => _perform(() async {
    final rules = SyncRules.patterns(_include.text, _exclude.text);
    final schedule = _daily
        ? BackupSchedule.forTime(
            _time.hour,
            _time.minute,
            previous: _pair?.schedule,
          )
        : null;
    await sync.add(
      _sourceLabel(_source!),
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
          title: Text(sync.ios ? 'Photos album' : 'What to back up'),
          subtitle: Text(
            _source == null ? 'Choose source' : _sourceLabel(_source!),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _pick,
        ),
        if (_libraryPermission == LibraryPermission.partial)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Only some of your photos are visible to ncloud. Allow all '
              'photos and videos in your phone\'s settings to back up '
              'everything.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.tertiary,
              ),
            ),
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
                    loadFolders: widget.controller.folderContents,
                    sources: const [],
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
