import '../backup/engine/file_mark.dart';
import '../backup/model/folder_pair.dart';
import 'phone_photo.dart';
import 'phone_source.dart';
import 'phone_states.dart';

/// The photos on the phone, each with where the backup stands with it.
class PhoneLibrary {
  PhoneLibrary({
    required PhoneSource source,
    required Future<List<FolderPair>> Function() pairs,
    required Future<List<FileMark>> Function(FolderPair pair) marks,
  }) : _source = source,
       _pairs = pairs,
       _marks = marks;

  final PhoneSource _source;
  final Future<List<FolderPair>> Function() _pairs;
  final Future<List<FileMark>> Function(FolderPair pair) _marks;

  /// Every photo on the phone, newest first.
  Future<List<PhoneEntry>> entries() async {
    final photos = await _source.photos();
    final marks = <FileMark>[
      for (final pair in await _pairs()) ...await _marks(pair),
    ];
    final states = PhoneStates(marks);
    return [for (final photo in photos) PhoneEntry(photo, states.of(photo))]
      ..sort((a, b) => b.photo.taken.compareTo(a.photo.taken));
  }
}
