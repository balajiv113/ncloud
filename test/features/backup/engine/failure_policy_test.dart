import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/features/backup/engine/failure_policy.dart';
import 'package:ncloud/features/backup/engine/sync_progress.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseException;

void main() {
  group('classifyFailure', () {
    FailureKind kind(Object e) => classifyFailure(e);

    test('sign-in, permission and a full server end the run', () {
      for (final status in [401, 403, 507]) {
        expect(
          kind(CloudException('x', statusCode: status)),
          FailureKind.fatal,
        );
      }
    });

    test('a busy or briefly unavailable server is worth a retry', () {
      for (final status in [408, 429, 500, 502, 503, 504]) {
        expect(
          kind(CloudException('x', statusCode: status)),
          FailureKind.transient,
        );
      }
      expect(
        kind(const CloudException('x', retryable: true)),
        FailureKind.transient,
      );
    });

    test('network trouble is temporary', () {
      expect(kind(const SocketException('x')), FailureKind.transient);
      expect(kind(http.ClientException('x')), FailureKind.transient);
      expect(kind(TimeoutException('x')), FailureKind.transient);
    });

    test('a problem with one file does not end the run', () {
      expect(
        kind(const CloudException('x', statusCode: 413)),
        FailureKind.item,
      );
      expect(
        kind(const CloudException('x', statusCode: 423)),
        FailureKind.item,
      );
      expect(kind(const CloudException('x')), FailureKind.item);
      expect(kind(const FormatException('x')), FailureKind.item);
      expect(kind(StateError('x')), FailureKind.item);
      expect(kind(PlatformException(code: 'folder_io')), FailureKind.item);
    });

    test(
      'lost folder access, a missing service and a broken journal end the run',
      () {
        for (final code in [
          'folder_permission',
          'photos_permission',
          'photos_album',
        ]) {
          expect(kind(PlatformException(code: code)), FailureKind.fatal);
        }
        expect(kind(MissingPluginException('x')), FailureKind.fatal);
        expect(kind(_DiskFull()), FailureKind.fatal);
      },
    );
  });

  group('retryDelay', () {
    test('grows, then gives up after three retries', () {
      final delays = [for (var i = 0; i < 3; i++) retryDelay(i)!];
      expect(delays[0], lessThan(delays[1]));
      expect(delays[1], lessThan(delays[2]));
      expect(retryDelay(3), isNull);
      expect(retryDelay(-1), isNull);
    });

    test('is spread a little so workers do not retry in step', () {
      expect(retryDelay(0, jitter: 0)!, lessThan(retryDelay(0, jitter: 1)!));
    });
  });

  group('FailureBreaker', () {
    test('trips after ten failures in a row and any success starts over', () {
      final breaker = FailureBreaker();
      for (var i = 0; i < 9; i++) {
        expect(breaker.failed('bad', connection: false), isFalse);
      }
      breaker.succeeded();
      for (var i = 0; i < 9; i++) {
        expect(breaker.failed('bad', connection: false), isFalse);
      }
      expect(breaker.failed('worst', connection: false), isTrue);
      expect(
        breaker.message,
        allOf(contains('10 files in a row'), contains('worst')),
      );
    });

    test('trips quickly when the connection itself is down', () {
      final breaker = FailureBreaker();
      expect(breaker.failed('timeout', connection: true), isFalse);
      expect(breaker.failed('timeout', connection: true), isTrue);
      expect(breaker.message, contains('connection to your server was lost'));
    });

    test(
      'a file that fails for another reason breaks a run of connection failures',
      () {
        final breaker = FailureBreaker();
        breaker.failed('timeout', connection: true);
        breaker.failed('unreadable', connection: false);
        expect(breaker.failed('timeout', connection: true), isFalse);
      },
    );
  });

  group('SyncProgress', () {
    test('reports how far along a run is, by size and by count', () {
      final p = SyncProgress()
        ..toUpload = 4
        ..bytesTotal = 1000;
      expect(p.fraction, 0);
      p.begin(DateTime(2025));
      p.uploaded(100, DateTime(2025));
      // One of four files but a tenth of the bytes: it reports between them.
      expect(p.fraction, closeTo((0.25 + 0.1) / 2, 0.001));
      expect(p.remaining, 3);
    });

    test('is unknown until the amount of work is known', () {
      expect(SyncProgress().fraction, isNull);
    });

    test('counts files found on the server and failures as finished', () {
      final p = SyncProgress()..toUpload = 4;
      p.wasOnServer(10);
      p.failed = 1;
      expect(p.settled, 2);
      expect(p.remaining, 2);
    });

    test('estimates the time left from recent speed', () {
      final p = SyncProgress()
        ..toUpload = 10
        ..bytesTotal = 10000;
      final start = DateTime(2025);
      p.begin(start);
      expect(p.estimatedRemaining, isNull);
      p.uploaded(1000, start.add(const Duration(seconds: 10)));
      // 100 bytes a second, 9000 left.
      expect(p.estimatedRemaining, const Duration(seconds: 90));
    });

    test('never reports negative work left and resets cleanly', () {
      final p = SyncProgress()..toUpload = 1;
      p.uploaded(5, DateTime(2025));
      p.uploaded(5, DateTime(2025));
      expect(p.remaining, 0);
      p.reset();
      expect(p.toJson().values.whereType<int>().every((v) => v == 0), isTrue);
    });
  });
}

class _DiskFull extends DatabaseException {
  _DiskFull() : super('disk full');

  @override
  int getResultCode() => 13;

  @override
  Object? get result => null;
}
