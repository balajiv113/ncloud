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
      expect(p.fraction, closeTo(0.1, 0.001));
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

    test(
      'a file being copied moves the bar a little, then uploading the rest',
      () {
        final p = SyncProgress()
          ..toUpload = 2
          ..bytesTotal = 1000;
        expect(p.fraction, 0);
        final file = p.start('a.mp4', 500);
        // Waiting for a turn adds nothing yet.
        expect(p.fraction, 0);
        file.step = ActiveFile.copy;
        file.copied = 250;
        // Half copied is half of a fifth of half the bytes.
        expect(p.fraction, closeTo(0.05, 0.001));
        file.copied = 500;
        file.step = ActiveFile.upload;
        expect(p.fraction, closeTo(0.1, 0.001));
        file.sent = 250;
        expect(p.sending, 250);
        expect(p.fraction, closeTo(0.3, 0.001));
        file.sent = 0;
        p.uploaded(500, DateTime(2025));
        p.finish(file);
        expect(p.fraction, closeTo(0.5, 0.001));
      },
    );

    test('counts come from the files in hand and add up', () {
      final p = SyncProgress()..toUpload = 5;
      final a = p.start('a', 10)..step = ActiveFile.copy;
      p.start('w', 10);
      final b = p.start('b', 10)..step = ActiveFile.check;
      final c = p.start('c', 10)..step = ActiveFile.upload;
      p.start('d', 10).step = ActiveFile.upload;
      expect([p.waiting, p.copying, p.checking, p.uploading], [1, 1, 1, 2]);
      p.finish(c);
      expect([p.waiting, p.copying, p.checking, p.uploading], [1, 1, 1, 1]);
      p.finish(a);
      p.finish(b);
      expect(p.active, hasLength(2));
      p.reset();
      expect(
        [p.waiting, p.copying, p.checking, p.uploading, p.active.length],
        [0, 0, 0, 0, 0],
      );
    });

    test('without sizes the bar counts each file by its step', () {
      final p = SyncProgress()..toUpload = 4;
      p.start('a', -1).step = ActiveFile.upload;
      p.start('b', -1);
      p.transferred = 1;
      // One done, one past its copy (a fifth), one just started.
      expect(p.fraction, closeTo((1 + 0.2) / 4, 0.001));
    });

    test('the time left follows a file while it uploads', () {
      final p = SyncProgress()
        ..toUpload = 2
        ..bytesTotal = 10000;
      final start = DateTime(2025);
      p.begin(start);
      final file = p.start('a', 10000)..step = ActiveFile.upload;
      file.sent = 1000;
      p.moving(start.add(const Duration(seconds: 10)));
      // 100 bytes a second, 9000 left, before any file has finished.
      expect(p.uploadSpeed, closeTo(100, 1));
      expect(p.estimatedRemaining, const Duration(seconds: 90));
    });

    test('measures speed over the last minute, not from one file', () {
      final p = SyncProgress()
        ..toUpload = 100
        ..bytesTotal = 1000000;
      final start = DateTime(2025);
      p.begin(start);
      // A steady 1,000 bytes a second for two minutes...
      for (var s = 5; s <= 120; s += 5) {
        p.uploaded(5000, start.add(Duration(seconds: s)));
      }
      expect(p.uploadSpeed, closeTo(1000, 1));
      // ...then one huge file lands at once. It moves the figure, but the
      // minute behind it keeps it from jumping to what that one file implies.
      p.uploaded(60000, start.add(const Duration(seconds: 125)));
      expect(p.uploadSpeed!, lessThan(2100));
      expect(p.uploadSpeed!, greaterThan(1000));
    });

    test('speed forgets a stall once a minute has passed', () {
      final p = SyncProgress()
        ..toUpload = 10
        ..bytesTotal = 1000000;
      final start = DateTime(2025);
      p.begin(start);
      p.uploaded(100000, start.add(const Duration(seconds: 10)));
      expect(p.uploadSpeed, closeTo(10000, 1));
      // Nothing for a long while, then a small file: the old burst is gone.
      p.uploaded(1000, start.add(const Duration(seconds: 200)));
      expect(p.uploadSpeed!, lessThan(2000));
    });

    test('files already on the server do not count as network speed', () {
      final p = SyncProgress()
        ..toUpload = 10
        ..bytesTotal = 100000;
      final start = DateTime(2025);
      p.begin(start);
      p.wasOnServer(50000, start.add(const Duration(seconds: 10)));
      expect(p.uploadSpeed, 0);
      expect(p.estimatedRemaining, const Duration(seconds: 10));
      p.uploaded(10000, start.add(const Duration(seconds: 20)));
      expect(p.uploadSpeed, closeTo(500, 1));
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
