import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models.dart';
import 'phone_badge.dart';
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
            ),
          ),
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

/// One photo or video: a large picture from the phone, and for a video a play
/// button that copies it to a temporary file and plays that.
class _PhonePage extends StatefulWidget {
  const _PhonePage({
    super.key,
    required this.file,
    required this.phone,
    required this.onZoomChanged,
  });

  final CloudFile file;
  final PhoneTimeline phone;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_PhonePage> createState() => _PhonePageState();
}

class _PhonePageState extends State<_PhonePage> {
  late final Future<Uint8List?> _picture = widget.phone.thumbnails!.of(
    widget.file.onPhone!.id,
    1600,
  );
  final TransformationController _zoom = TransformationController();
  VideoPlayerController? _player;
  File? _copy;
  bool _preparing = false;
  String? _error;

  @override
  void dispose() {
    _zoom.dispose();
    _player?.dispose();
    _copy?.delete().ignore();
    super.dispose();
  }

  Future<void> _play() async {
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final copy = _copy = await widget.phone.original(widget.file.onPhone!.id);
      final player = VideoPlayerController.file(copy);
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      await player.play();
      setState(() {
        _player = player;
        _preparing = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = 'This video could not be played.';
      });
    }
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
            return InteractiveViewer(
              transformationController: _zoom,
              maxScale: 5,
              onInteractionEnd: (_) =>
                  widget.onZoomChanged(_zoom.value.getMaxScaleOnAxis() > 1.01),
              child: SizedBox.expand(
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
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
}
