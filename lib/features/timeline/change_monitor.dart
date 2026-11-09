import 'dart:async';

import '../../models.dart';
import '../../core/cloud/cloud_backend.dart';

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
  });

  final CloudBackend client;
  final Account account;
  final Future<bool> Function(Set<String>? ids, bool pushed) check;
  final void Function(bool active) onActive;
  final void Function(Object error) onError;
  final Duration idleAfter;
  final Duration minimumInterval;
  final Duration maximumInterval;
  Timer? _poll;
  Timer? _idle;
  Timer? _debounce;
  StreamSubscription<Set<String>?>? _subscription;
  bool _disposed = false;
  bool _foreground = true;
  bool _active = false;
  bool _checking = false;
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
    if (_subscription != null || !_active || _disposed) return;
    final generation = _generation;
    bool current() => !_disposed && _active && generation == _generation;
    try {
      _subscription = client
          .changes(account)
          .listen(
            (ids) {
              if (current()) _queue(ids);
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
    }
  }

  void _queue(Set<String>? ids) {
    if (ids == null || (_ids != null && {..._ids!, ...ids}.length > 500)) {
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
    final generation = _generation;
    _poll?.cancel();
    try {
      final changed = await check(pushed ? ids : null, pushed);
      if (_disposed || generation != _generation) return;
      _interval = changed
          ? minimumInterval
          : Duration(
              milliseconds: (_interval.inMilliseconds * 2).clamp(
                minimumInterval.inMilliseconds,
                maximumInterval.inMilliseconds,
              ),
            );
    } catch (e) {
      if (!_disposed && generation == _generation) {
        onError(e);
        _interval = maximumInterval;
      }
    } finally {
      _checking = false;
      if (!_disposed && _active) {
        if (generation != _generation) {
          unawaited(_check());
        } else {
          _poll = Timer(_interval, _check);
        }
      }
    }
  }

  void _closePush() {
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void dispose() {
    _disposed = true;
    _pause();
  }
}
