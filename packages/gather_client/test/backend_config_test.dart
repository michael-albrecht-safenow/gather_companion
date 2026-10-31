/// BackendConfig + OTP login — the general-client seam.
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

/// A minimal [GatherHttp] whose `postForm` returns a chosen status + body, so the
/// OTP flow can be exercised with the exact `/auth/otp-verify` response shape.
class _FakeOtpHttp implements GatherHttp {
  _FakeOtpHttp({required this.status, required this.body});
  final int status;
  final Map<String, Object?> body;
  final List<({Uri uri, Map<String, String> fields})> posts = [];

  @override
  Future<({int status, Map<String, Object?> body})> postForm(
    Uri uri,
    Map<String, String> fields,
  ) async {
    posts.add((uri: uri, fields: fields));
    return (status: status, body: body);
  }

  @override
  Future<({int status, Object? body})> getJson(Uri uri, String bearer) async =>
      (status: 200, body: null);
  @override
  Future<({int status, List<int> body})> getBytes(Uri uri, String bearer) async =>
      (status: 200, body: const <int>[]);
  @override
  Future<({int status, List<int> body})> postJson(Uri uri, String bearer, Object? body) async =>
      (status: 200, body: const <int>[]);
}

void main() {
  group('BackendConfig', () {
    test('the gather default keeps the original hosts', () {
      const g = BackendConfig.gather;
      expect(g.apiBase, 'https://api.v2.gather.town/api/v2');
      expect(g.gameSocket, 'wss://game-router.v2.gather.town/gather-game-v2');
      expect(g.authStrategy, AuthStrategy.firebase);
      expect(g.firebaseKey, isNotNull);
      // Firebase refresh keeps the ?key= query.
      expect(g.refreshUri().toString(), contains('key='));
    });

    test('a bether profile derives its endpoints from the host', () {
      final b = BackendConfig.bether(
        name: 'Office',
        httpBase: 'https://office.example.com',
        wsBase: 'wss://office.example.com',
      );
      expect(b.apiBase, 'https://office.example.com/api/v2');
      expect(b.gameSocket, 'wss://office.example.com/gather-game-v2');
      expect(b.tokenEndpoint, 'https://office.example.com/auth/token');
      expect(b.otpVerifyEndpoint, 'https://office.example.com/auth/otp-verify');
      expect(b.authStrategy, AuthStrategy.otp);
      // No Firebase key, so no ?key= on refresh.
      expect(b.refreshUri().toString(), 'https://office.example.com/auth/token');
    });

    test('fromDescriptor builds a profile from /.well-known/gather-backend.json', () {
      final b = BackendConfig.fromDescriptor({
        'name': 'My Office',
        'protocolVersion': 'gather-v2',
        'apiBase': 'https://office.example.com/api/v2',
        'gameSocket': 'wss://office.example.com/gather-game-v2',
        'auth': {
          'strategies': ['otp'],
          'tokenEndpoint': 'https://office.example.com/auth/token',
        },
      });
      expect(b.name, 'My Office');
      expect(b.authStrategy, AuthStrategy.otp);
      expect(b.otpRequestEndpoint, 'https://office.example.com/auth/otp-request');
      expect(b.otpVerifyEndpoint, 'https://office.example.com/auth/otp-verify');
    });
  });

  group('OtpLogin', () {
    final config = BackendConfig.bether(
      name: 'Office',
      httpBase: 'https://office.example.com',
      wsBase: 'wss://office.example.com',
    );

    test('verify maps the securetoken-shaped body onto GatherCredentials', () async {
      final http = _FakeOtpHttp(
        status: 200,
        body: {'id_token': 'id-xyz', 'refresh_token': 'refresh-abc', 'user_id': 'uid-1'},
      );
      final creds = await OtpLogin(config: config, http: http).verify('me@example.com', '123456');
      expect(creds.refreshToken, 'refresh-abc');
      expect(creds.idToken, 'id-xyz');
      expect(creds.uid, 'uid-1');
      // It POSTed to the backend's otp-verify endpoint with the code.
      expect(http.posts.single.uri.toString(), config.otpVerifyEndpoint);
      expect(http.posts.single.fields['code'], '123456');
    });

    test('a rejected code throws a transient (retryable) error', () async {
      final http = _FakeOtpHttp(status: 400, body: {
        'error': {'message': 'INVALID_CODE'},
      });
      await expectLater(
        OtpLogin(config: config, http: http).verify('me@example.com', '000000'),
        throwsA(isA<GatherAuthException>()
            .having((e) => e.permanent, 'permanent', isFalse)
            .having((e) => e.message, 'message', contains('INVALID_CODE'))),
      );
    });

    test('OTP login against the gather profile is refused (no OTP there)', () async {
      await expectLater(
        OtpLogin(config: BackendConfig.gather).requestCode('me@example.com'),
        throwsA(isA<GatherAuthException>()),
      );
    });
  });
}
