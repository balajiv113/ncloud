import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cloud_backend.dart';
import 'models.dart';

/// Nextcloud notify_push wire protocol; consumers only see invalidation hints.
Stream<Set<String>?> nextcloudChanges(
  Account account,
  Future<Uri?> Function() endpoint, {
  Future<WebSocket> Function(Uri)? connect,
}) {
  late StreamController<Set<String>?> controller;
  WebSocket? socket;
  StreamSubscription<dynamic>? subscription;
  var cancelled = false;
  var authenticated = false;

  Future<void> open() async {
    try {
      final uri = await endpoint();
      if (cancelled || uri == null) return;
      final opening = (connect ?? (uri) => WebSocket.connect('$uri'))(uri);
      late WebSocket connected;
      try {
        connected = await opening.timeout(const Duration(seconds: 15));
      } on TimeoutException {
        unawaited(
          opening.then<void>(
            (lateSocket) => lateSocket.close(),
            onError: (Object _, StackTrace _) {},
          ),
        );
        rethrow;
      }
      if (cancelled) {
        await connected.close();
        return;
      }
      socket = connected;
      connected
        ..add(account.loginName)
        ..add(account.appPassword);
      subscription = connected.listen(
        (dynamic event) {
          if (cancelled || event is! String) return;
          if (event == 'authenticated') {
            authenticated = true;
            connected.add('listen notify_file_id');
          } else if (event.startsWith('err:')) {
            controller.addError(
              const CloudException(
                'Push authentication failed. Reconnect in Settings if change checks also fail.',
              ),
            );
            unawaited(connected.close());
          } else if (event == 'notify_file' && authenticated) {
            controller.add(null);
          } else if (event.startsWith('notify_file_id ') && authenticated) {
            try {
              final values = jsonDecode(
                event.substring('notify_file_id '.length),
              );
              if (values is! List ||
                  values.any(
                    (id) =>
                        (id is! int && id is! String) ||
                        !RegExp(r'^\d+$').hasMatch(id.toString()),
                  )) {
                throw const FormatException('Invalid push file IDs.');
              }
              controller.add(
                values.length > 500
                    ? null
                    : values.map((id) => id.toString()).toSet(),
              );
            } catch (error, stack) {
              controller.addError(error, stack);
              controller.add(null);
            }
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!cancelled) controller.addError(error, stack);
          unawaited(connected.close());
        },
        onDone: () {
          if (!cancelled) unawaited(controller.close());
        },
      );
    } catch (error, stack) {
      if (!cancelled) {
        controller.addError(error, stack);
        unawaited(controller.close());
      }
    }
  }

  controller = StreamController<Set<String>?>(
    onListen: () => unawaited(open()),
    onCancel: () async {
      cancelled = true;
      await subscription?.cancel();
      await socket?.close();
    },
  );
  return controller.stream;
}
