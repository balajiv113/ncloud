import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/sync_rules.dart';

void main() {
  test('empty include means all; exclude wins at every depth', () {
    final rules = SyncRules.patterns('', '*.tmp, Screenshots/**');
    expect(rules.allows(['Trips', 'photo.jpg']), isTrue);
    expect(rules.allows(['Trips', 'file.TMP']), isFalse);
    expect(rules.allows(['Screenshots', 'photo.jpg']), isFalse);
    expect(rules.visits(['Screenshots']), isFalse);
    expect(rules.visits(['Trips']), isTrue);
  });

  test('filename globs match album filenames and nested folder files', () {
    final rules = SyncRules.patterns(' *.heic, *.MOV ', 'Screenshot*');
    expect(rules.allows(['IMG_1234.HEIC']), isTrue);
    expect(rules.allows(['Travel', 'clip.mov']), isTrue);
    expect(rules.allows(['Travel', 'document.pdf']), isFalse);
    expect(rules.allows(['Screenshot_1234.heic']), isFalse);
  });

  test(
    'path globs support wildcards, zero-depth ** and literal regex chars',
    () {
      final rules = SyncRules.patterns('Trips/**/*.jp?, photo(1).jpg', '');
      expect(rules.allows(['Trips', 'a.jpg']), isTrue);
      expect(rules.allows(['Trips', 'Summer', 'a.jpg']), isTrue);
      expect(rules.allows(['TripsExtra', 'a.jpg']), isFalse);
      expect(rules.allows(['photo(1).jpg']), isTrue);
      expect(rules.allows(['photo1.jpg']), isFalse);
      expect(SyncRules.fromJson(rules.toJson()).toJson(), rules.toJson());
    },
  );

  test('invalid and excessive patterns fail explicitly', () {
    for (final pattern in [
      '/absolute',
      '../escape',
      'a/../b',
      r'a\b',
      '\u0000',
    ]) {
      expect(() => SyncRules.patterns(pattern, ''), throwsFormatException);
    }
    expect(
      () => SyncRules(include: List.generate(101, (i) => '$i.jpg')),
      throwsFormatException,
    );
  });

  test(
    'saved folder selections convert to patterns without widening the source',
    () {
      final rules = SyncRules.fromJson({
        'included': [
          ['Trips'],
        ],
        'excluded': [
          ['Trips', 'Private'],
        ],
        'types': 'photos',
      });
      expect(rules.allows(['Trips', 'photo.JPG']), isTrue);
      expect(rules.allows(['TripsExtra', 'photo.jpg']), isFalse);
      expect(rules.allows(['Trips', 'Private', 'photo.jpg']), isFalse);
      expect(rules.allows(['Trips', 'clip.mov']), isFalse);
      expect(rules.toJson().keys, ['include', 'exclude']);
    },
  );
}
