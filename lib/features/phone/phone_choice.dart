import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Whether the phone's photos are shown in the Timeline.
enum PhoneChoice {
  /// Not decided yet: the first time, the user is asked for access to the
  /// phone's photos.
  ask,
  show,
  hide,
}

/// Remembers the user's [PhoneChoice].
abstract interface class PhoneChoiceStore {
  Future<PhoneChoice> read();
  Future<void> write(PhoneChoice choice);
}

/// Keeps the choice in a small file beside the app's other saved data.
class FilePhoneChoiceStore implements PhoneChoiceStore {
  Future<File> _file() async => File(
    '${(await getApplicationSupportDirectory()).path}/phone-photos.choice',
  );

  @override
  Future<PhoneChoice> read() async {
    final file = await _file();
    if (!await file.exists()) return PhoneChoice.ask;
    final saved = await file.readAsString();
    return PhoneChoice.values.firstWhere(
      (choice) => choice.name == saved.trim(),
      orElse: () => PhoneChoice.ask,
    );
  }

  @override
  Future<void> write(PhoneChoice choice) async =>
      (await _file()).writeAsString(choice.name);
}

/// Keeps the choice in memory, for tests.
class MemoryPhoneChoiceStore implements PhoneChoiceStore {
  MemoryPhoneChoiceStore([this.choice = PhoneChoice.show]);

  PhoneChoice choice;

  @override
  Future<PhoneChoice> read() async => choice;

  @override
  Future<void> write(PhoneChoice choice) async => this.choice = choice;
}
