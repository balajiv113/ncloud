import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../models.dart';
import 'phone_badge.dart';
import 'phone_thumbnails.dart';

/// A photo that is only on the phone, in a grid: its thumbnail from the phone,
/// with its backup state marked in the corner.
class PhoneTile extends StatefulWidget {
  const PhoneTile({
    super.key,
    required this.file,
    required this.thumbnails,
    this.size = 384,
    this.fit = BoxFit.cover,
  });

  final CloudFile file;
  final PhoneThumbnails thumbnails;
  final int size;
  final BoxFit fit;

  @override
  State<PhoneTile> createState() => _PhoneTileState();
}

class _PhoneTileState extends State<PhoneTile> {
  late Future<Uint8List?> _thumbnail = _ask();

  Future<Uint8List?> _ask() =>
      widget.thumbnails.of(widget.file.onPhone!.id, widget.size);

  @override
  void didUpdateWidget(PhoneTile old) {
    super.didUpdateWidget(old);
    if (old.file.onPhone!.id != widget.file.onPhone!.id ||
        old.size != widget.size) {
      _thumbnail = _ask();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: colors.surfaceContainerHigh),
        FutureBuilder<Uint8List?>(
          future: _thumbnail,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) {
              return snapshot.connectionState == ConnectionState.done
                  ? Icon(
                      widget.file.isVideo
                          ? Icons.videocam_outlined
                          : Icons.image_outlined,
                    )
                  : const SizedBox.shrink();
            }
            return Image.memory(
              bytes,
              fit: widget.fit,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            );
          },
        ),
        Positioned(
          top: 5,
          right: 5,
          child: PhoneBadge(widget.file.onPhone!.state),
        ),
      ],
    );
  }
}
