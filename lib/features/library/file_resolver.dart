import '../../core/cloud/cloud_backend.dart';
import '../../models.dart';

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
  final CloudFile? Function(String id, CloudFile? file) apply;
  final Map<String, CloudFile> _resolved = {};
  final Map<String, Future<CloudFile>> _pending = {};
  Account? _owner;
  int _generation = 0;

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
    final request = _fetch(session, id, generation);
    _pending[id] = request;
    try {
      return await request;
    } finally {
      if (identical(_pending[id], request)) _pending.remove(id);
    }
  }

  Future<CloudFile> _fetch(Account session, String id, int generation) async {
    final found = await client.resolveFileIds(session, [id]);
    _checkCurrent(session, generation);
    final resolved = apply(id, found[id]);
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
