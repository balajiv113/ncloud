import 'package:flutter/painting.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/platform/device_library.dart';
import 'package:ncloud/features/phone/phone_photo.dart';
import 'package:ncloud/features/phone/phone_source.dart';
import 'package:ncloud/features/phone/phone_thumbnails.dart';

class _Source implements PhoneSource {
  final asked = <String>[];
  Completer<Uint8List?>? hold;
  Object? failWith;

  @override
  Future<LibraryPermission> permission() async => LibraryPermission.granted;
  @override
  Future<LibraryPermission> request() async => LibraryPermission.granted;
  @override
  Future<List<PhonePhoto>> photos() async => const [];

  @override
  Future<Uint8List?> thumbnail(String id, int size) {
    asked.add('$id|$size');
    if (failWith != null) return Future.error(failWith!);
    return hold?.future ?? Future.value(Uint8List.fromList([size]));
  }

  @override
  Future<ImageProvider?> image(String id) async => null;
  @override
  Future<PhoneVideo> video(String id, {bool copy = false}) async =>
      throw UnimplementedError();
  @override
  Stream<void> get changes => const Stream.empty();
}

void main() {
  test('a photo asked for again is not made again', () async {
    final source = _Source();
    final thumbnails = PhoneThumbnails(source);
    expect(await thumbnails.of('a', 100), [100]);
    expect(await thumbnails.of('a', 100), [100]);
    expect(source.asked, ['a|100']);
  });

  test('the same photo at another size is a different picture', () async {
    final source = _Source();
    final thumbnails = PhoneThumbnails(source);
    await thumbnails.of('a', 100);
    await thumbnails.of('a', 200);
    expect(source.asked, ['a|100', 'a|200']);
  });

  test('two tiles asking at once share one request', () async {
    final source = _Source()..hold = Completer();
    final thumbnails = PhoneThumbnails(source);
    final first = thumbnails.of('a', 100);
    final second = thumbnails.of('a', 100);
    source.hold!.complete(Uint8List.fromList([7]));
    expect(await first, [7]);
    expect(await second, [7]);
    expect(source.asked, ['a|100']);
  });

  test('forgets the least recently used one once full', () async {
    final source = _Source();
    final thumbnails = PhoneThumbnails(source, capacity: 2);
    await thumbnails.of('a', 1);
    await thumbnails.of('b', 1);
    await thumbnails.of('a', 1); // a is now the most recent
    await thumbnails.of('c', 1); // pushes out b
    source.asked.clear();
    await thumbnails.of('a', 1);
    expect(source.asked, isEmpty);
    await thumbnails.of('b', 1);
    expect(source.asked, ['b|1']);
  });

  test('a failure is not kept, so the next look tries again', () async {
    final source = _Source()..failWith = StateError('phone busy');
    final thumbnails = PhoneThumbnails(source);
    await expectLater(thumbnails.of('a', 1), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    source.failWith = null;
    expect(await thumbnails.of('a', 1), [1]);
    expect(source.asked, ['a|1', 'a|1']);
  });

  test('clear forgets everything', () async {
    final source = _Source();
    final thumbnails = PhoneThumbnails(source);
    await thumbnails.of('a', 1);
    thumbnails.clear();
    await thumbnails.of('a', 1);
    expect(source.asked, ['a|1', 'a|1']);
  });
}
