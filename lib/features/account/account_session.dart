import 'dart:async';

import '../../app/status_sink.dart';
import '../../core/cloud/cloud_backend.dart';
import '../../diagnostics.dart';
import '../../models.dart';
import 'browser_login.dart';
import 'session_store.dart';

/// Signing in and restoring a saved account. It runs one sign-in at a time and
/// drops the result of one that was cancelled or replaced; what happens once an
/// account is accepted is up to the app, through [signedIn].
class AccountSession {
  AccountSession({
    required this.client,
    required this.store,
    required this.status,
    required this.disposed,
    required this.active,
    required this.signedIn,
    required this.onChanged,
  });

  final CloudBackend client;
  final SessionStore store;
  final StatusSink status;
  final bool Function() disposed;

  /// Whether the app is in the foreground. Browser approval pauses otherwise.
  final bool Function() active;

  /// Accepts a new account: saves it and prepares the library.
  final Future<void> Function(Account account) signedIn;
  final void Function() onChanged;

  /// True until the saved account has been looked for.
  bool starting = true;
  bool signingIn = false;

  /// True while an accepted account is being saved, which can no longer be
  /// cancelled.
  bool saving = false;

  int _version = 0;
  Completer<void>? _resume;

  bool get canCancel => signingIn && !saving;

  /// The saved account, or null when there is none, it could not be read, or
  /// a sign-in replaced the lookup ([current] is then false).
  Future<({Account? account, bool current})> restore() async {
    final version = _version;
    bool current() => !disposed() && version == _version;
    Account? restored;
    try {
      final saved = await store.read();
      if (!current()) return (account: null, current: false);
      if (saved != null) restored = client.restoreAccount(saved);
    } catch (e) {
      if (current()) {
        status.error =
            'Could not restore the saved account. ${errorMessage(e)}';
      }
    }
    return (account: restored, current: current());
  }

  Future<void> passwordLogin(
    String server,
    String user,
    String password,
  ) async {
    final version = ++_version;
    signingIn = true;
    status.error = null;
    onChanged();
    try {
      final result = await client.authenticate(
        normalizeServer(server),
        user,
        password,
      );
      if (version != _version) return;
      await _accept(result);
    } catch (e) {
      if (version == _version) status.error = errorMessage(e);
    } finally {
      if (version == _version) {
        signingIn = false;
        onChanged();
      }
    }
  }

  Future<void> browserLogin(
    String server,
    Future<bool> Function(Uri) openBrowser,
  ) async {
    final version = ++_version;
    signingIn = true;
    status.error = null;
    status.notice = null;
    onChanged();
    try {
      final flow = BrowserLogin(
        client: client,
        isCurrent: () => version == _version,
        isActive: active,
        waitForResume: (remaining) async {
          final resume = _resume ??= Completer<void>();
          await resume.future.timeout(remaining, onTimeout: () {});
        },
        onRetry: () {
          status.notice = 'Sign-in connection interrupted. Retrying…';
          onChanged();
        },
      );
      final result = await flow.authenticate(
        normalizeServer(server),
        openBrowser,
      );
      if (version == _version && result != null) {
        status.notice = null;
        await _accept(result);
      }
    } catch (e) {
      if (version == _version) status.error = errorMessage(e);
    } finally {
      if (version == _version) {
        signingIn = false;
        status.notice = null;
        onChanged();
      }
    }
  }

  Future<void> _accept(Account account) async {
    saving = true;
    onChanged();
    try {
      await signedIn(account);
    } finally {
      saving = false;
    }
  }

  /// Gives up the sign-in in progress, unless its account is already saving.
  void cancel() {
    if (saving) return;
    invalidate();
    signingIn = false;
    status.notice = null;
    onChanged();
  }

  /// Makes any sign-in or lookup in flight stale.
  void invalidate() {
    _version++;
    wake();
  }

  /// Resumes a browser approval that was waiting for the app to return.
  void wake() {
    final pending = _resume;
    _resume = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }
}
