import '../../models.dart';
import '../backup/model/backup_state.dart';

/// A set of the phone's photos that the cloud does not have, as one view lays
/// them in with the cloud's own: all of them in the Timeline, or those of one
/// album in that album.
///
/// It hands out merged lists and leaves the cloud's lists, and the cache behind
/// them, untouched. The merged lists are kept while their inputs are the same
/// lists, so the screens that compare lists by identity see no change.
class PhoneView {
  PhoneView(this.files) : _perDay = _countDays(files);

  /// A view with no phone photos in it: every list passes straight through.
  PhoneView.none() : files = const [], _perDay = const {};

  /// The photos, newest first.
  final List<CloudFile> files;
  final Map<int, int> _perDay;

  static Map<int, int> _countDays(List<CloudFile> files) {
    final days = <int, int>{};
    for (final file in files) {
      days.update(file.captureDay!, (n) => n + 1, ifAbsent: () => 1);
    }
    return days;
  }

  (List<CloudFile>, List<CloudFile>)? _mergedFrom;
  List<CloudFile>? _merged;
  List<TimelineDay>? _daysFrom;
  List<TimelineDay>? _mergedDays;
  Set<int> _cloudDays = const {};

  /// How many of the photos are in each state.
  Map<BackupState, int> get counts {
    final counts = <BackupState, int>{};
    for (final file in files) {
      counts.update(file.onPhone!.state, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  /// The cloud's [cloud] photos with these laid in by date.
  List<CloudFile> items(List<CloudFile> cloud) {
    if (files.isEmpty) return cloud;
    final from = _mergedFrom;
    if (from != null && identical(from.$1, cloud)) return _merged!;
    _mergedFrom = (cloud, files);
    return _merged = [...cloud, ...files];
  }

  /// The cloud's days with these added, so a day only the phone has gets a
  /// section of its own and the others count both.
  List<TimelineDay> days(List<TimelineDay> cloud) {
    _cloudDays = {for (final day in cloud) day.id};
    if (_perDay.isEmpty) return cloud;
    if (identical(_daysFrom, cloud)) return _mergedDays!;
    _daysFrom = cloud;
    final counts = {for (final day in cloud) day.id: day.count};
    _perDay.forEach(
      (id, n) => counts.update(id, (c) => c + n, ifAbsent: () => n),
    );
    return _mergedDays = [
      for (final id in counts.keys.toList()..sort((a, b) => b.compareTo(a)))
        TimelineDay(id, counts[id]!),
    ];
  }

  /// Whether [day] is whole as far as this view knows: a day only the phone has
  /// has nothing to load from the server. Otherwise [cloudLoaded] says.
  bool dayLoaded(int day, bool Function(int day) cloudLoaded) =>
      _perDay.containsKey(day) && !_cloudDays.contains(day) || cloudLoaded(day);
}
