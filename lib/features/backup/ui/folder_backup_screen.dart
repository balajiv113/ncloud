import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../state/backup_controller.dart';
import '../../../core/ui/messages.dart' show showError;
import '../engine/sync_errors.dart' show sourceNeedsReselect;
import 'backup_setup_screen.dart';
import 'backup_preview_sheet.dart';
import 'remove_from_phone_sheet.dart';
import 'backup_status.dart';
import 'failures_sheet.dart';

class FolderBackupScreen extends StatefulWidget {
  const FolderBackupScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<FolderBackupScreen> createState() => _FolderBackupScreenState();
}

class _FolderBackupScreenState extends State<FolderBackupScreen> {
  BackupController get sync => widget.controller.backup;
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

  /// The first backup shows what it is about to do and waits for a yes; later
  /// ones simply run.
  Future<void> _backUp(FolderPair pair, Map<String, dynamic>? state) {
    final neverRun = pair.lastRun == null && state?['status'] == null;
    return neverRun
        ? _preview(pair, start: true)
        : _perform(() => sync.run(pair));
  }

  /// Shows what a backup would do. With [start], saying yes runs it.
  Future<void> _preview(FolderPair pair, {required bool start}) async {
    final go = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) =>
          BackupPreviewSheet(sync: sync, pair: pair, canStart: start),
    );
    if (go == true) await _perform(() => sync.run(pair));
  }

  /// Clears one album from the phone once its files are confirmed on the
  /// server.
  Future<void> _removeFromPhone(FolderPair pair) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => RemoveFromPhoneSheet(sync: sync, pair: pair),
  );

  Future<void> _backUpAgain(FolderPair pair) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Back up again?'),
        content: const Text(
          'Every file in this folder is checked again. Files already on your '
          'server are recognised and not uploaded twice; files missing from it '
          'are uploaded. Use this if the server folder was emptied or restored.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Back up again'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _perform(() => sync.backUpAgain(pair));
  }

  Future<void> _perform(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      if (mounted) showError(context, e);
    }
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
              onPressed: _loading
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
    final failed = state?['status'] == 'error' || state?['status'] == 'partial';
    // A run in this app reports live numbers; one made by the background
    // worker is read from what it saved.
    final numbers = sync.activeId == pair.id
        ? BackupNumbers.fromProgress(sync.progress)
        : BackupNumbers.fromState(state);
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
                PopupMenuButton<String>(
                  tooltip: 'More for ${pair.name}',
                  enabled: !sync.busy && !active,
                  onSelected: (choice) => switch (choice) {
                    'preview' => _preview(pair, start: false),
                    'remove' => _removeFromPhone(pair),
                    _ => _backUpAgain(pair),
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'preview',
                      child: Text('Preview what will be backed up'),
                    ),
                    const PopupMenuItem(
                      value: 'again',
                      child: Text('Back up again'),
                    ),
                    if (sync.canRemoveFromPhone(pair))
                      const PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove from this phone…'),
                      ),
                  ],
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
                    '$scheduleLabel · ${pairStatus(sync, pair)}'
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
                      : sync.busy
                      ? null
                      : () => _backUp(pair, state),
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
            if (active) ..._progress(numbers),
            if (!active) ..._summary(pair, numbers),
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
            if (sourceNeedsReselect(state?['errorCode'] as String?))
              TextButton(
                onPressed: sync.busy ? null : () => _edit(pair),
                child: const Text('Reselect source'),
              ),
          ],
        ),
      ),
    );
  }

  /// The bar, the count and what is being uploaded, while a backup runs.
  List<Widget> _progress(BackupNumbers numbers) => [
    Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              [
                numbers.progressLine ?? sync.phase,
                ?numbers.percent,
              ].join(' · '),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          if (numbers.remaining case final left?)
            Text(
              formatRemaining(left),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    ),
    Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 6),
      child: LinearProgressIndicator(value: numbers.fraction),
    ),
    if (numbers.current case final name?)
      Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 4),
        child: Text(
          'Uploading $name',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    if (numbers.problems > 0)
      Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 4),
        child: Text(
          '${numbers.problemLine} so far',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ),
  ];

  /// How the last run ended: how much is backed up, and a way to see problems.
  List<Widget> _summary(FolderPair pair, BackupNumbers numbers) => [
    if (numbers.summaryLine case final line?)
      Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 2),
        child: Text(line, style: Theme.of(context).textTheme.bodySmall),
      ),
    if (numbers.problemLine case final line?)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 32),
          ),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            isScrollControlled: true,
            builder: (_) => FailuresSheet(sync: sync, pair: pair),
          ),
          icon: const Icon(Icons.error_outline, size: 16),
          label: Text('$line · see why'),
        ),
      ),
  ];
}
