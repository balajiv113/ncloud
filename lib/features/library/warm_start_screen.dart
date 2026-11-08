import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../shared/ui/media_tile.dart';

/// Library preparation for new and previously unprepared saved sessions.
class WarmStartScreen extends StatelessWidget {
  const WarmStartScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mosaic = c.items.where((f) => f.isMedia).take(12).toList();
    Widget step(int phase, String label, String detail) {
      final done = c.warmPhase > phase;
      final running = c.warmPhase == phase;
      final color = done
          ? Colors.green.shade700
          : running
          ? colors.primary
          : colors.outline;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(
              done
                  ? Icons.check_circle
                  : running
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                detail.isEmpty ? label : '$label · $detail',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: running ? FontWeight.w600 : null,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.surface, colors.primaryContainer.withAlpha(90)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Icon(
                        Icons.photo_library_outlined,
                        color: colors.onPrimary,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Preparing your library',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Preparing up to the last ${AppController.warmYears} years '
                      'and recent thumbnails.\nYour cached library is reused '
                      'the next time you open the app.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 24),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: c.warmProgress),
                        duration: const Duration(milliseconds: 300),
                        builder: (context, value, _) =>
                            LinearProgressIndicator(value: value, minHeight: 6),
                      ),
                    ),
                    const SizedBox(height: 16),
                    step(0, 'Day index', c.warmIndex),
                    step(
                      1,
                      'Recent ${AppController.warmYears} years',
                      c.warmTotal == 0 ? '' : '${c.warmDone} / ${c.warmTotal}',
                    ),
                    step(2, 'First screens of thumbnails', ''),
                    if (mosaic.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: GridView.count(
                          crossAxisCount: 4,
                          shrinkWrap: true,
                          mainAxisSpacing: 2,
                          crossAxisSpacing: 2,
                          physics: const NeverScrollableScrollPhysics(),
                          children: [
                            for (final file in mosaic)
                              MediaTile(
                                key: ValueKey(file.id ?? file.key),
                                controller: c,
                                file: file,
                              ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: c.skipWarmUp,
                      child: const Text('Start browsing now'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Continues quietly in the background · '
                      'at most ${AppController.warmBudget.inSeconds} s here',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
