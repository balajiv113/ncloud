import 'dart:async';

import '../../core/cloud/cloud_backend.dart';
import '../../models.dart';

/// Coordinates a browser authorization flow without owning UI or storage.
class BrowserLogin {
  BrowserLogin({
    required this.client,
    required this.isCurrent,
    required this.isActive,
    required this.waitForResume,
    required this.onRetry,
    this.timeout = const Duration(minutes: 20),
    this.pollInterval = const Duration(seconds: 2),
  });

  final CloudBackend client;
  final bool Function() isCurrent;
  final bool Function() isActive;
  final Future<void> Function(Duration remaining) waitForResume;
  final void Function() onRetry;
  final Duration timeout;
  final Duration pollInterval;

  Future<Account?> authenticate(
    Uri server,
    Future<bool> Function(Uri) openBrowser,
  ) async {
    final flow = await client.startLogin(server);
    if (!isCurrent()) return null;
    if (!await openBrowser(flow.login)) {
      throw const CloudException(
        'Could not open your browser. Try an app password instead.',
      );
    }
    if (!isCurrent()) return null;
    final deadline = DateTime.now().add(timeout);
    var failures = 0;
    while (isCurrent() && DateTime.now().isBefore(deadline)) {
      if (!isActive()) {
        await waitForResume(deadline.difference(DateTime.now()));
        if (!isCurrent()) return null;
        if (!DateTime.now().isBefore(deadline)) break;
      }
      Account? result;
      try {
        result = await client.pollLogin(server, flow);
        failures = 0;
      } on CloudException catch (error) {
        if (!isCurrent()) return null;
        if (!isActive() && error.retryable) continue;
        if (!error.retryable || ++failures >= 5) rethrow;
        onRetry();
      }
      if (!isCurrent()) return null;
      if (result != null) return result;
      await Future<void>.delayed(pollInterval);
    }
    if (isCurrent()) {
      throw const CloudException(
        'Sign-in timed out. Start again to get a new login link.',
      );
    }
    return null;
  }
}
