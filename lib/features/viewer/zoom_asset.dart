import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../models.dart';
import '../../shared/ui/media_tile.dart';

/// A photo that can be pinched, panned and double-tapped to zoom.
///
/// [onZoomChanged] reports when the photo leaves or returns to its fitted
/// size, so the page view around it can stop swiping while it is zoomed.
class ZoomAsset extends StatefulWidget {
  const ZoomAsset({
    super.key,
    required this.file,
    required this.controller,
    required this.onTap,
    this.onZoomChanged,
  });

  final CloudFile file;
  final AppController controller;
  final VoidCallback onTap;
  final ValueChanged<bool>? onZoomChanged;

  static const maxScale = 6.0;
  static const doubleTapScale = 2.5;

  @override
  State<ZoomAsset> createState() => _ZoomAssetState();
}

class _ZoomAssetState extends State<ZoomAsset>
    with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _animation;
  Offset _tap = Offset.zero;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _transform.addListener(_scaleChanged);
  }

  @override
  void dispose() {
    _animation.dispose();
    _transform
      ..removeListener(_scaleChanged)
      ..dispose();
    super.dispose();
  }

  void _scaleChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged?.call(zoomed);
  }

  void _toggleZoom() {
    final from = _transform.value;
    final to = _zoomed
        ? Matrix4.identity()
        : (Matrix4.translationValues(
            -_tap.dx * (ZoomAsset.doubleTapScale - 1),
            -_tap.dy * (ZoomAsset.doubleTapScale - 1),
            0,
          )..scaleByDouble(
            ZoomAsset.doubleTapScale,
            ZoomAsset.doubleTapScale,
            1,
            1,
          ));
    final tween = Matrix4Tween(begin: from, end: to);
    void step() => _transform.value = tween.evaluate(_animation);
    _animation
      ..removeListener(step)
      ..addListener(step)
      ..forward(from: 0).whenComplete(() => _animation.removeListener(step));
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    onDoubleTapDown: (details) => _tap = details.localPosition,
    onDoubleTap: _toggleZoom,
    child: InteractiveViewer(
      transformationController: _transform,
      maxScale: ZoomAsset.maxScale,
      child: SizedBox.expand(
        child: MediaTile(
          file: widget.file,
          controller: widget.controller,
          fit: BoxFit.contain,
          previewSize: 1280,
        ),
      ),
    ),
  );
}
