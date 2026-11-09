import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/phone_removal.dart';
import '../engine/sync_errors.dart';
import '../state/backup_controller.dart';
import 'backup_status.dart';

/// Clears one album or folder from the phone, after checking each file against
/// the server. The user picks the album, sees what is safe to remove and what
/// stays, confirms, and the phone asks again before anything goes.
class RemoveFromPhoneSheet extends StatefulWidget {
  const RemoveFromPhoneSheet({
    super.key,
    required this.sync,
    required this.pair,
  });

  final BackupController sync;
  final FolderPair pair;

  @override
  State<RemoveFromPhoneSheet> createState() => _RemoveFromPhoneSheetState();
}

class _RemoveFromPhoneSheetState extends State<RemoveFromPhoneSheet> {
  List<RemovalTarget>? _targets;
  String? _targetsError;
  RemovalPlan? _plan;
  String? _planError;
  RemovalTarget? _target;
  bool _removing = false;
  bool _stop = false;
  int _done = 0;
  int _total = 0;
  RemovalResult? _result;
  String? _error;

  static String _message(Object error) => error is PlatformException
      ? (error.message ?? error.code)
      : describeSyncError(error, phase: 'removing').message;

  @override
  void initState() {
    super.initState();
    _loadTargets();
  }

  Future<void> _loadTargets() async {
    try {
      final targets = await widget.sync.removalTargetsOf(widget.pair);
      if (mounted) setState(() => _targets = targets);
    } catch (e) {
      if (mounted) setState(() => _targetsError = _message(e));
    }
  }

  Future<void> _choose(RemovalTarget target) async {
    setState(() {
      _target = target;
      _plan = null;
      _planError = null;
    });
    try {
      final plan = await widget.sync.planRemovalOf(widget.pair, target);
      if (mounted && _target == target) setState(() => _plan = plan);
    } catch (e) {
      if (mounted && _target == target) {
        setState(() => _planError = _message(e));
      }
    }
  }

  Future<void> _remove(RemovalPlan plan) async {
    final photos = plan.removable.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Move $photos ${photos == 1 ? 'file' : 'files'} to the trash?',
        ),
        content: Text(
          'All ${formatCount(photos)} are on your server (${formatSize(plan.bytes)}). '
          'They go to your phone\'s trash, where they stay for 30 days, and '
          'your phone asks you to confirm.'
          '${widget.sync.ios ? ' A photo in other albums is removed from them too.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _removing = true;
      _stop = false;
      _done = 0;
      _total = photos;
      _error = null;
    });
    try {
      final result = await widget.sync.removeFromPhoneWith(
        widget.pair,
        plan,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
        shouldStop: () => _stop,
      );
      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Remove from this phone',
                style: theme.textTheme.titleLarge,
              ),
            ),
            Flexible(child: _body(theme)),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: SizedBox(
                width: double.infinity,
                child: _removing
                    ? OutlinedButton(
                        onPressed: _stop
                            ? null
                            : () => setState(() => _stop = true),
                        child: Text(
                          _stop ? 'Stopping after this batch…' : 'Stop',
                        ),
                      )
                    : OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
      );
    }
    if (_result case final result?) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Text(
          result.removed == 0
              ? (result.reason ?? 'Nothing was removed.')
              : 'Moved ${formatCount(result.removed)} '
                    '${result.removed == 1 ? 'file' : 'files'} '
                    '(${formatSize(result.bytes)}) to your phone\'s trash. '
                    'They stay there for 30 days.'
                    '${result.stopped && result.reason != null ? '\n\n${result.reason}' : ''}',
        ),
      );
    }
    if (_removing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
            const SizedBox(height: 8),
            Text('${formatCount(_done)} of ${formatCount(_total)} removed'),
            const SizedBox(height: 4),
            Text(
              'Your phone asks you to confirm each batch.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }
    if (_target == null) return _chooser(theme);
    if (_planError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Text(
          _planError!,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    final plan = _plan;
    if (plan == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Checking ${_target!.name} against your server…'),
            ),
          ],
        ),
      );
    }
    return _summary(theme, plan);
  }

  Widget _chooser(ThemeData theme) {
    if (_targetsError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Text(
          _targetsError!,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    final targets = _targets;
    if (targets == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Looking at what is on your phone…'),
          ],
        ),
      );
    }
    if (targets.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Text('There is nothing here to remove.'),
      );
    }
    return ListView(
      shrinkWrap: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            'Choose an album. Only files already on your server, unchanged, '
            'are offered; the rest stay.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final target in targets)
          ListTile(
            title: Text(target.name),
            subtitle: Text(
              '${formatCount(target.files)} '
              '${target.files == 1 ? 'file' : 'files'}'
              '${target.bytes > 0 ? ' · ${formatSize(target.bytes)}' : ''}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _choose(target),
          ),
      ],
    );
  }

  Widget _summary(ThemeData theme, RemovalPlan plan) {
    final lines = <String>[
      if (plan.keptFor(KeepReason.notBackedUp) > 0)
        '${formatCount(plan.keptFor(KeepReason.notBackedUp))} not backed up '
            'yet, or changed since',
      if (plan.keptFor(KeepReason.notOnServer) > 0)
        '${formatCount(plan.keptFor(KeepReason.notOnServer))} no longer on '
            'your server, or changed there',
      if (plan.keptFor(KeepReason.partOfUnverified) > 0)
        '${formatCount(plan.keptFor(KeepReason.partOfUnverified))} part of a '
            'photo that could not be fully verified',
    ];
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        Text(plan.target.name, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        if (plan.isEmpty)
          const Text('Nothing here can be removed yet.')
        else
          Text(
            '${formatCount(plan.removable.length)} '
            '${plan.removable.length == 1 ? 'file' : 'files'}'
            '${plan.bytes > 0 ? ', ${formatSize(plan.bytes)},' : ''} are safely '
            'on your server and can be removed.',
            style: theme.textTheme.titleSmall,
          ),
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('These stay on your phone:', style: theme.textTheme.bodySmall),
          for (final line in lines) Text('• $line'),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: plan.isEmpty ? null : () => _remove(plan),
          child: Text(
            plan.isEmpty
                ? 'Nothing to remove'
                : 'Move ${formatCount(plan.removable.length)} to the trash',
          ),
        ),
        TextButton(
          onPressed: () => setState(() {
            _plan = null;
            _planError = null;
            _target = null;
          }),
          child: const Text('Choose another album'),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
