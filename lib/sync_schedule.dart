enum ScheduleKind { interval, daily, weekly }

/// Calendar schedules follow the device's current local timezone. A wall date
/// identifies an occurrence, so the repeated DST hour never runs twice.
class BackupSchedule {
  BackupSchedule({
    required this.kind,
    required this.created,
    this.minutes = 60,
    this.hour = 2,
    this.minute = 0,
    this.weekday = DateTime.monday,
  }) {
    if (minutes < 15 ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59 ||
        weekday < 1 ||
        weekday > 7) {
      throw const FormatException(
        'Choose an interval of at least 15 minutes and a valid time.',
      );
    }
  }

  final ScheduleKind kind;
  final DateTime created;
  final int minutes, hour, minute, weekday;

  DateTime _calendar(DateTime now, int offset) =>
      DateTime(now.year, now.month, now.day + offset, hour, minute);

  DateTime next(DateTime now) {
    if (kind == ScheduleKind.interval) {
      final elapsed = now.difference(created).inMilliseconds;
      final span = Duration(minutes: minutes).inMilliseconds;
      return created.add(
        Duration(milliseconds: (elapsed < 0 ? 1 : elapsed ~/ span + 1) * span),
      );
    }
    for (var offset = 0; offset <= 7; offset++) {
      final date = _calendar(now.toLocal(), offset);
      if (date.isAfter(now) &&
          (kind != ScheduleKind.weekly || date.weekday == weekday)) {
        return date;
      }
    }
    throw StateError('No next calendar occurrence.');
  }

  /// Coalesces missed occurrences into the most recent slot, never a backlog.
  String? dueSlot(DateTime now) {
    if (kind == ScheduleKind.interval) {
      final slot = now.difference(created).inMinutes ~/ minutes;
      return slot < 1 ? null : 'interval:$slot';
    }
    for (var offset = 0; offset >= -7; offset--) {
      final date = _calendar(now.toLocal(), offset);
      if (!date.isAfter(now) &&
          date.isAfter(created) &&
          (kind != ScheduleKind.weekly || date.weekday == weekday)) {
        return '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      }
    }
    return null;
  }

  bool handled(String slot, String? completed) {
    if (completed == null) return false;
    if (kind == ScheduleKind.interval) {
      return int.parse(slot.split(':').last) <=
          int.parse(completed.split(':').last);
    }
    return slot.compareTo(completed) <= 0;
  }

  Map<String, Object> toJson() => {
    'kind': kind.name,
    'created': created.toUtc().toIso8601String(),
    'minutes': minutes,
    'hour': hour,
    'minute': minute,
    'weekday': weekday,
  };
  factory BackupSchedule.fromJson(Map<String, dynamic> value) => BackupSchedule(
    kind: ScheduleKind.values.byName(value['kind'] as String),
    created: DateTime.parse(value['created'] as String),
    minutes: value['minutes'] as int,
    hour: value['hour'] as int,
    minute: value['minute'] as int,
    weekday: value['weekday'] as int,
  );
}

abstract interface class BackupScheduler {
  bool get supported;
  Future<void> put(
    String pairId,
    String revision,
    BackupSchedule schedule, {
    required bool wifiOnly,
    required bool chargingOnly,
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
    required bool chargingOnly,
  }) async {
    throw UnsupportedError('Scheduled backup is currently Android only.');
  }

  @override
  Future<void> cancel(String pairId) async {}
}
