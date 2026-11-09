import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../../../core/cloud/cloud_backend.dart';
import 'sync_errors.dart';

/// How a failure should be handled while a backup runs.
enum FailureKind {
  /// The whole run cannot continue and retrying now will not help: sign-in
  /// expired, the server is full, folder access was lost.
  fatal,

  /// Probably temporary: the connection dropped, the server is busy. Worth a
  /// retry after a pause.
  transient,

  /// This one file cannot be backed up right now. The rest carry on.
  item,
}

/// Decides how to treat [error]. A user's stop request is never an error and
/// must be handled before this is asked.
FailureKind classifyFailure(Object error) {
  if (error is CloudException) {
    final status = error.statusCode;
    if (status == 401 || status == 403 || status == 507) {
      return FailureKind.fatal;
    }
    if (error.retryable || status == 408 || status == 429) {
      return FailureKind.transient;
    }
    if (status != null && status >= 500) return FailureKind.transient;
    return FailureKind.item;
  }
  if (error is SocketException ||
      error is http.ClientException ||
      error is TimeoutException) {
    return FailureKind.transient;
  }
  if (error is PlatformException) {
    return switch (error.code) {
      'folder_permission' ||
      'photos_permission' ||
      'photos_album' ||
      'media_permission' ||
      'conditions_permission' ||
      'background_permission' ||
      'background_start' ||
      'scheduled_background' => FailureKind.fatal,
      _ => FailureKind.item,
    };
  }
  // The progress cannot be saved, so carrying on would lose track of uploads.
  if (error is MissingPluginException || error is DatabaseException) {
    return FailureKind.fatal;
  }
  return FailureKind.item;
}

/// A file that could not be backed up, in words for the user.
class FileFailure {
  const FileFailure({
    required this.path,
    required this.message,
    this.code,
    this.attempts = 1,
  });

  final List<String> path;
  final String message;
  final String? code;
  final int attempts;
}

/// Describes why one file failed, using the same wording as run-level errors.
FileFailure describeFileFailure(
  List<String> path,
  Object error, {
  int attempts = 1,
}) {
  final described = describeSyncError(error, phase: 'uploading');
  return FileFailure(
    path: path,
    message: described.message,
    code: described.code,
    attempts: attempts,
  );
}

/// How long to wait before attempt number [attempt] (0 is the first retry), or
/// null once the file has had its tries. Jitter keeps many workers from
/// retrying in step.
Duration? retryDelay(int attempt, {double jitter = 0.5}) {
  const delays = [
    Duration(seconds: 2),
    Duration(seconds: 8),
    Duration(seconds: 30),
  ];
  if (attempt < 0 || attempt >= delays.length) return null;
  final base = delays[attempt].inMilliseconds;
  return Duration(milliseconds: (base * (0.75 + jitter * 0.5)).round());
}

/// Stops a run that is failing for a reason that is not about one file, such as
/// a connection that is down or a provider that has stopped answering. It trips
/// after [limit] failures in a row, and any success starts the count again.
class FailureBreaker {
  FailureBreaker({this.limit = 10, this.connectionLimit = 2});

  /// Failures in a row, of any kind, that stop the run.
  final int limit;

  /// Files in a row that failed on the connection after all their retries. The
  /// connection is plainly down, so waiting for ten more is pointless.
  final int connectionLimit;

  int _inARow = 0;
  int _connection = 0;
  String? _last;
  bool _lostConnection = false;

  int get inARow => _inARow;

  void succeeded() => _inARow = _connection = 0;

  /// Records a failure. Returns true when the run should stop.
  bool failed(String message, {required bool connection}) {
    _last = message;
    _inARow++;
    _connection = connection ? _connection + 1 : 0;
    _lostConnection = connection && _connection >= connectionLimit;
    return _lostConnection || _inARow >= limit;
  }

  /// What to tell the user when the breaker tripped.
  String get message => _lostConnection
      ? 'The connection to your server was lost. Backup resumes by itself the '
            'next time it can connect.'
      : 'Backup stopped after $_inARow files in a row failed. '
            'Last problem: ${_last ?? 'unknown'}';
}
