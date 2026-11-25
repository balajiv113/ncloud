import 'package:flutter/material.dart';

import '../../app/app_controller.dart';

/// The setting that shows or hides the phone's photos in the Timeline.
class PhonePhotosTile extends StatefulWidget {
  const PhonePhotosTile({super.key, required this.controller});

  final AppController controller;

  @override
  State<PhonePhotosTile> createState() => _PhonePhotosTileState();
}

class _PhonePhotosTileState extends State<PhonePhotosTile> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    widget.controller.phone.isShown().then((shown) {
      if (mounted) setState(() => _shown = shown);
    });
  }

  Future<void> _change(bool wanted) async {
    final c = widget.controller;
    final now = await c.phone.setShown(wanted);
    if (!mounted) return;
    setState(() => _shown = now);
    if (wanted && !now) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Allow access to photos in your phone\'s settings to show them here.',
          ),
        ),
      );
    }
    await c.refreshPhone();
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    secondary: const Icon(Icons.phone_android_outlined),
    title: const Text('Photos on this phone'),
    subtitle: const Text(
      'Show photos that are not backed up in the Timeline, marked as waiting, '
      'left out or failed.',
    ),
    value: _shown,
    onChanged: _change,
  );
}
