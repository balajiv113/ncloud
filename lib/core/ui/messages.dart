import 'package:flutter/material.dart';

import '../../diagnostics.dart';

void showError(BuildContext context, Object error) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(errorMessage(error))));

class MessageCard extends StatelessWidget {
  const MessageCard({
    super.key,
    required this.message,
    this.isError = false,
    this.onRetry,
  });
  final String message;
  final bool isError;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: isError
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: [
        Icon(isError ? Icons.error_outline : Icons.info_outline),
        const SizedBox(width: 12),
        Expanded(child: Text(message)),
        if (onRetry != null)
          IconButton(
            tooltip: 'Retry',
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
          ),
      ],
    ),
  );
}
