/// Calendar schedules follow the device's current local timezone. A wall date
/// identifies an occurrence, so the repeated DST hour never runs twice.
class BackupSchedule {
  BackupSchedule({required this.created, this.hour = 2, this.minute = 0}) {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw const FormatException('Choose a valid daily backup time.');
    }
  }

  final DateTime created;
  final int hour, minute;

  DateTime _calendar(DateTime now, int offset) =>
      DateTime(now.year, now.month, now.day + offset, hour, minute);

  DateTime next(DateTime now) {
    for (var offset = 0; offset <= 1; offset++) {
      final date = _calendar(now.toLocal(), offset);
      if (date.isAfter(now)) {
        return date;
      }
    }
    throw StateError('No next calendar occurrence.');
  }

  /// Coalesces missed occurrences into the most recent slot, never a backlog.
  String? dueSlot(DateTime now) {
    for (var offset = 0; offset >= -1; offset--) {
      final date = _calendar(now.toLocal(), offset);
      if (!date.isAfter(now) && date.isAfter(created)) {
        return '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      }
    }
    return null;
  }

  bool handled(String slot, String? completed) {
    if (completed == null) return false;
    return slot.compareTo(completed) <= 0;
  }

  Map<String, Object> toJson() => {
    'created': created.toUtc().toIso8601String(),
    'hour': hour,
    'minute': minute,
  };
  factory BackupSchedule.fromJson(Map<String, dynamic> value) => BackupSchedule(
    created: DateTime.parse(value['created'] as String),
    hour: value['hour'] as int,
    minute: value['minute'] as int,
  );
}

abstract interface class BackupScheduler {
  bool get supported;
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
