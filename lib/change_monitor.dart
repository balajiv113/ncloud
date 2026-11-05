import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'nextcloud_client.dart';

/// Foreground-only change hints. No timers or socket survive inactivity.
class ChangeMonitor {
  ChangeMonitor({
    required this.client,
    required this.account,
    required this.check,
    required this.onActive,
    required this.onError,
    this.idleAfter = const Duration(minutes: 2),
    this.minimumInterval = const Duration(minutes: 1),
    this.maximumInterval = const Duration(minutes: 5),
    Future<WebSocket> Function(Uri)? connect,
  }) : _connect = connect ?? ((uri) => WebSocket.connect(uri.toString()));

  final NextcloudClient client;
  final Account account;
  final Future<bool> Function(Set<String>? ids, bool pushed) check;
  final void Function(bool active) onActive;
  final void Function(Object error) onError;
  final Duration idleAfter;
  final Duration minimumInterval;
  final Duration maximumInterval;
  final Future<WebSocket> Function(Uri) _connect;
  Timer? _poll;
  Timer? _idle;
  Timer? _debounce;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;
  bool _foreground = true;
  bool _active = false;
  bool _checking = false;
  bool _opening = false;
  bool _discovered = false;
  bool _authenticated = false;
  Uri? _endpoint;
  int _generation = 0;
  DateTime? _lastActivity;
  late Duration _interval = minimumInterval;
  Set<String>? _ids = {};

  void activity() {
    if (_disposed || !_foreground) return;
    final now = DateTime.now();
    if (_active &&
        _lastActivity != null &&
        now.difference(_lastActivity!) < const Duration(seconds: 10)) {
      return;
    }
    _lastActivity = now;
    _idle?.cancel();
    _idle = Timer(idleAfter, _pause);
    if (_active) return;
    _active = true;
    onActive(true);
    unawaited(_openPush());
    unawaited(_check());
  }

  void setForeground(bool foreground) {
    if (_disposed) return;
    _foreground = foreground;
    if (foreground) {
      activity();
    } else {
      _pause();
    }
  }

  void _pause() {
    _generation++;
    _active = false;
    _poll?.cancel();
    _idle?.cancel();
    _debounce?.cancel();
    _poll = _idle = _debounce = null;
    _ids = {};
    _closePush();
    onActive(false);
  }

  Future<void> _openPush() async {
    if (_opening || _socket != null || !_active || _disposed) return;
    _opening = true;
    final generation = _generation;
    bool current() => !_disposed && _active && generation == _generation;
    try {
      if (!_discovered) {
        final endpoint = await client.pushEndpoint(account);
        if (!current()) return;
        _endpoint = endpoint;
        _discovered = true;
      }
      final endpoint = _endpoint;
      if (endpoint == null || !current()) return;
      final opening = _connect(endpoint);
      late WebSocket socket;
      try {
        socket = await opening.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        unawaited(
          opening.then<void>(
            (lateSocket) async {
              await lateSocket.close();
            },
            onError: (Object error, StackTrace _) {
              if (current()) onError(error);
            },
          ),
        );
        rethrow;
      }
      if (!current()) {
        await socket.close();
        return;
      }
      _socket = socket;
      _authenticated = false;
      socket
        ..add(account.loginName)
        ..add(account.appPassword);
      _subscription = socket.listen(
        (dynamic event) {
          if (!current() || event is! String) return;
          if (event == 'authenticated') {
            _authenticated = true;
            socket.add('listen notify_file_id');
          } else if (event.startsWith('err:')) {
            onError(
              const CloudException(
                'Client Push authentication failed. Reconnect in Settings if change checks also fail.',
              ),
            );
            _closePush();
          } else if (event == 'notify_file' && _authenticated) {
            _queue(null);
          } else if (event.startsWith('notify_file_id ') && _authenticated) {
            try {
              final values = jsonDecode(
                event.substring('notify_file_id '.length),
              );
              if (values is! List ||
                  values.any(
                    (id) =>
                        (id is! int && id is! String) ||
                        !RegExp(r'^\d+$').hasMatch(id.toString()),
                  )) {
                throw const FormatException('Invalid push file IDs.');
              }
              _queue(
                values.length > 500
                    ? null
                    : values.map((id) => id.toString()).toSet(),
              );
            } catch (e) {
              onError(e);
              _queue(null);
            }
          }
        },
        onError: (Object error) {
          if (current()) {
            onError(error);
            _closePush();
          }
        },
        onDone: () {
          if (current()) _closePush();
        },
      );
    } catch (e) {
      if (current()) onError(e);
    } finally {
      _opening = false;
      if (!_disposed && _active && generation != _generation) {
        unawaited(_openPush());
      }
    }
  }

  void _queue(Set<String>? ids) {
    if (ids == null || (_ids?.length ?? 0) > 500) {
      _ids = null;
    } else {
      _ids?.addAll(ids);
    }
    // A fixed window coalesces bursts without starving a busy upload stream.
    _debounce ??= Timer(const Duration(seconds: 2), () {
      _debounce = null;
      final ids = _ids;
      _ids = {};
      unawaited(_check(ids: ids, pushed: true));
    });
  }

  Future<void> _check({Set<String>? ids, bool pushed = false}) async {
    if (_disposed || !_active) return;
    if (_checking) {
      if (pushed) _queue(ids);
      return;
    }
    _checking = true;
    _poll?.cancel();
    try {
      final changed = await check(pushed ? ids : null, pushed);
      _interval = changed
          ? minimumInterval
          : Duration(
              milliseconds: (_interval.inMilliseconds * 2).clamp(
                minimumInterval.inMilliseconds,
                maximumInterval.inMilliseconds,
              ),
            );
    } catch (e) {
      onError(e);
      _interval = maximumInterval;
    } finally {
      _checking = false;
      if (!_disposed && _active) {
        _poll = Timer(_interval, _check);
      }
    }
  }

  void _closePush() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_socket?.close());
    _socket = null;
    _authenticated = false;
  }

  void dispose() {
    _disposed = true;
    _pause();
  }
}
