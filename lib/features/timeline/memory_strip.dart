import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../models.dart';
import '../../shared/ui/media_tile.dart';

/// The horizontal strip of memories above the Timeline: photos from this day
/// in earlier years and a few favorites.
class MemoryStrip extends StatelessWidget {
  const MemoryStrip({
    super.key,
    required this.groups,
    required this.controller,
    required this.onOpen,
  });

  final Map<String, List<CloudFile>> groups;
  final AppController controller;
  final void Function(CloudFile file, List<CloudFile> group) onOpen;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 124,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      children: [
        for (final entry in groups.entries)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Semantics(
              button: true,
              label: entry.key,
              child: GestureDetector(
                onTap: () => onOpen(entry.value.first, entry.value),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: SizedBox(
                    width: 164,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ExcludeSemantics(
                          child: MediaTile(
                            file: entry.value.first,
                            controller: controller,
                          ),
                        ),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.center,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black87],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          right: 10,
                          bottom: 10,
                          child: Text(
                            entry.key,
                            maxLines: 2,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
