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
  });
  final CloudFile file;
  final AppController controller;
  final BoxFit fit;

  @override
  State<MediaTile> createState() => _MediaTileState();
}

class _MediaTileState extends State<MediaTile> {
  Future<Uint8List>? _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MediaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.key != widget.file.key) _load();
  }

  void _load({bool retry = false}) {
    if (widget.file.demoColor == null && widget.file.id != null) {
      _preview = widget.controller.preview(widget.file, retry: retry);
    }
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
    return FutureBuilder<Uint8List>(
      future: _preview,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return InkWell(
            onTap: () => setState(() => _load(retry: true)),
            child: _fallback(context, 'Preview unavailable. Tap to retry.'),
          );
        }
        if (snapshot.data case final bytes?) {
          return Image.memory(
            bytes,
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _fallback(context, 'Unsupported preview'),
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
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.file.isVideo ? Icons.videocam_outlined : Icons.image_outlined),
                const SizedBox(height: 4),
                Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
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
    canvas.drawRect(rect, Paint()..shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color.lerp(color, Colors.white, .55)!, color],
    ).createShader(rect));
    final sunX = size.width * (.25 + (seed.abs() % 40) / 100);
    canvas.drawCircle(Offset(sunX, size.height * .25), size.shortestSide * .12,
        Paint()..color = const Color(0xFFFFE6B8));
    for (var layer = 0; layer < 3; layer++) {
      final path = Path()..moveTo(0, size.height);
      for (var i = 0; i <= 6; i++) {
        final height = .45 + layer * .14 + ((seed.abs() + i * 7) % 17) / 100;
        path.lineTo(size.width * i / 6, size.height * height);
      }
      path..lineTo(size.width, size.height)..close();
      canvas.drawPath(path, Paint()..color = Color.lerp(color, const Color(0xFF102E30), layer * .23)!);
    }
  }

  @override
  bool shouldRepaint(LandscapePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.seed != seed;
}
