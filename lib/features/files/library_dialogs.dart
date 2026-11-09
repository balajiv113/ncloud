import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_controller.dart';
import '../../core/ui/messages.dart';
import '../../models.dart';

class NameDialog extends StatefulWidget {
  const NameDialog({super.key, this.title = 'New folder', this.initial = ''});
  final String title;
  final String initial;
  @override
  State<NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<NameDialog> {
  late final _name = TextEditingController(text: widget.initial);
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, _name.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onFieldSubmitted: (_) => _submit(),
        validator: (value) {
          try {
            validateName(value?.trim() ?? '');
            return null;
          } on FormatException catch (e) {
            return e.message;
          }
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Save')),
    ],
  );
}

Future<void> shareFile(
  BuildContext context,
  AppController controller,
  CloudFile file,
) async {
  try {
    final output = await controller.download(file);
    if (!context.mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(output.path)],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
