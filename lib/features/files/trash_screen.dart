import 'package:flutter/material.dart';
import '../../app/app_controller.dart';
import '../../diagnostics.dart';
import '../../models.dart';
import '../../core/ui/messages.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  late Future<List<TrashEntry>> _items = widget.controller.trash();
  bool _busy = false;
  void _reload() => setState(() => _items = widget.controller.trash());
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Recently deleted'),
      actions: [
        IconButton(
          tooltip: 'Refresh trash',
          onPressed: _busy ? null : _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'Recovery follows your server’s retention and naming rules. If the original folder is gone, items may restore to your root folder.',
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        Expanded(
          child: FutureBuilder<List<TrashEntry>>(
            future: _items,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: MessageCard(
                    message: errorMessage(snapshot.error!),
                    isError: true,
                    onRetry: _reload,
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.data!.isEmpty) {
                return const Center(
                  child: Text('A clean slate. Nothing in trash.'),
                );
              }
              return ListView(
                children: [
                  for (final entry in snapshot.data!)
                    ListTile(
                      leading: const Icon(Icons.restore_from_trash_outlined),
                      title: Text(entry.name),
                      subtitle: Text(entry.originalPath),
                      trailing: TextButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                setState(() => _busy = true);
                                try {
                                  await widget.controller.restore(entry);
                                  _reload();
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                } finally {
                                  if (mounted) setState(() => _busy = false);
                                }
                              },
                        child: const Text('Restore'),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
