import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ui/messages.dart';
import '../../models.dart';
import 'share_session.dart';

/// The people and groups a file is shared with, and a search to add more.
class PeopleShares extends StatefulWidget {
  const PeopleShares({
    super.key,
    required this.session,
    required this.shares,
    required this.busy,
    required this.run,
    required this.update,
  });

  final ShareSession session;

  /// Every share of the file; this section shows the people and groups.
  final List<FileShare> shares;
  final bool busy;

  /// Runs a server action with the panel's busy and error handling.
  final Future<void> Function(Future<void> Function() action) run;

  /// Changes the shared list and rebuilds the panel.
  final void Function(VoidCallback change) update;

  @override
  State<PeopleShares> createState() => _PeopleSharesState();
}

class _PeopleSharesState extends State<PeopleShares> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<Sharee> _found = [];
  bool _searching = false;
  int _request = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    final query = text.trim();
    if (query.length < 2) {
      _request++;
      setState(() {
        _found = [];
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _lookUp(query));
  }

  Future<void> _lookUp(String query) async {
    final request = ++_request;
    setState(() => _searching = true);
    try {
      final found = await widget.session.findPeople(query);
      if (!mounted || request != _request) return;
      final shared = {
        for (final share in widget.shares)
          if (share.kind != ShareKind.link)
            '${share.kind.name}|${share.recipient}',
      };
      setState(
        () => _found = [
          for (final sharee in found)
            if (!shared.contains('${sharee.kind.name}|${sharee.id}')) sharee,
        ],
      );
    } catch (e) {
      if (mounted && request == _request) showError(context, e);
    } finally {
      if (mounted && request == _request) setState(() => _searching = false);
    }
  }

  Future<void> _add(Sharee sharee) => widget.run(() async {
    final share = await widget.session.addPerson(sharee);
    widget.update(() => widget.shares.add(share));
    if (mounted) {
      _search.clear();
      setState(() => _found = []);
    }
  });

  Future<void> _setEditable(FileShare share, bool canEdit) =>
      widget.run(() async {
        final updated = await widget.session.setEditable(share, canEdit);
        widget.update(() {
          final index = widget.shares.indexWhere((s) => s.id == share.id);
          if (index >= 0) widget.shares[index] = updated;
        });
      });

  Future<void> _remove(FileShare share) => widget.run(() async {
    await widget.session.revoke(share);
    widget.update(() => widget.shares.removeWhere((s) => s.id == share.id));
  });

  IconData _icon(ShareKind kind) =>
      kind == ShareKind.group ? Icons.group_outlined : Icons.person_outline;

  @override
  Widget build(BuildContext context) {
    final people = [
      for (final share in widget.shares)
        if (share.kind != ShareKind.link) share,
    ];
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('People', style: textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Share with people or groups on this server. They see it in their own Nextcloud.',
          style: textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _search,
          enabled: !widget.busy,
          onChanged: _changed,
          decoration: InputDecoration(
            labelText: 'Add people or groups',
            prefixIcon: const Icon(Icons.person_add_alt),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
        ),
        for (final sharee in _found)
          ListTile(
            dense: true,
            leading: Icon(_icon(sharee.kind)),
            title: Text(sharee.name),
            subtitle: sharee.kind == ShareKind.group
                ? const Text('Group')
                : sharee.name == sharee.id
                ? null
                : Text(sharee.id),
            onTap: widget.busy ? null : () => _add(sharee),
          ),
        if (_found.isEmpty && !_searching && _search.text.trim().length >= 2)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No matching people or groups.'),
          ),
        for (final share in people)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_icon(share.kind)),
            title: Text(share.recipientName ?? share.recipient ?? 'Unknown'),
            subtitle: share.kind == ShareKind.group
                ? const Text('Group')
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButton<bool>(
                  value: share.canEdit,
                  underline: const SizedBox.shrink(),
                  onChanged: widget.busy
                      ? null
                      : (value) {
                          if (value != null && value != share.canEdit) {
                            _setEditable(share, value);
                          }
                        },
                  items: const [
                    DropdownMenuItem(value: false, child: Text('Can view')),
                    DropdownMenuItem(value: true, child: Text('Can edit')),
                  ],
                ),
                IconButton(
                  tooltip:
                      'Stop sharing with ${share.recipientName ?? share.recipient}',
                  onPressed: widget.busy ? null : () => _remove(share),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
