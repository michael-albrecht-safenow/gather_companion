/// In-app Gather login — the bridge-free path through [AppState.signInWithGather].
///
/// The native webview and its IndexedDB harvest are exercised on-device; this pins
/// the Dart glue: a harvested session is adopted exactly as a paired one is (creds
/// saved, socket attached, `isConfigured` flipped), a user cancel is silent and
/// changes nothing, and a session that came back empty is reported rather than
/// adopted.
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/gather_web_login.dart';
import 'package:gather_companion/src/notifications.dart';
import 'package:gather_companion/harness/fake_collector.dart';

/// Returns a canned outcome and records that it was asked, standing in for the
/// `WKWebView` + IndexedDB read.
class _FakeWebLogin implements GatherWebLogin {
  _FakeWebLogin(this._outcome);

  final GatherCredentials? _outcome;
  int calls = 0;

  @override
  Future<GatherCredentials?> signIn() async {
    calls++;
    return _outcome;
  }
}

/// A notifier that never touches the platform channel — `requestPermission` would
/// otherwise reach the (absent) local-notifications plugin under the test host.
class _SilentNotifier extends Notifier {
  @override
  Future<void> requestPermission() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AppState stateWith(_FakeWebLogin login) => AppState(
        webLogin: login,
        notifier: _SilentNotifier(),
        // Keep `_attach`/`_detach` off the real plugins.
        buildCollector: (auth, spaceId) => FakeCollector(),
        connectivityChanges: const Stream<List<ConnectivityResult>>.empty(),
        connectivityNow: () async => const [ConnectivityResult.wifi],
      );

  test('a harvested session is adopted and flips the app into its signed-in state',
      () async {
    final login = _FakeWebLogin(GatherCredentials(refreshToken: 'harvested', uid: 'u1'));
    final state = stateWith(login);
    addTearDown(state.dispose);

    expect(state.isConfigured, isFalse);

    final note = await state.signInWithGather();

    expect(login.calls, 1);
    expect(note, isNull); // success is silent
    expect(state.isConfigured, isTrue);
  });

  test('a user cancel is silent and leaves the app unconfigured', () async {
    final login = _FakeWebLogin(null); // dismissed the webview
    final state = stateWith(login);
    addTearDown(state.dispose);

    final note = await state.signInWithGather();

    expect(login.calls, 1);
    expect(note, isNull); // a deliberate cancel is not an error
    expect(state.isConfigured, isFalse);
  });

  test('an empty session is reported, not adopted', () async {
    final login = _FakeWebLogin(const GatherCredentials(refreshToken: ''));
    final state = stateWith(login);
    addTearDown(state.dispose);

    final note = await state.signInWithGather();

    expect(note, isNotNull);
    expect(state.isConfigured, isFalse);
  });
}
