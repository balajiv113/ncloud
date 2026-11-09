import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../files/file_actions.dart';
import '../files/share_panel.dart';
import '../../models.dart';
import '../files/library_dialogs.dart';
import 'video_asset.dart';
import 'zoom_asset.dart';

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
  bool _zoomed = false;
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
                physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                onPageChanged: (value) => setState(() {
                  _index = value;
                  _zoomed = false;
                }),
                itemBuilder: (_, index) => _files[index].isVideo
                    ? VideoAsset(
                        key: ValueKey(_files[index].key),
                        file: _files[index],
                        controller: widget.controller,
                        active: index == _index && _slideshow == null,
                        controlsVisible: _chrome,
                        onTap: () => setState(() => _chrome = !_chrome),
                      )
                    : ZoomAsset(
                        file: _files[index],
                        controller: widget.controller,
                        onTap: () => setState(() => _chrome = !_chrome),
                        onZoomChanged: (zoomed) {
                          if (mounted && index == _index) {
                            setState(() => _zoomed = zoomed);
                          }
                        },
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
                            onPressed: widget.controller.busy || _file.readOnly
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
                            _file.isVideo
                                ? 'Video streams unless saved offline'
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
                                onPressed: _file.readOnly
                                    ? null
                                    : () => showModalBottomSheet<void>(
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
                                onPressed:
                                    widget.controller.busy || _file.readOnly
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
