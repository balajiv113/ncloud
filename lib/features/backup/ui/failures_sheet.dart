import 'package:flutter/material.dart';

import '../state/backup_controller.dart';
import 'backup_status.dart';

/// The files of one backup that could not be backed up, each with its reason,
/// and a button to try them all again.
class FailuresSheet extends StatefulWidget {
  const FailuresSheet({super.key, required this.sync, required this.pair});

  final BackupController sync;
  final FolderPair pair;

  @override
  State<FailuresSheet> createState() => _FailuresSheetState();
}

class _FailuresSheetState extends State<FailuresSheet> {
  late final Future<List<StoredFailure>> _failures = widget.sync.failures(
    widget.pair,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.75,
        ),
        child: FutureBuilder<List<StoredFailure>>(
          future: _failures,
          builder: (context, snapshot) {
            final failures = snapshot.data;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                  child: Text(
                    'Could not be backed up',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    failures == null
                        ? 'Loading…'
                        : failures.length >= 200
                        ? 'Showing the 200 most recent. The rest are tried again too.'
                        : 'Everything else in ${widget.pair.name} is backed up. '
                              'These are tried again each time.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (snapshot.hasError)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Could not read the list. Try again later.'),
                  ),
                if (failures != null)
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: failures.length,
                      itemBuilder: (context, index) {
                        final failure = failures[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.error_outline,
                            color: theme.colorScheme.error,
                            size: 20,
                          ),
                          title: Text(
                            failure.path.join('/'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            failure.attempts > 1
                                ? '${failure.message} '
                                      '(tried ${formatCount(failure.attempts)} times)'
                                : failure.message,
                          ),
                        );
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                  child: FilledButton.icon(
                    onPressed: widget.sync.busy || failures?.isEmpty != false
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            widget.sync.retryFailed(widget.pair);
                          },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
