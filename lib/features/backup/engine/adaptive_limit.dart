import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// How many uploads run at once, found by trying.
///
/// It starts at [start] and adds one at a time up to [max], keeping a step only
/// when the upload rate rose clearly. When the link is already full, more
/// uploads add nothing, so it goes back and waits a while before trying again.
/// A transient failure, which is often the server or the connection being
/// overloaded, halves the number.
///
/// It also keeps the staged copies of the files in flight under a budget, so a
/// few very large videos cannot fill the phone.
class AdaptiveLimit {
  AdaptiveLimit({
    this.start = 3,
    int? max,
    this.byteBudget = 1024 * 1024 * 1024,
    DateTime Function()? clock,
  }) : max = _clampMax(max ?? deviceMax, start),
       _clock = clock ?? DateTime.now,
       _limit = start;

  /// What this device allows: one upload per processor, never fewer than
  /// [start] and never more than eight.
  static int get deviceMax => Platform.numberOfProcessors;

  static int _clampMax(int value, int start) =>
      math.min(8, math.max(value, start));

  static const _window = Duration(seconds: 20);
  static const _gain = 1.08;
  static const _drop = 0.7;
  static const _retryAfter = Duration(minutes: 2);
  static const _calmAfterFailure = Duration(minutes: 5);

  final int start;
  final int max;
  final int byteBudget;
  final DateTime Function() _clock;

  int _limit;
  int _active = 0;
  int _activeBytes = 0;
  final List<Completer<void>> _waiting = [];

  DateTime? _windowStart;
  int _windowBytes = 0;
  bool _full = true;

  /// Set while a step up is on trial: the number to go back to and the rate it
  /// has to beat.
  int? _trialFrom;
  double _reference = 0;
  DateTime _holdUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// How many uploads may run now.
  int get limit => _limit;

  /// How many are running now.
  int get active => _active;

  /// Waits until another file of [bytes] may start, then counts it as running.
  /// One file always runs, however large.
  Future<void> acquire(int bytes) async {
    while (!_fits(bytes)) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _active++;
    _activeBytes += bytes;
    if (_active < _limit) _full = false;
  }

  bool _fits(int bytes) =>
      _active == 0 || (_active < _limit && _activeBytes + bytes <= byteBudget);

  /// Gives back the place of a file of [bytes] that finished or failed.
  void release(int bytes) {
    _active--;
    _activeBytes -= bytes;
    _wake();
  }

  void _wake() {
    final turns = List.of(_waiting);
    _waiting.clear();
    for (final turn in turns) {
      turn.complete();
    }
  }

  /// Notes [bytes] that reached the server, and tunes the number of uploads
  /// once a window of time has passed.
  void sent(int bytes) {
    final now = _clock();
    final began = _windowStart ??= now;
    _windowBytes += bytes;
    if (_active < _limit) _full = false;
    final elapsed = now.difference(began);
    if (elapsed < _window) return;
    final rate = _windowBytes / (elapsed.inMilliseconds / 1000);
    final measured = _full;
    _windowStart = now;
    _windowBytes = 0;
    _full = true;
    // A window that was not using every place says nothing about more of them.
    if (!measured) return;
    _tune(rate, now);
  }

  void _tune(double rate, DateTime now) {
    final from = _trialFrom;
    if (from != null) {
      _trialFrom = null;
      if (rate < _reference * _gain) {
        _limit = from;
        _holdUntil = now.add(_retryAfter);
      } else {
        _reference = rate;
      }
      _wake();
      return;
    }
    if (_reference > 0 && rate < _reference * _drop && _limit > 1) {
      _limit--;
      _reference = rate;
      _holdUntil = now.add(_retryAfter);
      return;
    }
    _reference = rate;
    if (_limit < max && !now.isBefore(_holdUntil)) {
      _trialFrom = _limit;
      _limit++;
      _wake();
    }
  }

  /// A transient failure: the server or the connection is struggling.
  void struggled() {
    final now = _clock();
    _trialFrom = null;
    _limit = math.max(1, _limit ~/ 2);
    _holdUntil = now.add(_calmAfterFailure);
    _windowStart = null;
    _windowBytes = 0;
    _reference = 0;
  }
}
