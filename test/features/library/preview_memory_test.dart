import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/library/preview_memory.dart';

void main() {
  test('eviction honors recency and counts replacement bytes', () {
    final memory = PreviewMemory(byteBudget: 5, entryLimit: 3);
    memory.put('a', Uint8List(2), 'a1');
    memory.put('b', Uint8List(2), 'b1');
    memory.get('a');
    memory.put('c', Uint8List(2), 'c1');
    expect(memory.peek('b'), isNull);
    expect(memory.peek('a'), isNotNull);
    memory.put('a', Uint8List(4), 'a2');
    expect(memory.peek('a')!.version, 'a2');
    expect(memory.peek('c'), isNull);
    memory.remove('a');
    memory.put('large', Uint8List(6), 'large');
    expect(memory.peek('large'), isNotNull);
    memory.clear();
    expect(memory.peek('large'), isNull);
  });

  test('entry bound applies across file and person previews', () {
    final memory = PreviewMemory(byteBudget: 100, entryLimit: 2);
    memory.put('file', Uint8List(1), '1');
    memory.put('face', Uint8List(1), '1');
    memory.put('other', Uint8List(1), '1');
    expect(memory.peek('file'), isNull);
    expect(memory.peek('face'), isNotNull);
    expect(memory.peek('other'), isNotNull);
  });
}
