import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'domain/browse_target.dart';

/// The floating Timeline / Albums / Drive dock. Only the active destination
/// shows its label.
class NavigationDock extends StatelessWidget {
  const NavigationDock({
    super.key,
    required this.active,
    required this.busy,
    required this.onSelect,
  });

  /// The active bottom-bar destination.
  final Destination active;
  final bool busy;
  final ValueChanged<Destination> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final destinations = [
      (Destination.timeline, 'Timeline', Icons.photo_library_outlined),
      (Destination.albums, 'Albums', Icons.collections_bookmark_outlined),
      (Destination.drive, 'Drive', Icons.folder_outlined),
    ];
    final activeIndex = destinations.indexWhere((d) => d.$1 == active);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    final fullWidth = (MediaQuery.sizeOf(context).width - 40).clamp(0.0, 440.0);
    final width = fullWidth.clamp(0.0, 268.0);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 96,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AnimatedContainer(
              key: const ValueKey('navigation-dock'),
              duration: duration,
              curve: Curves.easeOutCubic,
              width: width,
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: .12),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Material(
                    color: colors.surface.withValues(alpha: .94),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                      side: BorderSide(
                        color: colors.outlineVariant.withValues(alpha: .5),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final selectedWidth = constraints.maxWidth * .46;
                          final otherWidth =
                              (constraints.maxWidth - selectedWidth) / 2;
                          return Stack(
                            children: [
                              AnimatedPositioned(
                                duration: duration,
                                curve: Curves.easeOutCubic,
                                left: activeIndex * otherWidth,
                                top: 0,
                                bottom: 0,
                                width: selectedWidth,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colors.primaryContainer,
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  for (final (destination, label, icon)
                                      in destinations)
                                    Expanded(
                                      flex: active == destination ? 46 : 27,
                                      child: Tooltip(
                                        message: label,
                                        child: Semantics(
                                          selected: destination == active,
                                          button: true,
                                          label: label,
                                          excludeSemantics: true,
                                          child: InkWell(
                                            key: ValueKey(
                                              'navigate-${destination.name}',
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              28,
                                            ),
                                            onTap: busy
                                                ? null
                                                : () => onSelect(destination),
                                            child: SizedBox.expand(
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    icon,
                                                    size: 21,
                                                    color: active == destination
                                                        ? colors
                                                              .onPrimaryContainer
                                                        : colors
                                                              .onSurfaceVariant,
                                                  ),
                                                  if (active ==
                                                      destination) ...[
                                                    const SizedBox(width: 6),
                                                    Flexible(
                                                      child: Text(
                                                        destination ==
                                                                Destination
                                                                    .timeline
                                                            ? 'Photos'
                                                            : label,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color:
                                                              active ==
                                                                  destination
                                                              ? colors
                                                                    .onPrimaryContainer
                                                              : colors
                                                                    .onSurfaceVariant,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
