import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/app_controller.dart';
import '../state/backup_controller.dart';
import '../../../core/ui/messages.dart' show showError;
import '../engine/sync_errors.dart' show sourceNeedsReselect;
import 'backup_setup_screen.dart';
import 'backup_status.dart';

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
}
