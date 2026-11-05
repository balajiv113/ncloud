import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';

import 'cloud_backend.dart';

enum FailureCategory {
  authentication,
  permission,
  network,
  storage,
  invalidData,
  server,
  device,
  unexpected,
}

class DiagnosticEvent {
  const DiagnosticEvent(this.time, this.category, this.statusCode);

  final DateTime time;
  final FailureCategory category;
  final int? statusCode;
}

/// Session-only support information. Never stores exception text or user data.
class Diagnostics {
  static final session = Diagnostics();
  static const capacity = 40;
  final Queue<DiagnosticEvent> _events = Queue();

  List<DiagnosticEvent> get events => List.unmodifiable(_events);

  void record(Object error) {
    final status = error is CloudException ? error.statusCode : null;
    final category = switch (error) {
      CloudException() when status == 401 => FailureCategory.authentication,
      CloudException() when status == 403 => FailureCategory.permission,
      CloudException() when status == 507 => FailureCategory.storage,
      SocketException() || TimeoutException() => FailureCategory.network,
      FileSystemException() => FailureCategory.storage,
      FormatException() => FailureCategory.invalidData,
      PlatformException() => FailureCategory.device,
      CloudException() when status == null && error.retryable =>
        FailureCategory.network,
      CloudException() => FailureCategory.server,
      _ => FailureCategory.unexpected,
    };
    _events.add(
      DiagnosticEvent(
        DateTime.now().toUtc(),
        category,
        status != null && status >= 100 && status <= 599 ? status : null,
      ),
    );
    while (_events.length > capacity) {
      _events.removeFirst();
    }
  }

  void clear() => _events.clear();

  String report() => [
    'ncloud support diagnostics (current session)',
    'No account details, paths, URLs, credentials or exception messages.',
    'Events: ${_events.length}',
    for (final event in _events)
      '${event.time.toIso8601String()} ${event.category.name}'
          '${event.statusCode == null ? '' : ' HTTP ${event.statusCode}'}',
  ].join('\n');
}
