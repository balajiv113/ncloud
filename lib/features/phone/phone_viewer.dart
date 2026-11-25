import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models.dart';
import '../viewer/zoom_asset.dart';
import 'phone_badge.dart';
import 'phone_source.dart';
import 'phone_timeline.dart';

/// Looks at photos that are only on the phone, swiping from one to the next.
/// Only what makes sense for them is offered: there is no cloud copy to
/// favorite, share or delete.
class PhoneViewer extends StatefulWidget {
  const PhoneViewer({
    super.key,
    required this.files,
    required this.initialIndex,
    required this.phone,
  });

  final List<CloudFile> files;
  final int initialIndex;
  final PhoneTimeline phone;

  @override
  State<PhoneViewer> createState() => _PhoneViewerState();
}

class _PhoneViewerState extends State<PhoneViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  /// Whether the picture on screen is zoomed in, when a drag moves it and must
  /// not turn the page.
  bool _zoomed = false;

  /// Whether the header is showing; tapping a photo toggles it.
  bool _chrome = true;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.files[_index];
    final state = file.onPhone!.state;
    final date = file.taken!;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.files.length,
            physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
            onPageChanged: (index) => setState(() {
              _index = index;
              _zoomed = false;
            }),
            itemBuilder: (context, index) => _PhonePage(
              key: ValueKey(widget.files[index].key),
              file: widget.files[index],
              phone: widget.phone,
              onZoomChanged: (zoomed) => setState(() => _zoomed = zoomed),
              onTap: () => setState(() => _chrome = !_chrome),
            ),
          ),
          if (_chrome)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black54, Colors.transparent],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        color: Colors.white,
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.maybePop(context),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white),
                            ),
                            Text(
                              '${MaterialLocalizations.of(context).formatMediumDate(date)}'
                              ' · ${PhoneBadge.labelOf(state)}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: PhoneBadge(state, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One photo or video: a large picture from the phone, which gives way to the
/// photo itself once that has loaded, and for a video a play button.
///
/// Neither is copied when the phone lets it be read where it is.
class _PhonePage extends StatefulWidget {
  const _PhonePage({
    super.key,
    required this.file,
    required this.phone,
    required this.onZoomChanged,
    required this.onTap,
  });

  final CloudFile file;
  final PhoneTimeline phone;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback onTap;

  @override
  State<_PhonePage> createState() => _PhonePageState();
}

class _PhonePageState extends State<_PhonePage> {
  late final Future<Uint8List?> _picture = widget.phone.thumbnails!.of(
    widget.file.onPhone!.id,
    2048,
  );

  /// The photo itself, once the phone has given it, to show in full clarity
  /// instead of the thumbnail.
  ImageProvider? _full;
  PhoneVideo? _video;
  VideoPlayerController? _player;
  bool _preparing = false;
  bool _gone = false;
  String? _error;

  /// The longest side a photo is drawn at. A photo is sharp at this size on any
  /// screen, even zoomed, and a huge one does not fill the phone's memory.
  static const _longestSide = 4096;

  @override
  void initState() {
    super.initState();
    if (!widget.file.isVideo) unawaited(_loadFull());
  }

  /// Asks the phone for the photo. One only flicked past is not worth it, so it
  /// waits a moment and gives up if the page has gone.
  Future<void> _loadFull() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_gone) return;
    try {
      final image = await widget.phone.image(widget.file.onPhone!.id);
      if (_gone || image == null) return;
      setState(() => _full = image);
    } on Object {
      // The thumbnail stays: it is the most the phone could give.
    }
  }

  @override
  void dispose() {
    _gone = true;
    _player?.dispose();
    unawaited(_video?.release());
    super.dispose();
  }

  Future<void> _play() async {
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final player = await _prepare();
      if (_gone) {
        await player.dispose();
        return;
      }
      await player.play();
      setState(() {
        _player = player;
        _preparing = false;
      });
    } on Object {
      if (_gone) return;
      setState(() {
        _preparing = false;
        _error = 'This video could not be played.';
      });
    }
  }

  /// A player for the video where it is, or, if the player cannot read it
  /// there, from a copy.
  Future<VideoPlayerController> _prepare() async {
    try {
      return await _open(copy: false);
    } on Object {
      return _open(copy: true);
    }
  }

  Future<VideoPlayerController> _open({required bool copy}) async {
    final video = await widget.phone.video(widget.file.onPhone!.id, copy: copy);
    final player = VideoPlayerController.file(video.file);
    try {
      await player.initialize();
    } on Object {
      await player.dispose();
      await video.release();
      rethrow;
    }
    unawaited(_video?.release());
    _video = video;
    return player;
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (player != null) {
      return GestureDetector(
        onTap: () => player.value.isPlaying ? player.pause() : player.play(),
        child: Center(
          child: AspectRatio(
            aspectRatio: player.value.aspectRatio,
            child: VideoPlayer(player),
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<Uint8List?>(
          future: _picture,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) {
              return Center(
                child: snapshot.connectionState == ConnectionState.done
                    ? const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 48,
                      )
                    : const CircularProgressIndicator(),
              );
            }
            return ZoomView(
              onTap: widget.onTap,
              onZoomChanged: widget.onZoomChanged,
              child: SizedBox.expand(child: _clear(bytes)),
            );
          },
        ),
        if (widget.file.isVideo)
          Center(
            child: _preparing
                ? const CircularProgressIndicator()
                : IconButton.filled(
                    tooltip: 'Play',
                    iconSize: 40,
                    icon: const Icon(Icons.play_arrow_rounded),
                    onPressed: _play,
                  ),
          ),
        if (_error != null)
          Positioned(
            bottom: 32,
            left: 16,
            right: 16,
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
          ),
      ],
    );
  }

  /// The thumbnail, with the photo over it once that has loaded. If the photo
  /// cannot be drawn (a format Flutter cannot decode), the thumbnail shows
  /// through.
  Widget _clear(Uint8List thumbnail) => Stack(
    fit: StackFit.expand,
    children: [
      Image.memory(thumbnail, fit: BoxFit.contain, gaplessPlayback: true),
      if (_full case final full?)
        Image(
          image: ResizeImage(
            full,
            width: _longestSide,
            height: _longestSide,
            policy: ResizeImagePolicy.fit,
          ),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
    ],
  );
}
