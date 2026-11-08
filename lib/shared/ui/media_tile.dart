import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../features/library/domain/thumbnail_repository.dart';
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
  ThumbnailRequest? _request;
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
      _release();
      _load(keep: oldWidget.file.key == widget.file.key);
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    _request?.release();
    _request = null;
  }

  /// Paints any cached thumbnail immediately, then fetches only if it is
  /// missing or from an older revision of the file.
  void _load({bool retry = false, bool keep = false}) {
    final generation = ++_generation;
    final thumbnails = widget.controller.thumbnails;
    final file = widget.file;
    final size = widget.previewSize;
    _bytes = thumbnails.paintable(file, size: size) ?? (keep ? _bytes : null);
    _instant = _bytes != null;
    _failed = false;
    _original = null;
    if (!retry && thumbnails.current(file, size: size)) return;
    final request = thumbnails.load(
      file,
      size: size,
      retry: retry,
      stale: (bytes) {
        if (mounted && generation == _generation && _bytes == null) {
          setState(() => _bytes = bytes);
        }
      },
    );
    _request = request;
    request.result.then(
      (image) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _original = image.original;
          if (image.bytes != null) _bytes = image.bytes;
        });
      },
      onError: (Object error) {
        if (!mounted || generation != _generation) return;
        if (error is PreviewCancelled) {
          _load();
        } else if (_bytes == null) {
          setState(() => _failed = true);
        }
      },
    );
  }

  void _retry() => setState(() => _load(retry: true));

  @override
  Widget build(BuildContext context) {
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
