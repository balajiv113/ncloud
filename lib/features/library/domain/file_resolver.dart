import '../../../core/cloud/cloud_backend.dart';
import '../../../core/storage/file_store.dart';
import '../../../models.dart';
import 'media_listing.dart';

/// Replaces a pathless entry in the shared store and every loaded listing.
({CloudFile? file, bool listingsChanged}) reconcileFileLocation(
  FileStore store,
  Iterable<MediaListing> listings,
  CloudFile original,
  CloudFile? real,
) {
  final key = original.key;
  final placeholder = store[key];
  final metadata = placeholder ?? original;
  final day = metadata.captureDay;
  final file = real != null && day != null
      ? real.withCaptureDate(
          metadata.taken ?? real.modified ?? DateTime.now(),
          metadata.etag ?? real.etag,
          day: day,
        )
      : real;
  if (placeholder == null && real != null) {
    return (file: file, listingsChanged: false);
  }
  final renamed = file == null ? <String, String>{} : {key: file.key};
  final gone = file == null ? {key} : <String>{};
  if (file != null) store.putAll([file]);
  var changed = false;
  for (final listing in listings) {
    if (listing.replace(renamed, gone)) changed = true;
  }
  store.removeKeys({...renamed.keys, ...gone});
  return (file: file, listingsChanged: changed);
}

/// Resolves lazy library entries only when an action requires their location.
class FileResolver {
  FileResolver({
    required this.client,
    required this.account,
    required this.active,
    required this.apply,
  });

  final CloudBackend client;
  final Account? Function() account;
  final bool Function() active;
  final CloudFile? Function(CloudFile original, CloudFile? file) apply;
  final Map<String, CloudFile> _resolved = {};
  final Map<String, Future<CloudFile>> _pending = {};
  Account? _owner;
  int _generation = 0;
  int get generation => _generation;

  void clear() {
    _generation++;
    _owner = null;
    _resolved.clear();
    _pending.clear();
  }

  CloudFile? cached(CloudFile file) {
    if (!identical(_owner, account())) return null;
    return _resolved[file.id];
  }

  void remember(
    Account session,
    CloudFile original,
    CloudFile resolved, {
    required int generation,
  }) {
    final id = original.id;
    if (id == null ||
        !active() ||
        !identical(account(), session) ||
        generation != _generation) {
      return;
    }
    if (!identical(_owner, session)) {
      _resolved.clear();
      _pending.clear();
      _owner = session;
    }
    final applied = apply(original, resolved);
    if (applied != null &&
        active() &&
        identical(account(), session) &&
        generation == _generation) {
      _resolved[id] = applied;
    }
  }

  Future<CloudFile> resolve(CloudFile file) async {
    if (!file.pending) return file;
    final id = file.id;
    if (id == null) {
      throw const CloudException('This item has no location reference.');
    }
    final session = account();
    if (session == null) {
      throw const CloudException('Sign in again to open this item.');
    }
    if (!identical(_owner, session)) {
      clear();
      _owner = session;
    }
    if (_resolved[id] case final known?) return known;
    if (_pending[id] case final pending?) return pending;
    final generation = _generation;
    final request = _fetch(session, file, id, generation);
    _pending[id] = request;
    try {
      return await request;
    } finally {
      if (identical(_pending[id], request)) _pending.remove(id);
    }
  }

  Future<CloudFile> _fetch(
    Account session,
    CloudFile original,
    String id,
    int generation,
  ) async {
    final found = await client.resolveFileIds(session, [id]);
    _checkCurrent(session, generation);
    if (_resolved[id] case final known?) return known;
    final resolved = apply(original, found[id]);
    _checkCurrent(session, generation);
    if (resolved == null) {
      throw const CloudException('This item is no longer available.');
    }
    return _resolved.putIfAbsent(id, () => resolved);
  }

  void _checkCurrent(Account session, int generation) {
    if (!active() ||
        !identical(account(), session) ||
        generation != _generation) {
      throw const CloudException(
        'The account or cache changed. Open this item again.',
      );
    }
  }
}
