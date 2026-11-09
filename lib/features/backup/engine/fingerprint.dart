import 'dart:io';

import 'package:crypto/crypto.dart';

/// The SHA-1 of a file as lower-case hex, read in chunks so a large video never
/// has to fit in memory.
///
/// It is the file's identity: the same content has the same fingerprint
/// whatever it is called or wherever it is. The server stores it with the
/// upload and checks the upload against it.
Future<String> fingerprintOf(File file) async =>
    (await sha1.bind(file.openRead()).first).toString();
