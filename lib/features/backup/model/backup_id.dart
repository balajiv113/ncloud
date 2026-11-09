import 'dart:math';

/// A random 128-bit identifier as 32 hex digits, for pairs and revisions.
String newBackupId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
