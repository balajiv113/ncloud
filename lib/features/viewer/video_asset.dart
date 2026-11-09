import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../app/app_controller.dart';
import '../../core/cloud/cloud_backend.dart';
import '../../core/ui/messages.dart';
import '../../models.dart';
import '../../shared/ui/media_tile.dart';

const _skip = Duration(seconds: 10);
const _speeds = [0.5, 1.0, 1.5, 2.0];

String formatPlaybackTime(Duration value) {
  final h = value.inHours;
  final m = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// A video with a seek bar, skip by double-tapping either side, playback
/// speed and replay. Tapping shows or hides the controls through [onTap];
/// they stay visible while [controlsVisible] is set or the video is paused.
class VideoAsset extends StatefulWidget {
  const VideoAsset({
    super.key,
    required this.file,
    required this.controller,
    required this.active,
    required this.controlsVisible,
    required this.onTap,
  });

  final CloudFile file;
  final AppController controller;
  final bool active;
  final bool controlsVisible;
  final VoidCallback onTap;

  @override
  State<VideoAsset> createState() => _VideoAssetState();
}

class _VideoAssetState extends State<VideoAsset> with WidgetsBindingObserver {
  VideoPlayerController? _player;
  bool _loading = false;
  bool _offline = false;
  bool _saving = false;
  String? _error;

  /// The position under the handle while it is being dragged.
  double? _dragging;
  bool _resumeAfterDrag = false;
  double _speed = 1;
  Offset _doubleTap = Offset.zero;
  int _skipDirection = 0;
  Timer? _skipHint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoplay();
  }

  void _autoplay() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && widget.active && _player == null && !_loading) _play();
  });

  @override
  void didUpdateWidget(VideoAsset oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) {
      _player?.pause();
    } else if (!oldWidget.active) {
      _autoplay();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _player?.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _skipHint?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _play({bool preferStream = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    VideoPlayerController? player;
    try {
      final playback = await widget.controller.preparePlayback(
        widget.file,
        preferStream: preferStream,
      );
      final copy = playback.offline;
      final source = playback.source;
      if (!mounted) return;
      if (copy != null) {
        player = VideoPlayerController.file(copy);
      } else if (source != null) {
        player = VideoPlayerController.networkUrl(
          source.uri,
          httpHeaders: source.headers,
        );
      } else {
        throw const CloudException('Reconnect to stream this video.');
      }
      await player.initialize().timeout(const Duration(seconds: 45));
      if (!mounted) {
        await player.dispose();
        return;
      }
      await _player?.dispose();
      _player = player;
      _offline = copy != null;
      await player.setLooping(false);
      await player.setPlaybackSpeed(_speed);
      if (widget.active) await player.play();
    } catch (e) {
      await player?.dispose();
      if (identical(_player, player)) _player = null;
      if (mounted) {
        _error = e is CloudException
            ? e.message
            : 'This video could not be streamed. The format may be unsupported '
                  'on this device — save it offline or open it in another app.';
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveOffline() async {
    setState(() => _saving = true);
    try {
      await widget.controller.saveOffline(widget.file);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved for offline replay')));
      final resume = _player?.value.position;
      await _play();
      if (resume != null) await _player?.seekTo(resume);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool _ended(VideoPlayerValue value) =>
      value.duration > Duration.zero &&
      value.position >= value.duration &&
      !value.isPlaying;

  Future<void> _togglePlay(VideoPlayerController player) async {
    final value = player.value;
    if (value.isPlaying) return player.pause();
    if (_ended(value)) await player.seekTo(Duration.zero);
    await player.play();
  }

  Future<void> _skipBy(VideoPlayerController player, int direction) async {
    final value = player.value;
    final target = value.position + _skip * direction;
    await player.seekTo(
      target < Duration.zero
          ? Duration.zero
          : target > value.duration
          ? value.duration
          : target,
    );
    _skipHint?.cancel();
    setState(() => _skipDirection = direction);
    _skipHint = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _skipDirection = 0);
    });
  }

  void _onDoubleTap(VideoPlayerController player, double width) {
    if (!widget.active) return;
    final third = width / 3;
    if (_doubleTap.dx < third) {
      _skipBy(player, -1);
    } else if (_doubleTap.dx > width - third) {
      _skipBy(player, 1);
    } else {
      _togglePlay(player);
    }
  }

  void _seekStarted(VideoPlayerController player) {
    _resumeAfterDrag = player.value.isPlaying;
    if (_resumeAfterDrag) player.pause();
  }

  Future<void> _seekEnded(VideoPlayerController player, double value) async {
    await player.seekTo(Duration(milliseconds: value.round()));
    setState(() => _dragging = null);
    if (_resumeAfterDrag) await player.play();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (player == null || !player.value.isInitialized) return _poster();
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, value, _) {
        final showControls =
            widget.controlsVisible || !value.isPlaying || _dragging != null;
        return LayoutBuilder(
          builder: (context, box) => Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onTap,
                  onDoubleTapDown: (d) => _doubleTap = d.localPosition,
                  onDoubleTap: () => _onDoubleTap(player, box.maxWidth),
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: value.aspectRatio,
                      child: VideoPlayer(player),
                    ),
                  ),
                ),
              ),
              if (_skipDirection != 0) _skipIndicator(),
              if (value.isBuffering)
                const IgnorePointer(
                  child: CircularProgressIndicator(color: Colors.white),
                )
              else if (showControls)
                _centerButton(player, value),
              if (showControls) _controlBar(player, value),
            ],
          ),
        );
      },
    );
  }

  Widget _centerButton(VideoPlayerController player, VideoPlayerValue value) {
    final ended = _ended(value);
    return IconButton.filled(
      iconSize: 44,
      style: IconButton.styleFrom(backgroundColor: Colors.black54),
      tooltip: ended
          ? 'Replay video'
          : value.isPlaying
          ? 'Pause video'
          : 'Play video',
      onPressed: widget.active ? () => _togglePlay(player) : null,
      icon: Icon(
        ended
            ? Icons.replay_rounded
            : value.isPlaying
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded,
      ),
    );
  }

  Widget _skipIndicator() => Positioned(
    left: _skipDirection < 0 ? 32 : null,
    right: _skipDirection > 0 ? 32 : null,
    child: IgnorePointer(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: const BoxDecoration(
          color: Colors.black54,
          shape: BoxShape.circle,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _skipDirection < 0
                  ? Icons.fast_rewind_rounded
                  : Icons.fast_forward_rounded,
              color: Colors.white,
            ),
            const Text(
              '10 s',
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _controlBar(VideoPlayerController player, VideoPlayerValue value) {
    final total = value.duration.inMilliseconds.toDouble();
    final position = (_dragging ?? value.position.inMilliseconds.toDouble())
        .clamp(0, total > 0 ? total : 1)
        .toDouble();
    const style = TextStyle(color: Colors.white, fontSize: 12);
    return Positioned(
      left: 8,
      right: 8,
      bottom: 96 + MediaQuery.paddingOf(context).bottom,
      child: Material(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Text(
                formatPlaybackTime(Duration(milliseconds: position.round())),
                style: style,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 18,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: position,
                    max: total > 0 ? total : 1,
                    semanticFormatterCallback: (v) =>
                        formatPlaybackTime(Duration(milliseconds: v.round())),
                    onChangeStart: widget.active && total > 0
                        ? (_) => _seekStarted(player)
                        : null,
                    onChanged: widget.active && total > 0
                        ? (v) => setState(() => _dragging = v)
                        : null,
                    onChangeEnd: widget.active && total > 0
                        ? (v) => _seekEnded(player, v)
                        : null,
                  ),
                ),
              ),
              Text(formatPlaybackTime(value.duration), style: style),
              PopupMenuButton<double>(
                tooltip: 'Playback speed',
                initialValue: _speed,
                onSelected: (speed) {
                  setState(() => _speed = speed);
                  player.setPlaybackSpeed(speed);
                },
                itemBuilder: (_) => [
                  for (final speed in _speeds)
                    PopupMenuItem(value: speed, child: Text('$speed×')),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Text('$_speed×', style: style),
                ),
              ),
              IconButton(
                tooltip: value.volume == 0 ? 'Unmute' : 'Mute',
                color: Colors.white,
                onPressed: () => player.setVolume(value.volume == 0 ? 1 : 0),
                icon: Icon(
                  value.volume == 0
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                ),
              ),
              if (_offline)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Tooltip(
                    message: 'Playing offline copy',
                    child: Icon(
                      Icons.offline_pin_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                )
              else if (_saving)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                )
              else
                IconButton(
                  tooltip: 'Save offline',
                  color: Colors.white,
                  onPressed: widget.controller.busy ? null : _saveOffline,
                  icon: const Icon(Icons.download_for_offline_outlined),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// What shows before the video is ready: its preview, with a play button,
  /// a spinner, or why it could not start.
  Widget _poster() => Stack(
    alignment: Alignment.center,
    children: [
      Positioned.fill(
        child: MediaTile(
          file: widget.file,
          controller: widget.controller,
          previewSize: 1280,
        ),
      ),
      Positioned.fill(child: Container(color: Colors.black38)),
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading)
              const CircularProgressIndicator(color: Colors.white)
            else
              IconButton.filled(
                iconSize: 48,
                tooltip: 'Play video',
                onPressed: widget.active ? _play : null,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            if (_error case final error?) ...[
              const SizedBox(height: 16),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: _saving || widget.controller.busy
                    ? null
                    : _saveOffline,
                icon: const Icon(Icons.download_for_offline_outlined),
                label: Text(_saving ? 'Saving…' : 'Save offline & play'),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}
