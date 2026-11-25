import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models.dart';
import '../backup/platform/device_library.dart';
import '../backup/model/backup_state.dart';
import 'phone_choice.dart';
import 'phone_library.dart';
import 'phone_photo.dart';
import 'phone_source.dart';
import 'phone_thumbnails.dart';

/// The phone's photos that the cloud does not have, laid in with the cloud's
/// own in the Timeline.
///
/// It is an overlay: it hands the Timeline merged lists and leaves the cloud's
/// own lists, and the cache behind them, untouched. With no phone to read it
/// passes the cloud's lists straight through.
class PhoneTimeline {
  PhoneTimeline({
    required PhoneLibrary library,
    required PhoneSource source,
    required PhoneChoiceStore choices,
  }) : _library = library,
       thumbnails = PhoneThumbnails(source),
       _source = source,
       _choices = choices;

  /// Shows nothing and reads nothing, for a platform with no phone library.
  PhoneTimeline.none()
    : _library = null,
      _source = null,
      _choices = null,
      thumbnails = null;

  final PhoneLibrary? _library;
  final PhoneSource? _source;
  final PhoneChoiceStore? _choices;
  StreamSubscription<void>? _watching;
  Timer? _debounce;

  /// Thumbnails of the phone's photos, or null with no phone to read.
  final PhoneThumbnails? thumbnails;

  /// A copy of the photo with the phone's id [id] as it is, in a temporary file
  /// the caller removes.
  Future<File> original(String id) => _source!.original(id);

  List<CloudFile> _files = const [];
  Map<int, int> _perDay = const {};

  // The merged lists are kept while their inputs are the same lists, so the
  // screens that compare lists by identity see no change.
  (List<CloudFile>, List<CloudFile>)? _mergedFiles;
  List<CloudFile>? _merged;
  (List<TimelineDay>, Map<int, int>)? _mergedDaysFrom;
  List<TimelineDay>? _mergedDays;
  Set<int> _cloudDays = const {};

  /// The photos on the phone that are not backed up, newest first.
  List<CloudFile> get files => _files;

  /// How many of the photos shown are in each state.
  Map<BackupState, int> get counts {
    final counts = <BackupState, int>{};
    for (final file in _files) {
      counts.update(file.onPhone!.state, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  /// Reads the phone again. Returns whether anything shown changed.
  Future<bool> load() async {
    final library = _library;
    if (library == null) return false;
    if (!await _allowed()) return _replace(const []);
    final entries = await library.entries();
    return _replace([
      for (final entry in entries)
        if (entry.state != BackupState.backedUp) entry,
    ]);
  }

  /// What is shown, by photo and state, to tell whether a reading changed it.
  static List<String> _signature(Iterable<CloudFile> files) => [
    for (final file in files)
      '${file.onPhone!.id}|${file.onPhone!.state.index}',
  ];

  /// Whether the phone's photos may be read now: the user has not turned them
  /// off, and the phone allows it. The first time, the user is asked.
  Future<bool> _allowed() async {
    switch (await _choices!.read()) {
      case PhoneChoice.hide:
        return false;
      case PhoneChoice.ask:
        return setShown(true);
      case PhoneChoice.show:
        return await _source!.permission() != LibraryPermission.denied;
    }
  }

  /// Turns the phone's photos on or off. Turning them on asks the phone for
  /// access when it has not been given. Returns whether they are now on.
  Future<bool> setShown(bool shown) async {
    final choices = _choices;
    if (choices == null) return false;
    final on = shown && await _source!.request() != LibraryPermission.denied;
    await choices.write(on ? PhoneChoice.show : PhoneChoice.hide);
    return on;
  }

  /// Whether the phone's photos are turned on.
  Future<bool> isShown() async => await _choices?.read() == PhoneChoice.show;

  /// Calls [onChange] when the phone's library has changed and settled, so a new
  /// photo appears and a backed-up one goes without a refresh.
  void watch(VoidCallback onChange) {
    _watching ??= _source?.changes.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), onChange);
    });
  }

  void dispose() {
    _debounce?.cancel();
    unawaited(_watching?.cancel());
  }

  bool _replace(List<PhoneEntry> entries) {
    final files = [for (final entry in entries) _file(entry)];
    if (listEquals(_signature(files), _signature(_files))) return false;
    _files = files;
    _perDay = {};
    for (final file in files) {
      _perDay.update(file.captureDay!, (n) => n + 1, ifAbsent: () => 1);
    }
    thumbnails?.clear();
    return true;
  }

  static CloudFile _file(PhoneEntry entry) {
    final photo = entry.photo;
    final day = DateTime.utc(
      photo.taken.year,
      photo.taken.month,
      photo.taken.day,
    );
    return CloudFile(
      path: [CloudFile.phoneRoot, photo.id],
      name: photo.name,
      isDirectory: false,
      contentType: photo.isVideo ? 'video/*' : 'image/*',
      size: photo.size,
      modified: photo.taken,
      taken: photo.taken,
      captureDay: day.millisecondsSinceEpoch ~/ 86400000,
      onPhone: OnPhone(photo.id, entry.state),
    );
  }

  /// The cloud's [cloud] photos with the phone's laid in by date.
  List<CloudFile> items(List<CloudFile> cloud) {
    if (_files.isEmpty) return cloud;
    final from = _mergedFiles;
    if (from != null &&
        identical(from.$1, cloud) &&
        identical(from.$2, _files)) {
      return _merged!;
    }
    _mergedFiles = (cloud, _files);
    return _merged = [...cloud, ..._files];
  }

  /// The cloud's days with the phone's added, so a day that only the phone has
  /// gets a section of its own and the others count both.
  List<TimelineDay> days(List<TimelineDay> cloud) {
    _cloudDays = {for (final day in cloud) day.id};
    if (_perDay.isEmpty) return cloud;
    final from = _mergedDaysFrom;
    if (from != null &&
        identical(from.$1, cloud) &&
        identical(from.$2, _perDay)) {
      return _mergedDays!;
    }
    _mergedDaysFrom = (cloud, _perDay);
    final counts = {for (final day in cloud) day.id: day.count};
    _perDay.forEach(
      (id, n) => counts.update(id, (c) => c + n, ifAbsent: () => n),
    );
    return _mergedDays = [
      for (final id in counts.keys.toList()..sort((a, b) => b.compareTo(a)))
        TimelineDay(id, counts[id]!),
    ];
  }

  /// Whether [day] is whole as far as this overlay knows: a day only the phone
  /// has has nothing to load from the server. Otherwise [cloudLoaded] says.
  bool dayLoaded(int day, bool Function(int day) cloudLoaded) =>
      _perDay.containsKey(day) && !_cloudDays.contains(day) || cloudLoaded(day);
}
