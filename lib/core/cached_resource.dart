import 'dart:async';

import 'storage/local_cache.dart';
import '../diagnostics.dart';
import '../models.dart';

/// A collection that is shown from the device first and revalidated from the
/// provider: restored from disk once, reused while fresh, refreshed on demand
/// and discarded if the account or the load generation changed meanwhile.
class CachedResource<T> {
  CachedResource({
    required this.empty,
    required this.freshFor,
    required this.account,
    required this.disposed,
    required this.cache,
    required this.key,
    required this.fetch,
    required this.encode,
    required this.decode,
    required this.onChanged,
    this.onRestored,
    this.replace,
    this.onDamaged,
  }) : value = empty;

  final T empty;
  final Duration freshFor;
  final Account? Function() account;
  final bool Function() disposed;
  final LocalCache? cache;
  final String Function(Account account) key;

  /// Loads the collection; null means the provider does not support it.
  /// [current] turns false once the result would be discarded.
  final Future<T?> Function(Account account, bool Function() current) fetch;
  final Map<String, dynamic> Function(T value, DateTime updated) encode;

  /// Reads a stored document, throwing [FormatException] if it is damaged.
  /// A non-null `updated` lets the stored copy count as fresh.
  final ({T value, DateTime? updated}) Function(Map<String, dynamic> document)
  decode;
  final void Function() onChanged;
  final void Function(T value)? onRestored;

  /// Runs before a fetched value replaces the current one.
  final Future<void> Function(T old, T next)? replace;
  final void Function()? onDamaged;

  T value;
  bool loading = false;
  String? error;

  /// Null until the first server answer; false when unsupported.
  bool? available;
  DateTime? updated;
  Future<void>? _task;
  int _generation = 0;

  bool get _fresh =>
      updated != null && DateTime.now().difference(updated!) < freshFor;

  Future<void> load({bool refresh = false}) async {
    final session = account();
    if (session == null || disposed()) return;
    if (!refresh) {
      if (_task case final pending?) return pending;
      if (_fresh) return;
    }
    final generation = ++_generation;
    bool current() =>
        !disposed() &&
        generation == _generation &&
        (account()?.sameOwner(session) ?? false);
    loading = true;
    error = null;
    onChanged();
    final task = () async {
      try {
        if (updated == null) {
          final saved = await cache?.readDocument(key(session));
          if (!current()) return;
          if (saved != null) {
            try {
              final restored = decode(saved);
              value = restored.value;
              updated = restored.updated;
            } on FormatException {
              onDamaged?.call();
            }
            onRestored?.call(value);
            onChanged();
          }
        }
        if (!refresh && _fresh) return;
        final result = await fetch(session, current);
        if (!current()) return;
        final next = result ?? empty;
        if (replace != null) {
          await replace!(value, next);
          if (!current()) return;
        }
        available = result != null;
        value = next;
        updated = DateTime.now();
        onChanged();
        await cache?.writeDocument(key(session), encode(value, updated!));
      } catch (e) {
        if (current()) error = errorMessage(e);
      } finally {
        if (current()) {
          loading = false;
          onChanged();
        }
      }
    }();
    _task = task;
    try {
      await task;
    } finally {
      if (identical(_task, task)) _task = null;
    }
  }

  /// Keeps the value visible but stale: the next load fetches again and
  /// anything in flight is dropped.
  void invalidate() {
    _generation++;
    _task = null;
    loading = false;
    if (updated != null) updated = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Forgets everything, as after signing out.
  void reset() {
    _generation++;
    _task = null;
    value = empty;
    loading = false;
    error = null;
    available = null;
    updated = null;
  }
}
