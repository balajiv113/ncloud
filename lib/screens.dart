import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_controller.dart';
import 'models.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final theme = Theme.of(context);
    return Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(alignment: Alignment.centerLeft, child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(26)),
            child: Icon(Icons.all_inclusive_rounded, size: 44, color: theme.colorScheme.primary),
          )),
          const SizedBox(height: 36),
          Text('Life, collected.', style: theme.textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.w800, letterSpacing: -2.5)),
          const SizedBox(height: 16),
          Text('Every moment. Every file.\nA beautiful home for your Nextcloud.',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w400)),
          const SizedBox(height: 36),
          if (c.error case final error?) ...[
            MessageCard(message: error, isError: true), const SizedBox(height: 16),
          ],
          TextField(controller: _server, enabled: !c.signingIn,
            keyboardType: TextInputType.url, autocorrect: false,
            decoration: const InputDecoration(labelText: 'Nextcloud server',
              hintText: 'https://cloud.example.com', prefixIcon: Icon(Icons.lock_outline))),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: c.signingIn ? null : () => c.browserLogin(_server.text,
              (uri) => launchUrl(uri, mode: LaunchMode.externalApplication)),
            icon: const Icon(Icons.arrow_forward_rounded),
            label: const Padding(padding: EdgeInsets.all(14), child: Text('Connect Nextcloud'))),
          if (c.signingIn) ...[
            const SizedBox(height: 16), const LinearProgressIndicator(),
            const SizedBox(height: 12),
            const Text('Approve access in your browser, then return here.'),
            TextButton(onPressed: c.canCancelLogin ? c.cancelLogin : null, child: const Text('Cancel sign-in')),
          ] else ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: c.enterDemo,
              child: const Padding(padding: EdgeInsets.all(12), child: Text('Try demo'))),
          ],
          const SizedBox(height: 16),
          ExpansionTile(title: const Text('Use an app password instead'), tilePadding: EdgeInsets.zero,
            children: [
              const Text('Create an app password in Nextcloud → Personal settings → Security. Never use your main password.'),
              const SizedBox(height: 12),
              TextField(controller: _user, enabled: !c.signingIn, autocorrect: false,
                decoration: const InputDecoration(labelText: 'Username or login email')),
              const SizedBox(height: 12),
              TextField(controller: _password, enabled: !c.signingIn, obscureText: true,
                autocorrect: false, enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'App password')),
              TextButton(onPressed: c.signingIn ? null : () => c.passwordLogin(
                _server.text, _user.text, _password.text), child: const Text('Sign in with app password')),
            ]),
          const SizedBox(height: 24),
          Text('YOUR SERVER. YOUR MEMORIES. YOUR RULES.',
            textAlign: TextAlign.center, style: theme.textTheme.labelSmall),
        ]),
      ),
    ))));
  }
}

class NameDialog extends StatefulWidget {
  const NameDialog({super.key, this.title = 'New folder', this.initial = ''});
  final String title;
  final String initial;
  @override
  State<NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<NameDialog> {
  late final _name = TextEditingController(text: widget.initial);
  final _form = GlobalKey<FormState>();
  @override
  void dispose() { _name.dispose(); super.dispose(); }
  void _submit() {
    if (_form.currentState!.validate()) Navigator.pop(context, _name.text.trim());
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(key: _form, child: TextFormField(
      controller: _name, autofocus: true, decoration: const InputDecoration(labelText: 'Name'),
      onFieldSubmitted: (_) => _submit(),
      validator: (value) {
        try { validateName(value?.trim() ?? ''); return null; }
        on FormatException catch (e) { return e.message; }
      })),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _submit, child: const Text('Save')),
    ]);
}

Future<void> shareFile(BuildContext context, AppController controller, CloudFile file) async {
  try {
    final output = await controller.download(file);
    if (!context.mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(files: [XFile(output.path)],
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

void showError(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMessage(error))));

class MessageCard extends StatelessWidget {
  const MessageCard({super.key, required this.message, this.isError = false, this.onRetry});
  final String message;
  final bool isError;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: isError ? Theme.of(context).colorScheme.errorContainer : Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(16)),
    child: Row(children: [
      Icon(isError ? Icons.error_outline : Icons.info_outline), const SizedBox(width: 12),
      Expanded(child: Text(message)),
      if (onRetry != null) IconButton(tooltip: 'Retry', onPressed: onRetry, icon: const Icon(Icons.refresh)),
    ]));
}
