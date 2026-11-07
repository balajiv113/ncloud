class SyncRules {
  const SyncRules.all() : include = const [], exclude = const [];

  SyncRules({
    Iterable<String> include = const [],
    Iterable<String> exclude = const [],
  }) : include = List.unmodifiable(include),
       exclude = List.unmodifiable(exclude) {
    for (final pattern in [...this.include, ...this.exclude]) {
      if (pattern.isEmpty ||
          pattern.length > 512 ||
          pattern.startsWith('/') ||
          pattern.split('/').any((part) => part == '.' || part == '..') ||
          pattern.contains(RegExp(r'[\x00-\x1f\\]'))) {
        throw const FormatException('Enter source-relative glob patterns.');
      }
    }
    if (this.include.length + this.exclude.length > 100) {
      throw const FormatException('Use at most 100 patterns.');
    }
  }

  factory SyncRules.patterns(String include, String exclude) =>
      SyncRules(include: _parse(include), exclude: _parse(exclude));

  final List<String> include;
  final List<String> exclude;
  String get includeText => include.join(', ');
  String get excludeText => exclude.join(', ');

  static Iterable<String> _parse(String text) =>
      text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);

  // Filename-only patterns apply at every depth. Slash patterns match the
  // complete source-relative path; **/ also matches zero directories.
  static bool _matches(String pattern, List<String> path) {
    final expression = StringBuffer('^');
    for (var i = 0; i < pattern.length; i++) {
      final char = pattern[i];
      if (char == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          i++;
          if (i + 1 < pattern.length && pattern[i + 1] == '/') {
            i++;
            expression.write('(?:.*/)?');
          } else {
            expression.write('.*');
          }
        } else {
          expression.write('[^/]*');
        }
      } else if (char == '?') {
        expression.write('[^/]');
      } else {
        expression.write(RegExp.escape(char));
      }
    }
    expression.write(r'$');
    final value = pattern.contains('/') ? path.join('/') : path.last;
    return RegExp(expression.toString(), caseSensitive: false).hasMatch(value);
  }

  bool visits(List<String> directory) => !exclude.any(
    (pattern) =>
        pattern.endsWith('/**') &&
        _matches(pattern.substring(0, pattern.length - 3), directory),
  );

  bool allows(List<String> file, {String contentType = ''}) =>
      (include.isEmpty || include.any((p) => _matches(p, file))) &&
      !exclude.any((p) => _matches(p, file));

  Map<String, Object> toJson() => {'include': include, 'exclude': exclude};

  factory SyncRules.fromJson(Map<String, dynamic> value) {
    if (value.containsKey('include')) {
      return SyncRules(
        include: (value['include'] as List).cast<String>(),
        exclude: (value['exclude'] as List).cast<String>(),
      );
    }
    // Preserve saved selections and receipts when moving from folder rules
    // to patterns. New records only write the pattern format.
    final folders = (value['included'] as List).map(
      (p) => (p as List).cast<String>().join('/'),
    );
    const photos = [
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
    ];
    const videos = [
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
    ];
    final extensions = switch (value['types']) {
      'all' => <String>[],
      'photos' => photos,
      'videos' => videos,
      'photosAndVideos' => [...photos, ...videos],
      _ => throw const FormatException('Invalid saved file filter.'),
    };
    return SyncRules(
      include: [
        for (final folder in folders)
          if (extensions.isEmpty)
            folder.isEmpty ? '**' : '$folder/**'
          else
            for (final extension in extensions)
              '${folder.isEmpty ? '' : '$folder/'}**/*.$extension',
      ],
      exclude: [
        for (final path in value['excluded'] as List)
          (path as List).isEmpty ? '**' : '${path.cast<String>().join('/')}/**',
      ],
    );
  }
}
