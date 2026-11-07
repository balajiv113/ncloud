import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  Future<void> check(String path, List<String> items, int listings) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    Map<String, dynamic>? state;
    do {
      state =
          jsonDecode(await driver.requestData('driveState'))
              as Map<String, dynamic>;
      if (state['error'] != null) {
        throw StateError('Drive failed: $state');
      }
      if (state['loading'] == false && state['directory'] == path) {
        if (jsonEncode(state['items']) != jsonEncode(items) ||
            state['listings'] != listings) {
          throw StateError('Unexpected Drive contents or cache miss: $state');
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } while (DateTime.now().isBefore(deadline));
    throw StateError('Drive did not finish opening $path: $state');
  }

  try {
    final platform = await driver.requestData('platform');
    final nativeResult = await driver.requestData(
      'nativeContract',
      timeout: const Duration(seconds: 45),
    );
    if (nativeResult !=
        'Native staging, conditions, account locks and pair storage verified.') {
      throw StateError('Unexpected native contract result: $nativeResult');
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      final cached = attempt == 1;
      if (cached && await driver.requestData('reopen') != 'reopened') {
        throw StateError('Could not reopen the persisted catalogue.');
      }
      await driver.waitFor(find.byValueKey('drive:Trips'));
      await check('', ['Other', 'Trips'], cached ? 4 : 1);
      await driver.tap(find.byValueKey('drive:Trips'));
      await driver.waitFor(find.byValueKey('drive:Trips/Summer'));
      await check('Trips', ['Trips/Summer'], cached ? 4 : 2);
      await driver.tap(find.byValueKey('drive:Trips/Summer'));
      await driver.waitFor(find.byValueKey('drive:Trips/Summer/Autumn'));
      await driver.waitFor(find.byValueKey('drive:Trips/Summer/notes.txt'));
      await check('Trips/Summer', [
        'Trips/Summer/Autumn',
        'Trips/Summer/notes.txt',
      ], cached ? 4 : 3);
      await driver.tap(find.byValueKey('drive:Trips/Summer/Autumn'));
      await check('Trips/Summer/Autumn', [], 4);
    }
    stdout.writeln(
      '$platform: native plugin contract, nested Drive navigation, empty folders '
      'and persisted SQLite reopen without network listings passed.',
    );
    if (platform == 'ios') {
      final albumResult = await driver.requestData(
        'testAlbum',
        timeout: const Duration(minutes: 3),
      );
      if (albumResult !=
          'Real PhotoKit original bytes and repeated-upload receipts verified.') {
        throw StateError('Unexpected album test result: $albumResult');
      }
      stdout.writeln(albumResult);
    }
    if (await driver.requestData('close') != 'closed') {
      throw StateError('Could not close the mobile test catalogue.');
    }
  } finally {
    await driver.close();
  }
}
