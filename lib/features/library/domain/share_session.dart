import '../../../core/cloud/cloud_backend.dart';
import '../../../models.dart';

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

  Future<List<PublicShare>> list() => _run(() async {
    final file = await _resolve(_file);
    _checkCurrent();
    return _client.shares(_account, file);
  });

  Future<PublicShare> create({String? password, DateTime? expires}) =>
      _run(() async {
        final file = await _resolve(_file);
        _checkCurrent();
        return _client.createShare(
          _account,
          file,
          password: password,
          expires: expires,
        );
      });

  Future<void> revoke(PublicShare share) =>
      _run(() => _client.revokeShare(_account, share));
}
