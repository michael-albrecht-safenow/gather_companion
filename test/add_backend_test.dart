/// Adding a backend by its descriptor URL — the shared tail of both entry paths
/// (QR scan and typed URL), which resolve to the same `addBackendFromUrl`.
///
/// What is pinned: a bare host is fetched at the well-known path over https; a
/// valid descriptor becomes a stored profile carrying the backend's own endpoints
/// and advertised auth; and every failure (unreachable, non-200, junk body,
/// endpoint-less descriptor) returns a sentence rather than a half-written profile.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';

/// A [GatherHttp] whose `getJson` returns a chosen status + body and records the
/// URLs it was asked for, so the descriptor fetch can be driven offline.
class _FakeHttp implements GatherHttp {
  _FakeHttp({this.status = 200, this.body});
  final int status;
  final Object? body;
  final List<Uri> gets = [];

  @override
  Future<({int status, Object? body})> getJson(Uri uri, String bearer) async {
    gets.add(uri);
    return (status: status, body: body);
  }

  @override
  Future<({int status, Map<String, Object?> body})> postForm(Uri uri, Map<String, String> f) async =>
      (status: 200, body: const <String, Object?>{});
  @override
  Future<({int status, List<int> body})> getBytes(Uri uri, String bearer) async =>
      (status: 200, body: const <int>[]);
  @override
  Future<({int status, List<int> body})> postJson(Uri uri, String bearer, Object? body) async =>
      (status: 200, body: const <int>[]);
}

Map<String, Object?> _descriptor() => {
      'name': 'My Office',
      'protocolVersion': 'gather-v2',
      'apiBase': 'https://office.example.com/api/v2',
      'gameSocket': 'wss://office.example.com/gather-game-v2',
      'auth': {
        'strategies': ['otp', 'password'],
        'tokenEndpoint': 'https://office.example.com/auth/token',
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('a bare host is fetched at the well-known path over https', () async {
    final http = _FakeHttp(body: _descriptor());
    final state = AppState(http: http);

    final result = await state.addBackendFromUrl('office.example.com');

    expect(result.error, isNull);
    expect(http.gets.single.toString(),
        'https://office.example.com/.well-known/gather-backend.json');
  });

  test('a valid descriptor becomes a stored profile with the backend endpoints', () async {
    final state = AppState(http: _FakeHttp(body: _descriptor()));

    final result = await state.addBackendFromUrl('https://office.example.com');

    expect(result.error, isNull);
    expect(result.profile!.name, 'My Office');
    expect(result.profile!.config.gameSocket, 'wss://office.example.com/gather-game-v2');
    expect(result.profile!.config.authStrategy, AuthStrategy.otp);

    final stored = await state.backendProfiles();
    expect(stored.single.id, result.profile!.id);
  });

  test('a non-200 descriptor response adds nothing and explains why', () async {
    final state = AppState(http: _FakeHttp(status: 404, body: null));

    final result = await state.addBackendFromUrl('office.example.com');

    expect(result.profile, isNull);
    expect(result.error, contains('404'));
    expect(await state.backendProfiles(), isEmpty);
  });

  test('a descriptor missing its endpoints is refused, not half-stored', () async {
    final state = AppState(http: _FakeHttp(body: {'name': 'Broken', 'auth': {}}));

    final result = await state.addBackendFromUrl('office.example.com');

    expect(result.profile, isNull);
    expect(result.error, contains('endpoints'));
    expect(await state.backendProfiles(), isEmpty);
  });

  test('a blank address never reaches the network', () async {
    final http = _FakeHttp(body: _descriptor());
    final result = await AppState(http: http).addBackendFromUrl('   ');

    expect(result.error, isNotNull);
    expect(http.gets, isEmpty);
  });
}
