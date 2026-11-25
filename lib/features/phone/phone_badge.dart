import 'package:flutter/material.dart';

import '../backup/model/backup_state.dart';

/// How a photo that is only on the phone says where the backup stands with it:
/// a small mark in the corner of its tile or viewer. A photo that is left out
/// stands out most, since nothing will ever back it up.
class PhoneBadge extends StatelessWidget {
  const PhoneBadge(this.state, {super.key, this.size = 14});

  final BackupState state;
  final double size;

  static ({IconData icon, String label}) _look(BackupState state) =>
      switch (state) {
        BackupState.backedUp => (
          icon: Icons.cloud_done_outlined,
          label: 'Backed up',
        ),
        BackupState.waiting => (
          icon: Icons.cloud_upload_outlined,
          label: 'Waiting to back up',
        ),
        BackupState.failed => (
          icon: Icons.error_outline,
          label: 'Could not be backed up',
        ),
        BackupState.leftOut => (
          icon: Icons.cloud_off_outlined,
          label: 'Not backed up',
        ),
      };

  /// What the badge says, in words.
  static String labelOf(BackupState state) => _look(state).label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final look = _look(state);
    final (background, foreground) = switch (state) {
      BackupState.leftOut => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      BackupState.failed => (colors.errorContainer, colors.onErrorContainer),
      _ => (Colors.black54, Colors.white),
    };
    return Semantics(
      label: look.label,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: background, shape: BoxShape.circle),
        child: Icon(look.icon, size: size, color: foreground),
      ),
    );
  }
}
