import 'package:flutter/services.dart';

abstract interface class SyncRunLock {
  Future<bool> acquire(String account);
  Future<void> release(String account);
}

/// Native FileChannel locks are shared by all engines and released on process
/// death, without expiring a lease while a slow upload still owns it.
class NativeSyncRunLock implements SyncRunLock {
  static const _channel = MethodChannel('app.ncloud/folder_sync');
  @override
  Future<bool> acquire(String account) async =>
      await _channel.invokeMethod<bool>('acquire', {'account': account}) ==
      true;
  @override
  Future<void> release(String account) =>
      _channel.invokeMethod<void>('release', {'account': account});
}

class InProcessSyncRunLock implements SyncRunLock {
  static final _owners = <String>{};
  @override
  Future<bool> acquire(String account) async => _owners.add(account);
  @override
  Future<void> release(String account) async {
    _owners.remove(account);
  }
}
