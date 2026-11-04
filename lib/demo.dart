import 'models.dart';

List<CloudFile> demoFiles() {
  final now = DateTime.now();
  return [
    const CloudFile(path: ['Photos'], name: 'Photos', isDirectory: true),
    const CloudFile(path: ['Weekend escapes'], name: 'Weekend escapes', isDirectory: true),
    const CloudFile(path: ['Coast & country'], name: 'Coast & country', isDirectory: true),
    const CloudFile(path: ['Documents'], name: 'Documents', isDirectory: true),
    CloudFile(
      path: const ['Welcome to ncloud.txt'],
      name: 'Welcome to ncloud.txt',
      isDirectory: false,
      contentType: 'text/plain',
      size: 1280,
      modified: now,
      favorite: true,
    ),
    CloudFile(
      path: const ['Documents', 'Travel notes.pdf'],
      name: 'Travel notes.pdf',
      isDirectory: false,
      contentType: 'application/pdf',
      size: 281600,
      modified: now.subtract(const Duration(days: 3)),
    ),
    for (final (index, name) in [
      'Alpine morning',
      'Desert light',
      'Ocean breeze',
      'After the rain',
      'Golden hour',
      'Into the blue',
      'Quiet places',
      'Weekend escape',
      'City sunset',
      'The long way home',
      'First light',
      'Wild coast',
    ].indexed)
      CloudFile(
        path: [index < 4 ? 'Photos' : index < 8 ? 'Weekend escapes' : 'Coast & country',
          '$name.${index == 11 ? 'mp4' : 'jpg'}'],
        name: '$name.${index == 11 ? 'mp4' : 'jpg'}',
        isDirectory: false,
        contentType: index == 11 ? 'video/mp4' : 'image/jpeg',
        size: 2100000 + index * 190000,
        modified: now.subtract(Duration(days: index < 4 ? index ~/ 2 : index * 6)),
        favorite: index == 0 || index == 4 || index == 8,
        demoColor: [
          0xFF3B7974,
          0xFFBB7455,
          0xFF427FA0,
          0xFF667D65,
          0xFFB88A49,
          0xFF526BA3,
        ][index % 6],
      ),
  ];
}
