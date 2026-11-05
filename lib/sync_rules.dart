enum SyncFileTypes { all, photosAndVideos, photos, videos }

extension SyncFileTypesLabel on SyncFileTypes {
  String get label => switch (this) {
    SyncFileTypes.all => 'All file types',
    SyncFileTypes.photosAndVideos => 'Photos + videos',
    SyncFileTypes.photos => 'Photos only',
    SyncFileTypes.videos => 'Videos only',
  };
}

bool syncPathContains(List<String> parent, List<String> path) =>
    parent.length <= path.length &&
    Iterable.generate(parent.length).every((i) => parent[i] == path[i]);

class SyncRules {
  const SyncRules.all()
    : included = const [[]],
      excluded = const [],
      types = SyncFileTypes.all;

  SyncRules({
    Iterable<List<String>> included = const [[]],
    Iterable<List<String>> excluded = const [],
    this.types = SyncFileTypes.all,
  }) : included = List.unmodifiable(included.map(List<String>.unmodifiable)),
       excluded = List.unmodifiable(excluded.map(List<String>.unmodifiable));

  final List<List<String>> included;
  final List<List<String>> excluded;
  final SyncFileTypes types;

  bool visits(List<String> directory) =>
      !excluded.any((p) => syncPathContains(p, directory)) &&
      included.any(
        (p) => syncPathContains(p, directory) || syncPathContains(directory, p),
      );

  bool allows(List<String> file, {String contentType = ''}) {
    if (!included.any((p) => syncPathContains(p, file)) ||
        excluded.any((p) => syncPathContains(p, file))) {
      return false;
    }
    if (types == SyncFileTypes.all) return true;
    final extension = file.last.split('.').last.toLowerCase();
    final generic =
        contentType.isEmpty || contentType == 'application/octet-stream';
    final photo =
        contentType.startsWith('image/') ||
        (generic &&
            const {
              'jpg',
              'jpeg',
              'png',
              'gif',
              'webp',
              'heic',
              'heif',
              'avif',
              'bmp',
              'tif',
              'tiff',
              'dng',
              'raw',
              'cr2',
              'cr3',
              'nef',
              'arw',
              'orf',
              'rw2',
            }.contains(extension));
    final video =
        contentType.startsWith('video/') ||
        (generic &&
            const {
              'mp4',
              'mov',
              'm4v',
              'mkv',
              'avi',
              'webm',
              '3gp',
              '3g2',
              'mts',
              'm2ts',
              'mpeg',
              'mpg',
              'wmv',
              'ogv',
            }.contains(extension));
    return switch (types) {
      SyncFileTypes.all => true,
      SyncFileTypes.photosAndVideos => photo || video,
      SyncFileTypes.photos => photo,
      SyncFileTypes.videos => video,
    };
  }

  Map<String, Object> toJson() => {
    'included': included,
    'excluded': excluded,
    'types': types.name,
  };

  factory SyncRules.fromJson(Map<String, dynamic> value) => SyncRules(
    included: (value['included'] as List).map(
      (p) => (p as List).cast<String>(),
    ),
    excluded: (value['excluded'] as List).map(
      (p) => (p as List).cast<String>(),
    ),
    types: SyncFileTypes.values.byName(value['types'] as String),
  );
}
