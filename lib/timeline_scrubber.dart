import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Google Photos-style fast scroller: a thumb on the right edge that can be
/// dragged across the whole library, with the month under the thumb and year
/// markers along the track. Indexed timelines lay out every day up front, so
/// dragging lands anywhere and the photos there load on demand.
class TimelineScrubber extends StatefulWidget {
  const TimelineScrubber({
    super.key,
    required this.controller,
    required this.labelAt,
    required this.markers,
  });

  final ScrollController controller;
  final String? Function(double offset) labelAt;
  final List<({double offset, String label})> Function() markers;

  @override
  State<TimelineScrubber> createState() => TimelineScrubberState();
}

class TimelineScrubberState extends State<TimelineScrubber> {
  static const _thumbHeight = 48.0;
  bool _active = false;
  bool _dragging = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrolled);
    _refreshAfterLayout();
  }

  @override
  void didUpdateWidget(TimelineScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scrolled);
      widget.controller.addListener(_scrolled);
    }
    _refreshAfterLayout();
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.controller.removeListener(_scrolled);
    super.dispose();
  }

  void _scrolled() {
    if (!mounted) return;
    setState(() => _active = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && !_dragging) setState(() => _active = false);
    });
  }

  void _startDrag(DragStartDetails details, double track) {
    _hide?.cancel();
    setState(() => _dragging = true);
    HapticFeedback.selectionClick();
    _seek(details.globalPosition, track);
  }

  void _endDrag() {
    setState(() => _dragging = false);
    _scheduleHide();
  }

  void _refreshAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _seek(Offset global, double track) {
    final controller = widget.controller;
    final box = context.findRenderObject() as RenderBox?;
    if (!controller.hasClients || box == null || track <= 0) return;
    final local = box.globalToLocal(global);
    final fraction = ((local.dy - _thumbHeight / 2) / track).clamp(0.0, 1.0);
    controller.jumpTo(fraction * controller.position.maxScrollExtent);
  }

  double _stepOffset(int direction) {
    final position = widget.controller.position;
    return (position.pixels + direction * position.viewportDimension).clamp(
      0.0,
      position.maxScrollExtent,
    );
  }

  String _describe(double offset) =>
      widget.labelAt(offset) ??
      '${(offset / widget.controller.position.maxScrollExtent * 100).round()}%';

  void _step(int direction) => widget.controller.jumpTo(_stepOffset(direction));

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      return const SizedBox.shrink();
    }
    final position = controller.position;
    final max = position.maxScrollExtent;
    if (max < position.viewportDimension * 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final track = constraints.maxHeight - _thumbHeight;
        final fraction = (position.pixels / max).clamp(0.0, 1.0);
        final label = _dragging ? widget.labelAt(position.pixels) : null;
        final markers = <Widget>[];
        if (_dragging) {
          var last = -100.0;
          for (final marker in widget.markers()) {
            final top =
                (marker.offset / max).clamp(0.0, 1.0) * track +
                _thumbHeight / 2 -
                8;
            if (top - last < 22) continue;
            last = top;
            markers.add(
              Positioned(
                right: 52,
                top: top,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: .9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(marker.label, style: theme.textTheme.labelSmall),
                ),
              ),
            );
          }
        }
        return Semantics(
          label: 'Scrub timeline by date',
          slider: true,
          excludeSemantics: true,
          value: _describe(position.pixels),
          increasedValue: position.pixels < max
              ? _describe(_stepOffset(1))
              : null,
          decreasedValue: position.pixels > 0
              ? _describe(_stepOffset(-1))
              : null,
          onIncrease: position.pixels < max ? () => _step(1) : null,
          onDecrease: position.pixels > 0 ? () => _step(-1) : null,
          child: Stack(
            children: [
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 24,
                child: GestureDetector(
                  key: const ValueKey('timeline-scrubber-edge'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) {
                    setState(() => _active = true);
                    _scheduleHide();
                  },
                  onVerticalDragStart: (details) => _startDrag(details, track),
                  onVerticalDragUpdate: (details) =>
                      _seek(details.globalPosition, track),
                  onVerticalDragEnd: (_) => _endDrag(),
                  onVerticalDragCancel: _endDrag,
                ),
              ),
              IgnorePointer(
                ignoring: !_active && !_dragging,
                child: AnimatedOpacity(
                  key: const ValueKey('timeline-scrubber-visibility'),
                  opacity: _active || _dragging ? 1 : 0,
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  child: Stack(
                    children: [
                      ...markers,
                      Positioned(
                        right: 0,
                        top: fraction * track,
                        height: _thumbHeight,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (label != null)
                              Material(
                                color: theme.colorScheme.inverseSurface,
                                borderRadius: BorderRadius.circular(20),
                                elevation: 3,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 9,
                                  ),
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onInverseSurface,
                                    ),
                                  ),
                                ),
                              ),
                            Semantics(
                              label: 'Scrub timeline by date',
                              slider: true,
                              child: GestureDetector(
                                key: const ValueKey('timeline-scrubber'),
                                behavior: HitTestBehavior.opaque,
                                onVerticalDragStart: (details) {
                                  _startDrag(details, track);
                                },
                                onVerticalDragUpdate: (details) =>
                                    _seek(details.globalPosition, track),
                                onVerticalDragEnd: (_) => _endDrag(),
                                onVerticalDragCancel: _endDrag,
                                child: SizedBox(
                                  width: 48,
                                  height: _thumbHeight,
                                  child: Center(
                                    child: Container(
                                      width: 34,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: theme
                                            .colorScheme
                                            .secondaryContainer,
                                        borderRadius:
                                            const BorderRadius.horizontal(
                                              left: Radius.circular(22),
                                            ),
                                        boxShadow: const [
                                          BoxShadow(
                                            blurRadius: 6,
                                            color: Color(0x33000000),
                                          ),
                                        ],
                                      ),
                                      child: Icon(
                                        Icons.unfold_more,
                                        size: 20,
                                        color: theme
                                            .colorScheme
                                            .onSecondaryContainer,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
