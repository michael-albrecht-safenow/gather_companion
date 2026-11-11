/// The general-client flow through AppState: with no backend chosen the app is at
/// the picker; adding and choosing a backend routes to its login; an OTP login
/// connects and stores the session *under that profile*; and removing or backing
/// out of a backend returns to the picker — a backend staying in the list through
/// the latter, gone through the former.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/backend_profiles.dart';
import 'package:gather_companion/src/notifications.dart';

class _SilentNotifier extends Notifier {
  @override
  Future<void> init() async {}
  @override
  Future<void> requestPermission() async {}
}

/// Serves a descriptor to the add-backend fetch (getJson) and a securetoken-shaped
/// body to the OTP request/verify (postForm), so one fake drives the whole flow.
class _FlowHttp implements GatherHttp {
  @override
  Future<({int status, Object? body})> getJson(Uri uri, String bearer) async => (
        status: 200,
        body: {
          'name': 'My Office',
          'apiBase': 'https://office.example.com/api/v2',
          'gameSocket': 'wss://office.example.com/gather-game-v2',
          'auth': {
            'strategies': ['otp'],
            'tokenEndpoint': 'https://office.example.com/auth/token',
          },
        },
      );

  @override
  Future<({int status, Map<String, Object?> body})> postForm(Uri uri, Map<String, String> f) async =>
      (status: 200, body: {'id_token': 'id-xyz', 'refresh_token': 'refresh-abc', 'user_id': 'u1'});

  @override
  Future<({int status, List<int> body})> getBytes(Uri uri, String bearer) async =>
      (status: 200, body: const <int>[]);
  @override
  Future<({int status, List<int> body})> postJson(Uri uri, String bearer, Object? body) async =>
      (status: 200, body: const <int>[]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  AppState build() => AppState(
        notifier: _SilentNotifier(),
        http: _FlowHttp(),
        buildCollector: (auth, spaceId) => FakeCollector(),
      );

  test('with no backend chosen the app is at the picker', () {
    final state = build();
    expect(state.hasActiveBackend, isFalse);
    expect(state.knownProfiles, isEmpty);
    expect(state.isConfigured, isFalse);
  });

  test('adding then choosing a backend routes to its login, not yet connected', () async {
    final state = build();

    final added = await state.addBackendFromUrl('office.example.com');
    expect(added.error, isNull);
    expect(state.knownProfiles.single.name, 'My Office');
    // Added but not chosen: still the picker.
    expect(state.hasActiveBackend, isFalse);

    await state.activateBackend(added.profile!);
    // Chosen, no stored session: routes to that backend's login.
    expect(state.hasActiveBackend, isTrue);
    expect(state.isConfigured, isFalse);
    expect(state.backend.authStrategy, AuthStrategy.otp);
  });

  test('an OTP login connects and stores the session under the profile', () async {
    final state = build();
    final added = await state.addBackendFromUrl('office.example.com');
    await state.activateBackend(added.profile!);

    final failure = await state.loginWithOtp('me@example.com', '123456');

    expect(failure, isNull);
    expect(state.isConfigured, isTrue, reason: 'the securetoken body is a complete session');

    // The session is persisted against this profile's id, not globally.
    final stored = await BackendProfileStore(storage: const FlutterSecureStorage())
        .loadCredentials(added.profile!.id);
    expect(stored.refreshToken, 'refresh-abc');
  });

  test('removing the active backend forgets it and returns to the picker', () async {
    final state = build();
    final added = await state.addBackendFromUrl('office.example.com');
    await state.activateBackend(added.profile!);

    await state.removeBackend(added.profile!.id);

    expect(state.hasActiveBackend, isFalse);
    expect(state.knownProfiles, isEmpty);
  });

  test('backing out of a backend returns to the picker but keeps it in the list', () async {
    final state = build();
    final added = await state.addBackendFromUrl('office.example.com');
    await state.activateBackend(added.profile!);

    await state.deactivateBackend();

    expect(state.hasActiveBackend, isFalse);
    expect(state.knownProfiles.single.id, added.profile!.id, reason: 'added backends persist');
  });
}
