import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// The SHA-1 of a file as lower-case hex, read in chunks so a large video never
/// has to fit in memory.
///
/// It is the file's identity: the same content has the same fingerprint
/// whatever it is called or wherever it is. The server stores it with the
/// upload and checks the upload against it.
///
/// It is worked out on another isolate, so hashing a large video does not stall
/// the screen and several files can be hashed on different cores at once.
Future<String> fingerprintOf(File file) {
  final path = file.path;
  return Isolate.run(
    () async => (await sha1.bind(File(path).openRead()).first).toString(),
  );
}

/// The same fingerprint of bytes that are being read, such as a file on the
/// server.
Future<String> fingerprintOfStream(Stream<List<int>> bytes) async =>
    (await sha1.bind(bytes).first).toString();
