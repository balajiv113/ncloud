import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../models.dart';
import '../../shared/ui/media_tile.dart';

/// A photo or video in a grid: its thumbnail with selection, favorite and
/// video marks. It zooms into the viewer through a shared [Hero].
class MediaGridTile extends StatelessWidget {
  const MediaGridTile({
    super.key,
    required this.file,
    required this.controller,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final CloudFile file;
  final AppController controller;
  final bool selected;

  /// Whether any file is selected, which shows every tile's check mark.
  final bool selecting;
  final VoidCallback onTap;

  /// Null for files that cannot be selected, such as read-only album members.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: file.name,
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.all(selected ? 6 : 0),
          color: colors.primaryContainer,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Hero(
                tag: 'asset:${file.key}',
                child: MediaTile(
                  key: ValueKey(file.key),
                  file: file,
                  controller: controller,
                ),
              ),
              if (selecting && !file.readOnly)
                Positioned(
                  top: 5,
                  left: 5,
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: selected ? colors.primary : Colors.white,
                    size: 22,
                  ),
                ),
              if (file.favorite)
                const Positioned(
                  bottom: 6,
                  right: 6,
                  child: Icon(Icons.favorite, color: Colors.white, size: 14),
                ),
              if (file.isLive && !file.isVideo)
                const Positioned(
                  bottom: 5,
                  left: 5,
                  child: Icon(
                    Icons.motion_photos_on_outlined,
                    color: Colors.white,
                    size: 17,
                    semanticLabel: 'Live Photo',
                  ),
                ),
              if (file.isVideo)
                const Positioned(
                  bottom: 5,
                  left: 5,
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 21,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
