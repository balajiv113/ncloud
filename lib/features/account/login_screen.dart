import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_controller.dart';
import '../../core/ui/messages.dart';

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
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Icon(
                        Icons.all_inclusive_rounded,
                        size: 44,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 36),
                  Text(
                    'Life, collected.',
                    style: theme.textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -2.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Every moment. Every file.\nA beautiful home for your cloud.',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 36),
                  if (c.error case final error?) ...[
                    MessageCard(message: error, isError: true),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: _server,
                    enabled: !c.signingIn,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Server address',
                      hintText: 'https://cloud.example.com',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: c.signingIn
                        ? null
                        : () => c.browserLogin(
                            _server.text,
                            (uri) => launchUrl(
                              uri,
                              mode: LaunchMode.externalApplication,
                            ),
                          ),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Text('Connect server'),
                    ),
                  ),
                  if (c.signingIn) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 12),
                    const Text(
                      'Approve access in your browser, then return here.',
                    ),
                    if (c.notice case final notice?) ...[
                      const SizedBox(height: 8),
                      MessageCard(message: notice),
                    ],
                    TextButton(
                      onPressed: c.canCancelLogin ? c.cancelLogin : null,
                      child: const Text('Cancel sign-in'),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: c.enterDemo,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('Try demo'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  ExpansionTile(
                    title: const Text('Use an app password instead'),
                    tilePadding: EdgeInsets.zero,
                    children: [
                      const Text(
                        'Create an app password in your server’s security settings. Never use your main password.',
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _user,
                        enabled: !c.signingIn,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Username or login email',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        enabled: !c.signingIn,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'App password',
                        ),
                      ),
                      TextButton(
                        onPressed: c.signingIn
                            ? null
                            : () => c.passwordLogin(
                                _server.text,
                                _user.text,
                                _password.text,
                              ),
                        child: const Text('Sign in with app password'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'YOUR SERVER. YOUR MEMORIES. YOUR RULES.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
