import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/features/account/browser_login.dart';
import 'package:ncloud/models.dart';

class _Flow implements LoginFlow {
  @override
  Uri get login => Uri.parse('https://example.test/authorize');
}

class _Backend implements CloudBackend {
  int polls = 0;
  final Future<Account?> Function(int poll) response;
  _Backend(this.response);

  @override
  Future<LoginFlow> startLogin(Uri server) async => _Flow();

  @override
  Future<Account?> pollLogin(Uri server, LoginFlow flow) => response(++polls);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected operation: ${invocation.memberName}');
}

void main() {
  test('retryable failures stop at the bounded retry limit', () async {
    final backend = _Backend(
      (_) async => throw const CloudException('temporary', retryable: true),
    );
    var notices = 0;
    final flow = BrowserLogin(
      client: backend,
      isCurrent: () => true,
      isActive: () => true,
      waitForResume: (_) async => fail('Unexpected suspension'),
      onRetry: () => notices++,
      pollInterval: Duration.zero,
    );
    await expectLater(
      flow.authenticate(Uri.parse('https://example.test'), (_) async => true),
      throwsA(isA<CloudException>()),
    );
    expect(backend.polls, 5);
    expect(notices, 4);
  });

  test(
    'background failures do not consume the foreground retry budget',
    () async {
      var active = true;
      final backend = _Backend((poll) async {
        if (poll == 1) active = false;
        throw const CloudException('temporary', retryable: true);
      });
      var resumes = 0;
      final flow = BrowserLogin(
        client: backend,
        isCurrent: () => true,
        isActive: () => active,
        waitForResume: (_) async {
          resumes++;
          active = true;
        },
        onRetry: () {},
        pollInterval: Duration.zero,
      );
      await expectLater(
        flow.authenticate(Uri.parse('https://example.test'), (_) async => true),
        throwsA(isA<CloudException>()),
      );
      expect(resumes, 1);
      expect(backend.polls, 6);
    },
  );
}
