import '../../../models.dart';
import '../platform/folder_access.dart';
import 'sync_rules.dart';
import 'backup_schedule.dart';

String syncAccount(Account account) => account.storageKey;

class FolderPair {
  FolderPair({
    required this.id,
    required this.account,
    required this.name,
    required this.folder,
    required this.remote,
    this.wifiOnly = true,
    this.lastRun,
    this.rules = const SyncRules.all(),
    this.uploadConcurrency = 1,
    this.schedule,
    this.revision = '',
  });
  final String id;
  final String account;
  final String name;
  final DeviceFolder folder;
  final List<String> remote;
  final bool wifiOnly;
  DateTime? lastRun;
  final SyncRules rules;
  final int uploadConcurrency;
  final BackupSchedule? schedule;
  final String revision;

  List<String> get cloudRoot => [...remote, folder.name];

  /// The scheduled occurrence that is due at [now] and has not been run for
  /// this version of the pair, or null. [state] is the pair's journal state,
  /// which records the last occurrence handled and the revision it ran under.
  String? dueSlot(Map<String, dynamic> state, DateTime now) {
    final schedule = this.schedule;
    final slot = schedule?.dueSlot(now);
    if (schedule == null || slot == null) return null;
    final handled =
        state['revision'] == revision &&
        schedule.handled(slot, state['slot'] as String?);
    return handled ? null : slot;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'account': account,
    'name': name,
    'token': folder.token,
    'folderName': folder.name,
    'identity': folder.identity,
    'sourceKind': folder.kind.name,
    'remote': remote,
    'wifiOnly': wifiOnly,
    'lastRun': lastRun?.toIso8601String(),
    'rules': rules.toJson(),
    'uploadConcurrency': uploadConcurrency,
    'schedule': schedule?.toJson(),
    'revision': revision,
  };

  factory FolderPair.fromJson(Map<String, dynamic> value) => FolderPair(
    id: value['id'] as String,
    account: value['account'] as String,
    name: value['name'] as String,
    folder: DeviceFolder(
      value['token'] as String,
      value['folderName'] as String,
      value['identity'] as String,
      kind: DeviceSourceKind.values.byName(
        value['sourceKind'] as String? ?? DeviceSourceKind.folder.name,
      ),
    ),
    remote: (value['remote'] as List).cast<String>(),
    wifiOnly: value['wifiOnly'] as bool,
    lastRun: DateTime.tryParse(value['lastRun'] as String? ?? ''),
    rules: SyncRules.fromJson((value['rules'] as Map).cast<String, dynamic>()),
    uploadConcurrency: value['uploadConcurrency'] as int,
    schedule: value['schedule'] == null
        ? null
        : BackupSchedule.fromJson(
            (value['schedule'] as Map).cast<String, dynamic>(),
          ),
    revision: value['revision'] as String? ?? '',
  );
}
