import '../model/backup_schedule.dart';

abstract interface class BackupScheduler {
  bool get supported;
  String? get notice;
  Future<void> put(
    String pairId,
    String revision,
    BackupSchedule schedule, {
    required bool wifiOnly,
  });
  Future<void> cancel(String pairId);
}

class UnsupportedBackupScheduler implements BackupScheduler {
  @override
  bool get supported => false;
  @override
  String? get notice => null;
  @override
  Future<void> put(
    String pairId,
    String revision,
    BackupSchedule schedule, {
    required bool wifiOnly,
  }) async {
    throw UnsupportedError('Scheduled backup is currently Android only.');
  }

  @override
  Future<void> cancel(String pairId) async {}
}
