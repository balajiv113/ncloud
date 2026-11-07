import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../models.dart';

class MediaTile extends StatefulWidget {
  const MediaTile({
    super.key,
    required this.file,
    required this.controller,
    this.fit = BoxFit.cover,
    this.previewSize = 384,
  });
  final CloudFile file;
  final AppController controller;
  final BoxFit fit;
  final int previewSize;

  @override
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  Uint8List? _bytes;
  File? _original;
  bool _failed = false;
  bool _instant = false;
  bool _waiting = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MediaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.key != widget.file.key ||
        oldWidget.file.modified != widget.file.modified ||
        oldWidget.file.size != widget.file.size ||
        oldWidget.file.id != widget.file.id ||
        oldWidget.file.etag != widget.file.etag ||
        oldWidget.previewSize != widget.previewSize ||
        oldWidget.controller != widget.controller) {
      _release(oldWidget);
      _load(keep: oldWidget.file.key == widget.file.key);
    }
  }

  @override
  void dispose() {
    _release(widget);
    super.dispose();
  }

  void _release(MediaTile tile) {
    if (!_waiting) return;
    _waiting = false;
    tile.controller.releasePreview(tile.file, size: tile.previewSize);
  }

  /// Paints any cached thumbnail immediately, then fetches only if it is
  /// missing or from an older revision of the file.
  void _load({bool retry = false, bool keep = false}) {
    if (widget.file.demoColor != null) return;
    final generation = ++_generation;
    final c = widget.controller;
    final cached = c.cachedPreview(widget.file, size: widget.previewSize);
    final thumbnail = widget.previewSize > 384
        ? c.cachedPreview(widget.file)
        : null;
    _bytes = cached ?? thumbnail ?? (keep ? _bytes : null);
    _instant = _bytes != null;
    _failed = false;
    _original = null;
    if (!retry &&
        cached != null &&
        c.previewCurrent(widget.file, size: widget.previewSize)) {
      return;
    }
    if (!retry && cached == null && widget.file.isImage && c.cache != null) {
      // A saved original replays without any network request.
      c.offlineCopy(widget.file).then((copy) {
        if (!mounted || generation != _generation) return;
        if (copy != null) {
          setState(() => _original = copy);
        } else {
          _request(generation, retry);
        }
      });
      return;
    }
    _request(generation, retry);
  }

  void _request(int generation, bool retry) {
    final c = widget.controller;
    _waiting = true;
    c
        .preview(
          widget.file,
          retry: retry,
          size: widget.previewSize,
          stale: (bytes) {
            if (mounted && generation == _generation && _bytes == null) {
              setState(() => _bytes = bytes);
            }
          },
        )
        .then(
          (bytes) {
            if (!mounted || generation != _generation) return;
            _waiting = false;
            if (!identical(bytes, _bytes)) setState(() => _bytes = bytes);
          },
          onError: (Object error) {
            if (!mounted || generation != _generation) return;
            _waiting = false;
            if (error is PreviewCancelled) {
              _load();
            } else if (_bytes == null) {
              _useOffline(generation);
            }
          },
        );
  }

  Future<void> _useOffline(int generation) async {
    final original = widget.file.isImage
        ? await widget.controller.offlineCopy(widget.file)
        : null;
    if (!mounted || generation != _generation) return;
    setState(() {
      _original = original;
      _failed = original == null;
    });
  }

  void _retry() => setState(() => _load(retry: true));

  @override
  Widget build(BuildContext context) {
    if (widget.file.demoColor case final color?) {
      return CustomPaint(
        painter: LandscapePainter(Color(color), widget.file.name.hashCode),
        child: const SizedBox.expand(),
      );
    }
    final placeholder = _placeholder(context);
    if (_failed) {
      return InkWell(
        onTap: _retry,
        child: _fallback(context, 'Preview unavailable. Tap to retry.'),
      );
    }
    final ImageProvider? image = _original != null
        ? FileImage(_original!)
        : _bytes != null
        ? MemoryImage(_bytes!)
        : null;
    if (image == null) return placeholder;
    final instant =
        _instant || MediaQuery.maybeDisableAnimationsOf(context) == true;
    return Stack(
      fit: StackFit.expand,
      children: [
        placeholder,
        Image(
          image: ResizeImage(
            image,
            width: widget.previewSize,
            height: widget.previewSize,
            policy: ResizeImagePolicy.fit,
          ),
          fit: widget.fit,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, synchronous) =>
              synchronous || instant
              ? child
              : AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 180),
                  child: child,
                ),
          errorBuilder: (_, _, _) => InkWell(
            onTap: _retry,
            child: _fallback(context, 'Unsupported preview. Tap to retry.'),
          ),
        ),
      ],
    );
  }

  /// Calm tinted tile shown until a thumbnail arrives; never a spinner.
  Widget _placeholder(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = [
      colors.surfaceContainerHighest,
      colors.surfaceContainerHigh,
      colors.surfaceContainer,
    ][widget.file.key.hashCode.abs() % 3];
    return ColoredBox(color: tint);
  }

  Widget _fallback(BuildContext context, String label) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final icon = Icon(
          widget.file.isVideo ? Icons.videocam_outlined : Icons.image_outlined,
        );
        if (constraints.maxWidth < 88 || constraints.maxHeight < 88) {
          return Center(
            child: Tooltip(message: label, child: icon),
          );
        }
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(height: 4),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class LandscapePainter extends CustomPainter {
  LandscapePainter(this.color, this.seed);
  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(color, Colors.white, .55)!, color],
        ).createShader(rect),
    );
    final sunX = size.width * (.25 + (seed.abs() % 40) / 100);
    canvas.drawCircle(
      Offset(sunX, size.height * .25),
      size.shortestSide * .12,
      Paint()..color = const Color(0xFFFFE6B8),
    );
    for (var layer = 0; layer < 3; layer++) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i <= 6; i++) {
        final height = .45 + layer * .14 + ((seed.abs() + i * 7) % 17) / 100;
        path.lineTo(size.width * i / 6, size.height * height);
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(color, const Color(0xFF102E30), layer * .23)!,
      );
    }
  }

  @override
  bool shouldRepaint(LandscapePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.seed != seed;
}
