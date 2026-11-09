import '../../core/cloud/cloud_backend.dart';
import '../../models.dart';

/// A share panel is bound to the account and file that opened it.
class ShareSession {
  ShareSession({
    required CloudBackend client,
    required Account account,
    required CloudFile file,
    required bool Function() isCurrent,
    required Future<CloudFile> Function(CloudFile) resolve,
  }) : _client = client,
       _account = account,
       _file = file,
       _isCurrent = isCurrent,
       _resolve = resolve;

  final CloudBackend _client;
  final Account _account;
  final CloudFile _file;
  final bool Function() _isCurrent;
  final Future<CloudFile> Function(CloudFile) _resolve;

  void _checkCurrent() {
    if (!_isCurrent()) {
      throw const CloudException(
        'The account changed. Open the share panel again.',
      );
    }
  }

  Future<T> _run<T>(Future<T> Function() action) async {
    _checkCurrent();
    final result = await action();
    _checkCurrent();
    return result;
  }

  Future<List<FileShare>> list() =>
      _withFile((file) => _client.shares(_account, file));

  Future<FileShare> createLink({String? password, DateTime? expires}) =>
      _withFile(
        (file) => _client.createLink(
          _account,
          file,
          password: password,
          expires: expires,
        ),
      );

  /// Whether the file is a folder, which decides what "edit" allows.
  bool get isFolder => _file.isDirectory;

  Future<List<Sharee>> findPeople(String query) => _run(
    () => _client.findSharees(_account, query, folder: _file.isDirectory),
  );

  Future<FileShare> addPerson(Sharee sharee, {bool canEdit = false}) =>
      _withFile(
        (file) => _client.shareWith(_account, file, sharee, canEdit: canEdit),
      );

  Future<FileShare> setEditable(FileShare share, bool canEdit) =>
      _run(() => _client.setShareEditable(_account, share, canEdit));

  Future<void> revoke(FileShare share) =>
      _run(() => _client.revokeShare(_account, share));

  Future<T> _withFile<T>(Future<T> Function(CloudFile file) action) =>
      _run(() async {
        final file = await _resolve(_file);
        _checkCurrent();
        return action(file);
      });
}
