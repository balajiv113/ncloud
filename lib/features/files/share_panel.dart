import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../app/app_controller.dart';
import '../../core/cloud/cloud_backend.dart';
import '../../diagnostics.dart';
import '../../models.dart';
import '../../core/ui/messages.dart';
import 'share_session.dart';

class SharePanel extends StatefulWidget {
  const SharePanel({super.key, required this.controller, required this.file});
  final AppController controller;
  final CloudFile file;
  @override
  State<SharePanel> createState() => _SharePanelState();
}

class _SharePanelState extends State<SharePanel> {
  final _password = TextEditingController();
  DateTime? _expires;
  List<PublicShare> _links = [];
  bool _busy = false;
  String? _error;
  ShareSession? _session;

  @override
  void initState() {
    super.initState();
    try {
      _session = widget.controller.shareSession(widget.file);
    } catch (e) {
      _error = errorMessage(e);
      return;
    }
    _load();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() => _run(() async {
    final links = await _shareSession.list();
    if (mounted) setState(() => _links = links);
  });

  ShareSession get _shareSession =>
      _session ??
      (throw const CloudException('Sign in to manage share links.'));

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Share a little of your world',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(widget.file.name, maxLines: 2),
          const SizedBox(height: 16),
          const Text(
            'Anyone with a public link can view and download. Links are read-only; server policies may require a password or expiry.',
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            MessageCard(
              message: _error!,
              isError: true,
              onRetry: _busy ? null : _load,
            ),
          for (final link in _links)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      link.url.toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${link.passwordProtected ? 'Password protected' : 'No password'}${link.expiration == null ? '' : ' · ${link.expiration}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Wrap(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy'),
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: link.url.toString()),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Link copied')),
                              );
                            }
                          },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.ios_share, size: 18),
                          label: const Text('Share'),
                          onPressed: () async {
                            try {
                              final box =
                                  context.findRenderObject() as RenderBox?;
                              await SharePlus.instance.share(
                                ShareParams(
                                  uri: link.url,
                                  sharePositionOrigin: box == null
                                      ? null
                                      : box.localToGlobal(Offset.zero) &
                                            box.size,
                                ),
                              );
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          },
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await _shareSession.revoke(link);
                                  if (mounted) {
                                    setState(
                                      () => _links.removeWhere(
                                        (s) => s.id == link.id,
                                      ),
                                    );
                                  }
                                }),
                          child: const Text('Revoke'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Link password (optional)',
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final now = DateTime.now();
                    final date = await showDatePicker(
                      context: context,
                      firstDate: now.add(const Duration(days: 1)),
                      lastDate: now.add(const Duration(days: 365 * 5)),
                      initialDate: _expires ?? now.add(const Duration(days: 7)),
                    );
                    if (mounted && date != null) {
                      setState(() => _expires = date);
                    }
                  },
            icon: const Icon(Icons.schedule),
            label: Text(
              _expires == null
                  ? 'Set expiry date'
                  : 'Expires ${MaterialLocalizations.of(context).formatMediumDate(_expires!)}',
            ),
          ),
          if (_expires != null)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _expires = null),
              child: const Text('Remove expiry'),
            ),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final result = await _shareSession.create(
                      password: _password.text,
                      expires: _expires,
                    );
                    if (mounted) {
                      setState(() {
                        _links.add(result);
                        _password.clear();
                      });
                    }
                  }),
            icon: const Icon(Icons.add_link),
            label: const Text('Create read-only link'),
          ),
        ],
      ),
    ),
  );
}
