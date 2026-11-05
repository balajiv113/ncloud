import 'package:flutter/services.dart';

abstract interface class SyncBackground {
  Future<bool> permission({bool request = false});
  Future<void> start(void Function(String? reason) onPause);
  Future<void> stop();
}

class NativeSyncBackground implements SyncBackground {
  static const channel = MethodChannel('app.ncloud/sync_background');

  static Future<void> openSettings() => channel.invokeMethod<void>('settings');

  @override
  Future<bool> permission({bool request = false}) async =>
      await channel.invokeMethod<bool>('permission', {'request': request}) ==
      true;

  @override
  Future<void> start(void Function(String? reason) onPause) async {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'pause') throw MissingPluginException(call.method);
      onPause(call.arguments as String?);
    });
    try {
      await channel.invokeMethod<void>('start');
    } on Object {
      channel.setMethodCallHandler(null);
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await channel.invokeMethod<void>('stop');
    } finally {
      channel.setMethodCallHandler(null);
    }
  }
}
