import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'app_controller.dart';
import 'library_actions.dart';
import 'media_tile.dart';
import 'models.dart';
import 'screens.dart';

class AssetViewer extends StatefulWidget {
  const AssetViewer({
    super.key,
    required this.files,
    required this.initialIndex,
    required this.controller,
  });
  final List<CloudFile> files;
  final int initialIndex;
  final AppController controller;
  @override
  State<AssetViewer> createState() => _AssetViewerState();
}

class _AssetViewerState extends State<AssetViewer> with WidgetsBindingObserver {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late final _files = [...widget.files];
  late int _index = widget.initialIndex;
  bool _chrome = true;
  Timer? _slideshow;
  CloudFile get _file => _files[_index];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _slideshow != null) {
      _slideshow?.cancel();
      setState(() => _slideshow = null);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slideshow?.cancel();
    _pages.dispose();
    super.dispose();
  }

  void _toggleSlideshow() {
    if (_slideshow != null) {
      _slideshow!.cancel();
      setState(() => _slideshow = null);
      return;
    }
    setState(() {
      _chrome = false;
      _slideshow = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted) {
          _pages.animateToPage(
            (_index + 1) % _files.length,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeInOutCubic,
          );
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: ThemeData.dark(useMaterial3: true),
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: PageView.builder(
                controller: _pages,
                itemCount: _files.length,
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (_, index) => _files[index].isVideo
                    ? VideoAsset(
                        key: ValueKey(_files[index].key),
                        file: _files[index],
                        controller: widget.controller,
                        active: index == _index && _slideshow == null,
                      )
                    : ZoomAsset(
                        file: _files[index],
                        controller: widget.controller,
                        onTap: () => setState(() => _chrome = !_chrome),
                      ),
              ),
            ),
            if (_chrome)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 36),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Back to library',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.arrow_back_rounded),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _file.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '${_index + 1} of ${_files.length}',
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Slideshow',
                            onPressed: _files.length < 2
                                ? null
                                : _toggleSlideshow,
                            icon: const Icon(Icons.slideshow_outlined),
                          ),
                          IconButton(
                            tooltip: 'Details & organize',
                            onPressed: widget.controller.busy
                                ? null
                                : () async {
                                    final key = _file.key;
                                    await fileActions(
                                      context,
                                      widget.controller,
                                      _file,
                                    );
                                    if (!context.mounted) return;
                                    final updated = widget.controller.items
                                        .where((f) => f.key == key)
                                        .firstOrNull;
                                    if (updated != null) {
                                      setState(() => _files[_index] = updated);
                                    } else {
                                      Navigator.pop(context);
                                    }
                                  },
                            icon: const Icon(Icons.more_horiz),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_chrome)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 36, 16, 12),
                      child: Column(
                        children: [
                          Text(
                            widget.controller.demo
                                ? 'Demo illustration'
                                : _file.isVideo
                                ? 'Original video · downloaded securely to play'
                                : 'Server preview · original available below',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton.filledTonal(
                                tooltip: _file.favorite
                                    ? 'Remove favorite'
                                    : 'Add favorite',
                                onPressed: widget.controller.busy
                                    ? null
                                    : () async {
                                        final index = _index;
                                        final file = _files[index];
                                        if (await widget.controller.organize(
                                              [file],
                                              'favorite',
                                              favorite: !file.favorite,
                                            ) &&
                                            mounted) {
                                          setState(
                                            () => _files[index] = file
                                                .withFavorite(!file.favorite),
                                          );
                                        }
                                      },
                                icon: Icon(
                                  _file.favorite
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Share link',
                                onPressed: () => showModalBottomSheet<void>(
                                  context: context,
                                  showDragHandle: true,
                                  isScrollControlled: true,
                                  builder: (_) => SharePanel(
                                    controller: widget.controller,
                                    file: _file,
                                  ),
                                ),
                                icon: const Icon(Icons.link),
                              ),
                              IconButton(
                                tooltip: 'Download original & share',
                                onPressed: widget.controller.busy
                                    ? null
                                    : () => shareFile(
                                        context,
                                        widget.controller,
                                        _file,
                                      ),
                                icon: const Icon(Icons.ios_share),
                              ),
                              IconButton(
                                tooltip: 'Delete',
                                onPressed: widget.controller.busy
                                    ? null
                                    : () async {
                                        if (await confirmDelete(context, [
                                              _file,
                                            ]) &&
                                            await widget.controller.organize([
                                              _file,
                                            ], 'delete') &&
                                            context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      },
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                          if (widget.controller.error case final error?)
                            Text(
                              error,
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                              ),
                            ),
                          if (widget.controller.busy)
                            const LinearProgressIndicator(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (!_chrome)
              Positioned(
                top: 0,
                right: 8,
                child: SafeArea(
                  child: IconButton(
                    tooltip: _slideshow == null
                        ? 'Show controls'
                        : 'Stop slideshow',
                    onPressed: () {
                      _slideshow?.cancel();
                      setState(() {
                        _slideshow = null;
                        _chrome = true;
                      });
                    },
                    icon: Icon(
                      _slideshow == null
                          ? Icons.more_horiz
                          : Icons.pause_circle_outline,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class ZoomAsset extends StatefulWidget {
  const ZoomAsset({
    super.key,
    required this.file,
    required this.controller,
    required this.onTap,
  });
  final CloudFile file;
  final AppController controller;
  final VoidCallback onTap;
  @override
  State<ZoomAsset> createState() => _ZoomAssetState();
}

class _ZoomAssetState extends State<ZoomAsset> {
  final _transform = TransformationController();
  bool _zoomed = false;
  Offset _doubleTapPosition = Offset.zero;
  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
    onDoubleTap: () => setState(() {
      _zoomed = !_zoomed;
      _transform.value = _zoomed
          ? (Matrix4.translationValues(
              -_doubleTapPosition.dx,
              -_doubleTapPosition.dy,
              0,
            )..multiply(Matrix4.diagonal3Values(2, 2, 1)))
          : Matrix4.identity();
    }),
    child: InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: 5,
      child: Center(
        child: Hero(
          tag: 'asset:${widget.file.key}',
          child: AspectRatio(
            aspectRatio: 1,
            child: MediaTile(
              file: widget.file,
              controller: widget.controller,
              fit: BoxFit.contain,
              previewSize: 1280,
            ),
          ),
        ),
      ),
    ),
  );
}

class VideoAsset extends StatefulWidget {
  const VideoAsset({
    super.key,
    required this.file,
    required this.controller,
    required this.active,
  });
  final CloudFile file;
  final AppController controller;
  final bool active;
  @override
  State<VideoAsset> createState() => _VideoAssetState();
}

class _VideoAssetState extends State<VideoAsset> with WidgetsBindingObserver {
  VideoPlayerController? _player;
  bool _loading = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(VideoAsset oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) _player?.pause();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _player?.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    VideoPlayerController? player;
    try {
      final File file = await widget.controller.download(widget.file);
      if (!mounted) return;
      player = VideoPlayerController.file(file);
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      _player = player;
      if (widget.active) await player.play();
    } catch (e) {
      await player?.dispose();
      _player = null;
      if (mounted) _error = errorMessage(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    if (player != null && player.value.isInitialized) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: player.value.aspectRatio,
              child: VideoPlayer(player),
            ),
            VideoProgressIndicator(
              player,
              allowScrubbing: true,
              padding: const EdgeInsets.all(16),
            ),
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: player,
              builder: (_, value, _) => IconButton(
                tooltip: value.isPlaying ? 'Pause video' : 'Play video',
                onPressed: !widget.active
                    ? null
                    : () => value.isPlaying ? player.pause() : player.play(),
                icon: Icon(
                  value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                  size: 44,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 220,
            height: 220,
            child: MediaTile(file: widget.file, controller: widget.controller),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const CircularProgressIndicator()
          else
            FilledButton.icon(
              onPressed: !widget.active || widget.controller.busy
                  ? null
                  : _play,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Download & play'),
            ),
          const SizedBox(height: 12),
          Text(
            _error ?? 'Original video is cached locally for secure playback.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
