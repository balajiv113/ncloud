import 'package:flutter/material.dart';

/// What a view shows when it has nothing to list: a connection problem, more
/// dates to scroll to, or an empty collection.
class EmptyLibrary extends StatelessWidget {
  const EmptyLibrary({
    super.key,
    required this.failed,
    required this.hasMore,
    required this.message,
  });

  final bool failed;
  final bool hasMore;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            failed ? Icons.cloud_off : Icons.photo_library_outlined,
            size: 44,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            failed
                ? 'Connection interrupted'
                : hasMore
                ? 'Keep scrolling'
                : 'Nothing here yet',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
