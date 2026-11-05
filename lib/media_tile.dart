import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'models.dart';

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
  Future<({File? original, Uint8List? bytes})>? _preview;

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
        oldWidget.previewSize != widget.previewSize ||
        oldWidget.controller != widget.controller) {
      _preview = null;
      _load();
    }
  }

  void _load({bool retry = false}) {
    if (widget.file.demoColor == null) {
      _preview = _source(retry);
    }
  }

  Future<({File? original, Uint8List? bytes})> _source(bool retry) async {
    if (widget.file.isImage) {
      final original = await widget.controller.offlineCopy(widget.file);
      if (original != null) return (original: original, bytes: null);
    }
    return (
      original: null,
      bytes: await widget.controller.preview(
        widget.file,
        retry: retry,
        size: widget.previewSize,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.file.demoColor case final color?) {
      return CustomPaint(
        painter: LandscapePainter(Color(color), widget.file.name.hashCode),
        child: const SizedBox.expand(),
      );
    }
    if (_preview == null) return _fallback(context, 'Preview unavailable');
    return FutureBuilder<({File? original, Uint8List? bytes})>(
      future: _preview,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return InkWell(
            onTap: () => setState(() => _load(retry: true)),
            child: _fallback(context, 'Preview unavailable. Tap to retry.'),
          );
        }
        if (snapshot.data case final source?) {
          final ImageProvider image = source.original != null
              ? FileImage(source.original!)
              : MemoryImage(source.bytes!);
          return Image(
            image: ResizeImage(
              image,
              width: widget.previewSize,
              height: widget.previewSize,
              policy: ResizeImagePolicy.fit,
            ),
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => InkWell(
              onTap: () => setState(() => _load(retry: true)),
              child: _fallback(context, 'Unsupported preview. Tap to retry.'),
            ),
          );
        }
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        );
      },
    );
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
