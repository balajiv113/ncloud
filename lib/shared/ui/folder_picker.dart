import 'package:flutter/material.dart';

import '../../core/ui/messages.dart';
import '../../diagnostics.dart';
import '../../models.dart';

Future<List<String>?> chooseFolder(
  BuildContext context, {
  required Future<List<CloudFile>> Function(List<String> path) loadFolders,
  required List<CloudFile> sources,
}) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => FolderPicker(loadFolders: loadFolders, sources: sources),
);

class FolderPicker extends StatefulWidget {
  const FolderPicker({
    super.key,
    required this.loadFolders,
    required this.sources,
  });
  final Future<List<CloudFile>> Function(List<String> path) loadFolders;
  final List<CloudFile> sources;

  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<FolderPicker> {
  List<String> _path = [];
  late Future<List<CloudFile>> _folders = widget.loadFolders(_path);

  void _open(List<String> value) => setState(() {
    _path = value;
    _folders = widget.loadFolders(_path);
  });

  bool _blocked(List<String> path) =>
      widget.sources.any((f) => f.isDirectory && pathStartsWith(path, f.path));

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: Column(
        children: [
          ListTile(
            title: const Text('Choose destination'),
            subtitle: Text(_path.isEmpty ? 'All files' : '/${_path.join('/')}'),
            leading: IconButton(
              tooltip: 'Parent folder',
              onPressed: _path.isEmpty
                  ? null
                  : () => _open(_path.sublist(0, _path.length - 1)),
              icon: const Icon(Icons.arrow_back),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<CloudFile>>(
              future: _folders,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: MessageCard(
                      message: errorMessage(snapshot.error!),
                      isError: true,
                      onRetry: () => _open(_path),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final folders = snapshot.data!
                    .where((f) => f.isDirectory)
                    .toList();
                return folders.isEmpty
                    ? const Center(
                        child: Text('No subfolders. You can use this folder.'),
                      )
                    : ListView(
                        children: [
                          for (final folder in folders)
                            ListTile(
                              enabled: !_blocked(folder.path),
                              leading: const Icon(Icons.folder_outlined),
                              title: Text(folder.name),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(folder.path),
                            ),
                        ],
                      );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _blocked(_path)
                  ? null
                  : () => Navigator.pop(context, _path),
              icon: const Icon(Icons.check),
              label: const Text('Use this folder'),
            ),
          ),
        ],
      ),
    ),
  );
}
