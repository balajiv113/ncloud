import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../models.dart';
import '../backup/platform/device_library.dart';
import '../backup/model/backup_state.dart';
import 'phone_choice.dart';
import 'phone_library.dart';
import 'phone_photo.dart';
import 'phone_source.dart';
import 'phone_thumbnails.dart';
import 'phone_view.dart';

/// The phone's photos that the cloud does not have: read from the phone, kept
/// as a view of all of them and one for each album, and handed to the Timeline
/// and the albums to lay in with the cloud's own. With no phone to read it has
/// nothing to show.
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

  /// The photo with the phone's id [id] itself, or null if it cannot be had.
  Future<ImageProvider?> image(String id) => _source!.image(id);

  /// The video with the phone's id [id], ready to play.
  Future<PhoneVideo> video(String id, {bool copy = false}) =>
      _source!.video(id, copy: copy);

  PhoneView _all = PhoneView.none();
  Map<String, PhoneView> _albums = const {};
  Map<String, String> _albumNames = const {};

  /// Every photo that is only on the phone, for the Timeline.
  PhoneView get all => _all;

  /// The photos of the album called [name] on the phone, whatever its case.
  PhoneView album(String name) =>
      _albums[name.toLowerCase()] ?? PhoneView.none();

  /// The phone's albums that have photos not backed up, by the name the phone
  /// gives them.
  Map<String, PhoneView> get albums => {
    for (final entry in _albums.entries) _albumNames[entry.key]!: entry.value,
  };

  /// The photos that are only on the phone, newest first.
  List<CloudFile> get files => _all.files;

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

  /// What is shown, by photo and state, to tell whether a reading changed it.
  static List<String> _signature(Iterable<CloudFile> files) => [
    for (final file in files)
      '${file.onPhone!.id}|${file.onPhone!.state.index}',
  ];

  bool _replace(List<PhoneEntry> entries) {
    final files = [for (final entry in entries) _file(entry)];
    if (listEquals(_signature(files), _signature(_all.files))) return false;
    _all = PhoneView(files);
    final byAlbum = <String, List<CloudFile>>{};
    _albumNames = {};
    for (final file in files) {
      final name = file.onPhone!.album;
      final key = name.toLowerCase();
      _albumNames.putIfAbsent(key, () => name);
      byAlbum.putIfAbsent(key, () => []).add(file);
    }
    _albums = {
      for (final entry in byAlbum.entries) entry.key: PhoneView(entry.value),
    };
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
      onPhone: OnPhone(photo.id, entry.state, photo.album),
    );
  }
}
