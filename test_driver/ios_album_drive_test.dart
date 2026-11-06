import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  try {
    await driver.waitFor(
      find.byValueKey('drive:Trips'),
      timeout: const Duration(seconds: 45),
    );
    final root = jsonDecode(await driver.requestData('driveState'));
    if (root['directory'] != '' ||
        jsonEncode(root['items']) != '["Other","Trips"]') {
      throw StateError(
        'Drive root contains repeated or out-of-scope folders: $root',
      );
    }
    await driver.tap(find.byValueKey('drive:Trips'));
    await driver.waitFor(
      find.byValueKey('drive:Trips/Summer'),
      timeout: const Duration(seconds: 45),
    );
    final child = jsonDecode(await driver.requestData('driveState'));
    if (child['directory'] != 'Trips' ||
        jsonEncode(child['items']) != '["Trips/Summer"]') {
      throw StateError(
        'Drive did not open only the requested direct children: $child',
      );
    }
    await driver.tap(find.byValueKey('drive:Trips/Summer'));
    await driver.waitFor(
      find.byValueKey('drive:Trips/Summer/Autumn'),
      timeout: const Duration(seconds: 45),
    );
    await driver.waitFor(
      find.byValueKey('drive:Trips/Summer/notes.txt'),
      timeout: const Duration(seconds: 45),
    );
    final grandchild = jsonDecode(await driver.requestData('driveState'));
    if (grandchild['directory'] != 'Trips/Summer' ||
        jsonEncode(grandchild['items']) !=
            '["Trips/Summer/Autumn","Trips/Summer/notes.txt"]') {
      throw StateError(
        'Drive repeated the parent instead of opening the second folder: $grandchild',
      );
    }
    stdout.writeln('iOS simulator: two-level Drive navigation passed.');
    final albumResult = await driver.requestData(
      'testAlbum',
      timeout: const Duration(minutes: 3),
    );
    if (albumResult !=
        'Real PhotoKit original bytes and repeated-upload receipts verified.') {
      throw StateError('Unexpected album test result: $albumResult');
    }
    if (await driver.requestData('close') != 'closed') {
      throw StateError('Could not close the simulator test catalogue.');
    }
    stdout.writeln(
      'iOS simulator: unique Drive folders/navigation, real PhotoKit originals and upload receipts passed.',
    );
  } finally {
    await driver.close();
  }
}
