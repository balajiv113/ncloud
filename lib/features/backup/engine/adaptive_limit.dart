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
/// Places that are taken for a while and given back.
abstract interface class Places {
  Future<void> acquire();
  void release();
}

/// Room for the temporary copies of files in hand.
abstract interface class Reservation {
  Future<void> acquire(int bytes);
  void release(int bytes);
}

class AdaptiveLimit implements Places {
  AdaptiveLimit({this.start = 3, int? max, DateTime Function()? clock})
    : max = _clampMax(max ?? deviceMax, start),
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
  final DateTime Function() _clock;

  int _limit;
  int _struggles = 0;
  int _active = 0;
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

  /// Waits until another upload may start, then counts it as running.
  @override
  Future<void> acquire() async {
    while (_active >= _limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _active++;
    if (_active < _limit) _full = false;
  }

  /// Gives back the place of an upload that finished or failed.
  @override
  void release() {
    _active--;
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
    // Never below two (or the start, if that is lower): one slow upload would
    // otherwise take the only place and keep every other file waiting.
    _limit = math.max(math.min(2, start), _limit ~/ 2);
    _struggles++;
    // Each time it happens the wait is longer, so a server that cannot take
    // the load stops being tried.
    _holdUntil = now.add(_calmAfterFailure * _struggles * _struggles);
    _windowStart = null;
    _windowBytes = 0;
    _reference = 0;
  }
}

/// A fixed number of places, taken in turn.
class Gate implements Places {
  Gate(this.size);

  final int size;
  int _used = 0;
  final List<Completer<void>> _waiting = [];

  @override
  Future<void> acquire() async {
    while (_used >= size) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _used++;
  }

  @override
  void release() {
    _used--;
    if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
  }
}

/// How much of the phone's storage the staged copies may take. A file starts
/// copying while the total is under the budget, so one very large video can go
/// over it but never holds up the files behind it for long.
class ByteBudget implements Reservation {
  ByteBudget(this.size);

  final int size;
  int _used = 0;
  final List<Completer<void>> _waiting = [];

  @override
  Future<void> acquire(int bytes) async {
    while (_used >= size) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _used += bytes;
  }

  @override
  void release(int bytes) {
    _used -= bytes;
    final turns = List.of(_waiting);
    _waiting.clear();
    for (final turn in turns) {
      turn.complete();
    }
  }
}

/// Room for a number of copies, whatever their size.
class HeldCount implements Reservation {
  HeldCount(int size) : _gate = Gate(size);

  final Gate _gate;

  @override
  Future<void> acquire(int bytes) => _gate.acquire();

  @override
  void release(int bytes) => _gate.release();
}
