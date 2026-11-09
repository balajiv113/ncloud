import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app/app_controller.dart';
import '../../core/ui/messages.dart';
import '../../models.dart';

/// Plays a Live Photo's short video over the photo when the LIVE button is
/// tapped or the photo is pressed and held, then returns to the still.
class LivePhotoOverlay extends StatefulWidget {
  const LivePhotoOverlay({
    super.key,
    required this.file,
    required this.controller,
    required this.active,
    required this.child,
  });

  final CloudFile file;
  final AppController controller;

  /// Whether this is the photo being looked at; playback stops when it is not.
  final bool active;
  final Widget child;

  @override
  State<LivePhotoOverlay> createState() => _LivePhotoOverlayState();
}

class _LivePhotoOverlayState extends State<LivePhotoOverlay> {
  VideoPlayerController? _player;
  bool _loading = false;
  int _request = 0;

  @override
  void didUpdateWidget(LivePhotoOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && oldWidget.active) unawaited(_stop());
  }

  @override
  void dispose() {
    _request++;
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    if (_loading || _player != null || !widget.active) return;
    final request = ++_request;
    setState(() => _loading = true);
    VideoPlayerController? player;
    try {
      final clip = await widget.controller.livePhotoClip(widget.file);
      if (!mounted || request != _request) return;
      player = VideoPlayerController.file(clip);
      await player.initialize();
      if (!mounted || request != _request) {
        await player.dispose();
        return;
      }
      await player.setLooping(false);
      player.addListener(_watch);
      setState(() => _player = player);
      await player.play();
    } catch (e) {
      await player?.dispose();
      if (mounted && request == _request) showError(context, e);
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _watch() {
    final value = _player?.value;
    if (value == null || !value.isInitialized) return;
    if (value.duration > Duration.zero &&
        value.position >= value.duration &&
        !value.isPlaying) {
      unawaited(_stop());
    }
  }

  Future<void> _stop() async {
    _request++;
    final player = _player;
    if (player == null) {
      if (mounted && _loading) setState(() => _loading = false);
      return;
    }
    player.removeListener(_watch);
    if (mounted) {
      setState(() {
        _player = null;
        _loading = false;
      });
    }
    await player.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final playing = player != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(onLongPress: _start, child: widget.child),
        if (player != null && player.value.isInitialized)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: player.value.aspectRatio,
                    child: VideoPlayer(player),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: 12,
          top: MediaQuery.paddingOf(context).top + 104,
          child: Semantics(
            button: true,
            label: playing ? 'Stop Live Photo' : 'Play Live Photo',
            child: Material(
              color: Colors.black54,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: playing ? _stop : _start,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_loading)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      else
                        Icon(
                          playing
                              ? Icons.stop_rounded
                              : Icons.motion_photos_on_outlined,
                          size: 16,
                          color: Colors.white,
                        ),
                      const SizedBox(width: 6),
                      const Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
