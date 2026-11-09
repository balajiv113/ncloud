import 'package:flutter/material.dart';

import '../engine/backup_preview.dart';
import '../engine/sync_errors.dart';
import '../state/backup_controller.dart';
import 'backup_status.dart';

/// A sheet that shows what a backup would do, worked out without doing any of
/// it, and lets the user start it. It closes with true when they do.
class BackupPreviewSheet extends StatefulWidget {
  const BackupPreviewSheet({
    super.key,
    required this.sync,
    required this.pair,
    this.canStart = true,
  });

  final BackupController sync;
  final FolderPair pair;

  /// False when the sheet is only for looking, such as from the menu.
  final bool canStart;

  @override
  State<BackupPreviewSheet> createState() => _BackupPreviewSheetState();
}

class _BackupPreviewSheetState extends State<BackupPreviewSheet> {
  late final Future<BackupPreview> _preview = widget.sync.preview(widget.pair);

  /// About how long the upload would take on a 20 megabit connection.
  static String _estimate(int bytes) {
    final seconds = bytes / (20 * 1000 * 1000 / 8);
    return formatRemaining(
      Duration(seconds: seconds.round()),
    ).replaceAll(' left', '');
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: FutureBuilder<BackupPreview>(
        future: _preview,
        builder: (context, snapshot) {
          final theme = Theme.of(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'Back up ${widget.pair.name}',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              if (snapshot.hasError)
                _Message(
                  describeSyncError(snapshot.error!, phase: 'reading').message,
                  error: true,
                )
              else if (!snapshot.hasData)
                const Padding(
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
                )
              else
                Flexible(
                  child: _Body(preview: snapshot.data!, pair: widget.pair),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(widget.canStart ? 'Not now' : 'Close'),
                      ),
                    ),
                    if (widget.canStart) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: snapshot.hasData && !snapshot.data!.isEmpty
                              ? () => Navigator.of(context).pop(true)
                              : null,
                          child: Text(
                            snapshot.hasData && snapshot.data!.isEmpty
                                ? 'Nothing to back up'
                                : 'Start backup',
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
    child: Text(
      text,
      style: TextStyle(
        color: error ? Theme.of(context).colorScheme.error : null,
      ),
    ),
  );
}

class _Body extends StatelessWidget {
  const _Body({required this.preview, required this.pair});

  final BackupPreview preview;
  final FolderPair pair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dates = MaterialLocalizations.of(context);
    final p = preview;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        if (p.isEmpty) ...[
          Text(
            p.found == 0
                ? 'There is nothing to back up yet.'
                : 'Everything is already backed up.',
            style: theme.textTheme.headlineSmall,
          ),
          if (p.found > 0)
            Text(
              '${formatCount(p.alreadyBackedUp)} files, all on your server.',
            ),
        ] else ...[
          Text(
            '${formatCount(p.toUpload)} ${p.toUpload == 1 ? 'file' : 'files'}'
            ' · ${formatSize(p.bytes)}',
            style: theme.textTheme.headlineSmall,
          ),
          Text(
            'will be uploaded. On a 20 Mbps connection that is about '
            '${_BackupPreviewSheetState._estimate(p.bytes)}.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        _Line(
          Icons.cloud_done_outlined,
          '${formatCount(p.alreadyBackedUp)} already backed up',
          show: p.alreadyBackedUp > 0 && !p.isEmpty,
        ),
        _Line(
          Icons.error_outline,
          '${formatCount(p.blocked)} ${p.blocked == 1 ? 'file keeps' : 'files keep'} '
          'failing and will be left alone until you try again',
          show: p.blocked > 0,
        ),
        _Line(
          Icons.folder_outlined,
          p.destinationExists == false
              ? '/${pair.cloudRoot.join('/')} will be created on your server'
              : 'Goes to /${pair.cloudRoot.join('/')} on your server',
          show: !p.isEmpty,
        ),
        if (p.oldest != null && p.newest != null && !p.isEmpty)
          _Line(
            Icons.date_range_outlined,
            'Files from ${dates.formatMonthYear(p.oldest!)} to '
            '${dates.formatMonthYear(p.newest!)}',
          ),
        if (p.folders.length > 1) ...[
          const SizedBox(height: 12),
          Text('Biggest folders', style: theme.textTheme.titleSmall),
          for (final folder in p.folders.take(8))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                folder.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                '${formatCount(folder.files)} · ${formatSize(folder.bytes)}',
              ),
            ),
          if (p.folders.length > 8)
            Text(
              '…and ${p.folders.length - 8} more folders',
              style: theme.textTheme.bodySmall,
            ),
        ],
        if (!p.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Photos that turn out to be on your server already are recognised '
            'while uploading and are not uploaded twice. Nothing is deleted, '
            'on your phone or on your server.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.text, {this.show = true});

  final IconData icon;
  final String text;
  final bool show;

  @override
  Widget build(BuildContext context) => show
      ? Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(text)),
            ],
          ),
        )
      : const SizedBox.shrink();
}
