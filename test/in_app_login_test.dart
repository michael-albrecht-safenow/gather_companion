/// In-app Gather login — the bridge-free path through [AppState.signInWithGather].
///
/// The native webview and its IndexedDB harvest are exercised on-device; this pins
/// the Dart glue: a harvested session resolves a space before it is adopted (so the
/// collector is never handed the null that stranded it on "Reconnecting"), the
/// chosen space is the one adopted, a session with no recent spaces is reported
/// rather than adopted, and both a webview dismiss and a picker dismiss are silent.
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

/// Adopting a real space drives `_attach` to load the activity feed, which would
/// otherwise mint an ID token and hit the REST API. This stands in for it,
/// returning an empty page without touching the network.
class _EmptyActivityFeed implements ActivityFeed {
  @override
  Future<ActivityFeedPage> fetch(String spaceId) async =>
      ActivityFeedPage(items: const [], fetchedAt: DateTime.fromMillisecondsSinceEpoch(0));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a state over the fake login. [spaces] is what the recent-spaces lookup
  /// returns (or [spacesThrows] makes it fail); [onBuildCollector] captures the
  /// space id that reached adoption — the collector is built from `_spaceId` in
  /// `_attach`, so it is the proof the chosen id was carried through.
  AppState stateWith(
    _FakeWebLogin login, {
    List<GatherSpace> spaces = const [],
    bool spacesThrows = false,
    void Function(String? spaceId)? onBuildCollector,
  }) =>
      AppState(
        webLogin: login,
        notifier: _SilentNotifier(),
        buildActivityFeed: (_) => _EmptyActivityFeed(),
        recentSpacesOf: (creds) async {
          if (spacesThrows) throw StateError('network down');
          return (spaces: spaces, credentials: creds);
        },
        // Keep `_attach`/`_detach` off the real plugins, and record the adopted id.
        buildCollector: (auth, spaceId) {
          onBuildCollector?.call(spaceId);
          return FakeCollector();
        },
        connectivityChanges: const Stream<List<ConnectivityResult>>.empty(),
        connectivityNow: () async => const [ConnectivityResult.wifi],
      );

  /// A chooser that always takes the first offered space, like a one-tap pick.
  Future<GatherSpace?> pickFirst(List<GatherSpace> spaces) async => spaces.first;

  /// Lets `_attach`'s fire-and-forget activity load run its `notifyListeners` to
  /// completion, so it does not land after the `dispose` teardown and assert.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('the chosen space is resolved and adopted, flipping the app signed-in',
      () async {
    final login = _FakeWebLogin(GatherCredentials(refreshToken: 'harvested', uid: 'u1'));
    String? adopted;
    final state = stateWith(
      login,
      spaces: const [GatherSpace(id: 'space-a', name: 'Alpha')],
      onBuildCollector: (id) => adopted = id,
    );
    addTearDown(state.dispose);

    expect(state.isConfigured, isFalse);

    final note = await state.signInWithGather(chooseSpace: pickFirst);

    expect(login.calls, 1);
    expect(note, isNull); // success is silent
    expect(state.isConfigured, isTrue);
    expect(adopted, 'space-a'); // the picked id, not null
    await settle();
  });

  test('with several spaces the chooser receives them all and its pick is adopted',
      () async {
    final login = _FakeWebLogin(GatherCredentials(refreshToken: 'harvested', uid: 'u1'));
    String? adopted;
    List<GatherSpace>? offered;
    final state = stateWith(
      login,
      spaces: const [
        GatherSpace(id: 'space-a', name: 'Alpha'),
        GatherSpace(id: 'space-b', name: 'Beta'),
        GatherSpace(id: 'space-c', name: 'Gamma'),
      ],
      onBuildCollector: (id) => adopted = id,
    );
    addTearDown(state.dispose);

    final note = await state.signInWithGather(chooseSpace: (spaces) async {
      offered = spaces;
      return spaces[1]; // Beta
    });

    expect(note, isNull);
    expect(offered, hasLength(3));
    expect(state.isConfigured, isTrue);
    expect(adopted, 'space-b');
    await settle();
  });

  test('a refresh-token rotation during the spaces lookup is carried to adoption',
      () async {
    // The recent-spaces lookup can refresh the session and get a rotated refresh
    // token back. Adoption must save that, not the pre-lookup token, or the next
    // refresh fails on a superseded credential (issue #97 review).
    final login =
        _FakeWebLogin(GatherCredentials(refreshToken: 'harvested', uid: 'u1'));
    const rotated =
        GatherCredentials(refreshToken: 'rotated', idToken: 'fresh', uid: 'u1');
    String? adoptedRefresh;
    final state = AppState(
      webLogin: login,
      notifier: _SilentNotifier(),
      buildActivityFeed: (_) => _EmptyActivityFeed(),
      recentSpacesOf: (_) async => (
        spaces: const [GatherSpace(id: 'space-a', name: 'Alpha')],
        credentials: rotated,
      ),
      buildCollector: (auth, spaceId) {
        adoptedRefresh = auth.credentials.refreshToken;
        return FakeCollector();
      },
      connectivityChanges: const Stream<List<ConnectivityResult>>.empty(),
      connectivityNow: () async => const [ConnectivityResult.wifi],
    );
    addTearDown(state.dispose);

    final note = await state.signInWithGather(chooseSpace: pickFirst);

    expect(note, isNull);
    expect(adoptedRefresh, 'rotated'); // not the pre-lookup 'harvested'
    await settle();
  });

  test('no recent space is reported, not adopted', () async {
    final login = _FakeWebLogin(GatherCredentials(refreshToken: 'harvested', uid: 'u1'));
    var choserCalled = false;
    final state = stateWith(login, spaces: const []);
    addTearDown(state.dispose);

    final note = await state.signInWithGather(chooseSpace: (spaces) async {
      choserCalled = true;
      return spaces.first;
    });

    expect(note, isNotNull); // a sentence telling them to open a space first
    expect(choserCalled, isFalse); // nothing to pick from, so never asked
    expect(state.isConfigured, isFalse);
  });

  test('a failed recent-spaces lookup is reported, not adopted', () async {
    final login = _FakeWebLogin(GatherCredentials(refreshToken: 'harvested', uid: 'u1'));
    final state = stateWith(login, spacesThrows: true);
    addTearDown(state.dispose);

    final note = await state.signInWithGather(chooseSpace: pickFirst);

    expect(note, isNotNull);
    expect(state.isConfigured, isFalse);
  });

  test('dismissing the picker is silent and leaves the app unconfigured', () async {
    final login = _FakeWebLogin(GatherCredentials(refreshToken: 'harvested', uid: 'u1'));
    final state = stateWith(
      login,
      spaces: const [GatherSpace(id: 'space-a', name: 'Alpha')],
    );
    addTearDown(state.dispose);

    final note = await state.signInWithGather(chooseSpace: (_) async => null);

    expect(note, isNull); // a deliberate cancel is not an error
    expect(state.isConfigured, isFalse);
  });

  test('dismissing the webview is silent and leaves the app unconfigured', () async {
    final login = _FakeWebLogin(null); // dismissed the webview before any session
    var choserCalled = false;
    final state = stateWith(login);
    addTearDown(state.dispose);

    final note = await state.signInWithGather(chooseSpace: (spaces) async {
      choserCalled = true;
      return spaces.first;
    });

    expect(login.calls, 1);
    expect(note, isNull);
    expect(choserCalled, isFalse); // no session, so never reached the picker
    expect(state.isConfigured, isFalse);
  });

  test('an empty session is reported before any space lookup', () async {
    final login = _FakeWebLogin(const GatherCredentials(refreshToken: ''));
    var choserCalled = false;
    final state = stateWith(login);
    addTearDown(state.dispose);

    final note = await state.signInWithGather(chooseSpace: (spaces) async {
      choserCalled = true;
      return spaces.first;
    });

    expect(note, isNotNull);
    expect(choserCalled, isFalse);
    expect(state.isConfigured, isFalse);
  });
}
