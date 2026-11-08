import 'dart:async';
import 'dart:typed_data';

import '../../../core/cloud/cloud_backend.dart';
import '../../../models.dart';

class PreviewCancelled implements Exception {
  const PreviewCancelled();
}

class PreviewBatcher {
  PreviewBatcher({
    required this.client,
    required this.session,
    required this.active,
    required this.interested,
  });

  final CloudBackend client;
  final Account? Function() session;
  final bool Function() active;
  final bool Function(String key) interested;
  final Map<String, _Request> _queue = {};
  Account? _queueAccount;
  Timer? _timer;
  int _running = 0;
  int _generation = 0;
  int _failures = 0;
  bool _batchUnavailable = false;
  bool _disposed = false;

  Future<Uint8List> fetch(
    Account account,
    CloudFile file,
    int size,
    String loadKey, {
    required bool batch,
  }) {
    if (_disposed || !active()) {
      return Future.error(const PreviewCancelled());
    }
    if (!batch || file.id == null || _batchUnavailable || size > 512) {
      return _single(account, file, size);
    }
    if (_queueAccount != null && !identical(_queueAccount, account)) {
      pause();
    }
    _queueAccount = account;
    final key = '${file.id}|$size';
    final request =
        _queue.remove(key) ?? _Request(file, size, loadKey, Completer());
    _queue[key] = request;
    _timer ??= Timer(const Duration(milliseconds: 12), () => _flush(account));
    return request.completer.future;
  }

  void pause() {
    _timer?.cancel();
    _timer = null;
    for (final request in _queue.values) {
      request.completer.completeError(const PreviewCancelled());
    }
    _queue.clear();
    _queueAccount = null;
  }

  void clear() {
    _generation++;
    pause();
    _batchUnavailable = false;
    _failures = 0;
  }

  void dispose() {
    _disposed = true;
    clear();
  }

  Future<Uint8List> _single(Account account, CloudFile file, int size) async {
    final previews = await client.previews(account, [file], size: size);
    if (previews.length != 1) {
      throw const CloudException('Invalid preview response.');
    }
    return previews.single ??
        (throw const CloudException('No preview is available for this file.'));
  }

  void _flush(Account account) {
    _timer = null;
    if (_disposed || !identical(session(), account) || !active()) {
      pause();
      return;
    }
    while (_queue.isNotEmpty && _running < 3) {
      final batch = <_Request>[];
      for (final key in _queue.keys.toList().reversed) {
        final request = _queue[key]!;
        if (batch.isNotEmpty && request.size != batch.first.size) continue;
        _queue.remove(key);
        if (!interested(request.loadKey)) {
          request.completer.completeError(const PreviewCancelled());
          continue;
        }
        batch.add(request);
        if (batch.length == 48) break;
      }
      if (batch.isEmpty) continue;
      _running++;
      unawaited(_send(account, batch));
    }
    if (_queue.isEmpty) _queueAccount = null;
  }

  Future<void> _send(Account account, List<_Request> batch) async {
    final generation = _generation;
    bool current() =>
        !_disposed &&
        identical(session(), account) &&
        generation == _generation;
    void single(_Request request) {
      if (!active() || !current()) {
        request.completer.completeError(const PreviewCancelled());
      } else {
        request.completer.complete(
          _single(account, request.file, request.size),
        );
      }
    }

    try {
      if (batch.length == 1) {
        single(batch.single);
        return;
      }
      final previews = await client.previews(account, [
        for (final request in batch) request.file,
      ], size: batch.first.size);
      if (previews.length != batch.length) {
        throw const CloudException('Invalid preview response.');
      }
      if (!current()) {
        for (final request in batch) {
          request.completer.completeError(const PreviewCancelled());
        }
        return;
      }
      _failures = 0;
      for (var i = 0; i < batch.length; i++) {
        final bytes = previews[i];
        if (bytes != null) {
          batch[i].completer.complete(bytes);
        } else {
          single(batch[i]);
        }
      }
    } on Object {
      if (current() && ++_failures >= 2) _batchUnavailable = true;
      for (final request in batch) {
        if (!request.completer.isCompleted) single(request);
      }
    } finally {
      _running--;
      final nextSession = session();
      if (!_disposed && active() && nextSession != null && _queue.isNotEmpty) {
        _timer ??= Timer(Duration.zero, () => _flush(nextSession));
      }
    }
  }
}

class _Request {
  _Request(this.file, this.size, this.loadKey, this.completer);
  final CloudFile file;
  final int size;
  final String loadKey;
  final Completer<Uint8List> completer;
}
