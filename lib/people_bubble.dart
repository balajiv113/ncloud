import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'discovery_models.dart';

class PeopleBubble extends StatefulWidget {
  const PeopleBubble({
    super.key,
    required this.person,
    required this.controller,
    required this.onTap,
    this.diameter = 72,
  });

  final RecognizedPerson person;
  final AppController controller;
  final VoidCallback onTap;
  final double diameter;

  @override
  State<PeopleBubble> createState() => _PeopleBubbleState();
}

class _PeopleBubbleState extends State<PeopleBubble> {
  Uint8List? _bytes;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PeopleBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.person != widget.person ||
        oldWidget.controller != widget.controller) {
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final person = widget.person;
    final controller = widget.controller;
    _bytes = controller.cachedPersonPreview(person);
    _error = null;
    try {
      final saved = await controller.restorePersonPreview(person);
      if (!mounted || generation != _generation) return;
      if (saved != null) setState(() => _bytes = saved);
      final bytes = await controller.personPreview(person);
      if (mounted && generation == _generation) {
        setState(() => _bytes = bytes);
      }
    } catch (e) {
      if (e is PreviewCancelled) return;
      if (mounted && generation == _generation) {
        setState(() {
          _bytes = null;
          _error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final person = widget.person;
    final colors = Theme.of(context).colorScheme;
    final portrait = ClipOval(
      child: SizedBox.square(
        dimension: widget.diameter,
        child: ColoredBox(
          color: colors.surfaceContainerHighest,
          child: _bytes == null
              ? Icon(
                  _error == null
                      ? Icons.person_outline
                      : Icons.broken_image_outlined,
                  size: 32,
                  color: colors.onSurfaceVariant,
                )
              : Image.memory(
                  _bytes!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Tooltip(
                    message: 'The server returned an invalid face preview.',
                    child: Icon(Icons.broken_image_outlined),
                  ),
                ),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: '${person.label}, ${person.count} photos',
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(16),
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              children: [
                _error == null
                    ? portrait
                    : Tooltip(message: _error!, child: portrait),
                const SizedBox(height: 8),
                Text(
                  person.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  '${person.count} photos',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
