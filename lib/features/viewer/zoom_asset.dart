import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../models.dart';
import '../../shared/ui/media_tile.dart';

/// A photo from the cloud that can be pinched, panned and double-tapped to zoom.
class ZoomAsset extends StatelessWidget {
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

  static const maxScale = ZoomView.maxScale;
  static const doubleTapScale = ZoomView.doubleTapScale;

  @override
  Widget build(BuildContext context) => ZoomView(
    onTap: onTap,
    onZoomChanged: onZoomChanged,
    child: SizedBox.expand(
      child: MediaTile(
        file: file,
        controller: controller,
        fit: BoxFit.contain,
        previewSize: 1280,
      ),
    ),
  );
}

/// Anything that can be pinched, panned and double-tapped to zoom: the cloud's
/// photos and the phone's use the same one, so they behave the same.
///
/// [onZoomChanged] reports when the content leaves or returns to its fitted
/// size, so the page view around it can stop swiping while it is zoomed.
class ZoomView extends StatefulWidget {
  const ZoomView({
    super.key,
    required this.child,
    required this.onTap,
    this.onZoomChanged,
  });

  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<bool>? onZoomChanged;

  static const maxScale = 6.0;
  static const doubleTapScale = 2.5;

  @override
  State<ZoomView> createState() => _ZoomViewState();
}

class _ZoomViewState extends State<ZoomView>
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
            -_tap.dx * (ZoomView.doubleTapScale - 1),
            -_tap.dy * (ZoomView.doubleTapScale - 1),
            0,
          )..scaleByDouble(
            ZoomView.doubleTapScale,
            ZoomView.doubleTapScale,
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
      maxScale: ZoomView.maxScale,
      child: widget.child,
    ),
  );
}
