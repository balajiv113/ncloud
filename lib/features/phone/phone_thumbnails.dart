import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'phone_source.dart';

/// Thumbnails of the phone's photos, kept for the ones just shown.
///
/// The phone already caches its own thumbnails, so this only has to stop a grid
/// that scrolls back from asking again, and to share one request between tiles
/// that ask for the same photo at once.
class PhoneThumbnails {
  PhoneThumbnails(this._source, {this.capacity = 400});

  final PhoneSource _source;
  final int capacity;

  // Least recently used first. The values are the requests, so a photo asked
  // for twice while it is being made is made once.
  final LinkedHashMap<String, Future<Uint8List?>> _recent = LinkedHashMap();

  /// The thumbnail of the photo [id], about [size] pixels across.
  Future<Uint8List?> of(String id, int size) {
    final key = '$id|$size';
    final known = _recent.remove(key);
    final request = known ?? _source.thumbnail(id, size);
    _recent[key] = request;
    if (_recent.length > capacity) _recent.remove(_recent.keys.first);
    // A failure is not kept, so the next look tries again.
    request.ignore();
    unawaited(request.then<void>((_) {}, onError: (_) => _recent.remove(key)));
    return request;
  }

  /// Forgets everything, such as when the phone's library changes.
  void clear() => _recent.clear();
}
