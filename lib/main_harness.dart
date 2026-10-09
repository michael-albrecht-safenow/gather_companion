/// Simulator harness entrypoint. Boots straight into a scripted scene with no
/// microphone, camera, network or Gather backend behind it, so the app can be
/// watched by eye and driven with `idb` on a bare simulator.
///
/// Two targets, chosen with `--dart-define=TARGET`:
///
///  * **`call`** (default) — straight into [CallScreen] on a scripted multi-party
///    call. [ScriptedCall] + [CallScenarioDriver] animate who is talking, for the
///    spotlight. This is the original harness, untouched.
///
///  * **`app`** — the whole app: it boots through the real pair→home flow into
///    [HomeShell] with a [FakeCollector] standing in for the Gather socket, so the
///    Office is walkable, party mode runs, and the Activity feed fills — all with
///    no network. [AppScenarioDriver] mills the cast about and lands waves.
///
/// ```
/// # the call screen (spotlight)
/// flutter run -t lib/main_harness.dart -d <sim> \
///   --dart-define=TARGET=call --dart-define=SCENARIO=roundrobin --dart-define=PARTICIPANTS=4
///
/// # the whole app
/// flutter run -t lib/main_harness.dart -d <sim> \
///   --dart-define=TARGET=app --dart-define=SCENARIO=office --dart-define=PARTICIPANTS=4
/// ```
///
/// `SCENARIO` is a [Scenario] (call) or [AppScenario] (app) name; `PARTICIPANTS`
/// is how many of the cast to seat (default 4). See `docs/sim_harness.md`.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gather_client/gather_client.dart';

import 'harness/call_scenarios.dart';
import 'harness/fake_collector.dart';
import 'harness/scripted_call.dart';
import 'src/app_state.dart';
import 'src/credentials.dart';
import 'src/settings.dart';
import 'src/ui_preferences.dart';
import 'theme/gather_theme.dart';
import 'ui/call_screen.dart';
import 'ui/home_shell.dart';
import 'ui/pair_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

  const target = String.fromEnvironment('TARGET', defaultValue: 'call');
  const scenarioName = String.fromEnvironment('SCENARIO', defaultValue: 'group');
  const participantsRaw = int.fromEnvironment('PARTICIPANTS');
  final participants = participantsRaw == 0 ? 4 : participantsRaw;

  runApp(target == 'app' ? _buildApp(scenarioName, participants) : _buildCall(scenarioName, participants));
}

// ---- the call target --------------------------------------------------------

Widget _buildCall(String scenarioName, int participants) {
  final scenario = Scenario.fromName(scenarioName);
  final state = AppState();
  final call = ScriptedCall();
  // A handle so the call screen's setWatching / buttons resolve rather than
  // null-crash; the rendered state rides on this same object via `emit`. A test
  // seam, driven here on purpose: this harness target exists for it.
  // ignore: invalid_use_of_visible_for_testing_member
  state.debugAttachCall(call);

  final driver = CallScenarioDriver(
    state: state,
    call: call,
    scenario: scenario,
    participants: participants,
  )..start();

  return _CallHarness(state: state, driver: driver);
}

class _CallHarness extends StatefulWidget {
  const _CallHarness({required this.state, required this.driver});

  final AppState state;
  final CallScenarioDriver driver;

  @override
  State<_CallHarness> createState() => _CallHarnessState();
}

class _CallHarnessState extends State<_CallHarness> {
  @override
  void dispose() {
    widget.driver.stop();
    widget.state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gather Companion — Harness',
      debugShowCheckedModeBanner: false,
      theme: buildGatherTheme(),
      // Straight into the faces: no pairing, no home shell, no network boot.
      home: CallScreen(state: widget.state),
    );
  }
}

// ---- the app target ---------------------------------------------------------

Widget _buildApp(String scenarioName, int participants) {
  final fake = FakeCollector(participants: participants);
  // One [ScriptedCall], held here so the driver can push call state onto the very
  // instance `AppState` builds on the first warp or proximity huddle — a warp's
  // `setMicOn`, or `_noteCluster`, calls this back for the same object.
  final call = ScriptedCall();
  final state = AppState(
    // The two seams that make the whole app run without a wire: a [Collector]
    // that is not a socket, and a [Call] that is not a microphone.
    buildCollector: (auth, spaceId) => fake,
    buildCall: (auth, spaceId, srcId) => call,
    // Without this the simulator's real connectivity plugin reports no interface,
    // `_isOffline()` reads true, the link parks offline, and every warp refuses
    // with "No connection — waiting for network." Report Wi-Fi so `boot()` brings
    // the link live and the call paths actually run.
    connectivityNow: () async => const [ConnectivityResult.wifi],
    connectivityChanges: const Stream<List<ConnectivityResult>>.empty(),
    // The feed fills from the collector's interaction stream (live waves), so the
    // REST feed has nothing to add. A synthetic space id (below) arms the fetch
    // path; this keeps that path off the wire rather than letting it reach Gather.
    buildActivityFeed: (auth) => _SilentActivityFeed(auth),
    // A store that reports a complete credential, so `boot()` takes the pair→home
    // path into [HomeShell] rather than stopping at the pairing screen, and a
    // synthetic space id so the injected [ScriptedCall] can be placed. It reads,
    // writes and clears nothing, so `unpair()` cannot wipe a real Gather credential
    // the simulator may already hold.
    credentials: _HarnessCredentials(),
    // No bridge behind the app harness. The real store would load, save and clear
    // simulator-persistent bridge settings and let `boot()` register push against a
    // previously paired bridge; this reports an empty bridge, so push no-ops on an
    // incomplete setting and `unpair()` clears nothing real.
    bridge: _HarnessBridgeStore(),
  );
  final driver = AppScenarioDriver(
    state: state,
    collector: fake,
    call: call,
    scenario: AppScenario.fromName(scenarioName),
  );
  return _AppHarness(state: state, driver: driver);
}

/// A credential store that is always "paired", with no keychain behind it. It reads
/// a complete credential and a synthetic space, and writes/clears nothing — so the
/// app harness can place a scripted call yet cannot touch the real Gather credential
/// the simulator keychain may already hold (`unpair()` is inert here).
class _HarnessCredentials extends GatherCredentialStore {
  @override
  Future<GatherCredentials> load() async => const GatherCredentials(refreshToken: 'sim-harness');

  /// A stand-in space id. `_spaceIdForCall` reads this when the fake roster carries
  /// no server-supplied space, which is what lets the injected `ScriptedCall` build;
  /// nothing fetches against it — the feed and photo paths are kept off the wire.
  @override
  Future<String?> loadSpaceId() async => 'sim-harness-space';

  @override
  Future<void> save(GatherCredentials credentials) async {}

  @override
  Future<void> saveSpaceId(String? spaceId) async {}

  @override
  Future<void> clear() async {}
}

/// A bridge-settings store with nothing behind it. The app harness never pairs a
/// bridge, so `load` returns empty — push registration then no-ops on an incomplete
/// setting — and save/clear do nothing, keeping the simulator's stored bridge
/// settings untouched.
class _HarnessBridgeStore extends BridgeSettingsStore {
  @override
  Future<BridgeSettings> load() async => BridgeSettings.empty;

  @override
  Future<String?> loadName() async => null;

  @override
  Future<void> save(BridgeSettings settings) async {}

  @override
  Future<void> saveName(String name) async {}

  @override
  Future<void> clear() async {}
}

/// An activity feed that never reaches the network. The app harness fills the feed
/// from the collector's interaction stream, so a REST fetch has nothing to add and
/// must not hit Gather — it returns an empty page instead.
class _SilentActivityFeed extends ActivityFeed {
  _SilentActivityFeed(GatherAuth auth) : super(auth: auth);

  @override
  Future<ActivityFeedPage> fetch(String spaceId) async => ActivityFeedPage.empty;
}

class _AppHarness extends StatefulWidget {
  const _AppHarness({required this.state, required this.driver});

  final AppState state;
  final AppScenarioDriver driver;

  @override
  State<_AppHarness> createState() => _AppHarnessState();
}

class _AppHarnessState extends State<_AppHarness> {
  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  /// Boot the real flow, then animate once the collector is subscribed. `boot`
  /// runs `_attach`, which calls `FakeCollector.start()` and wires the streams;
  /// starting the driver after keeps the first scripted roster from being emitted
  /// into a broadcast stream nobody is listening to yet.
  Future<void> _boot() async {
    // `--dart-define=GAMEBOY=true` boots straight into the handheld, for watching the
    // Gameboy shell and its centred camera on a bare sim. Written to [UiPreferences]
    // *before* [AppState.boot], because boot reads the flag from there — setting it
    // after would land on the Dial tab, since [HomeShell] picks its opening tab from
    // the flag as it first builds. The pref sticks on the throwaway sim, so the define
    // is honoured only when actually passed: `GAMEBOY=true` arms it, `GAMEBOY=false`
    // clears it again, and leaving it off keeps whatever the last run set.
    if (const bool.hasEnvironment('GAMEBOY')) {
      await UiPreferences().saveGameboyMode(const bool.fromEnvironment('GAMEBOY'));
    }
    // `--dart-define=GBTHEME=safenow` boots the handheld in a given hardware theme,
    // for watching the plastic skin and its brand on a bare sim. Written before
    // [AppState.boot] like the GAMEBOY flag, since boot reads it from there. Sticks
    // on the throwaway sim, so it is honoured only when actually passed.
    if (const bool.hasEnvironment('GBTHEME')) {
      await UiPreferences().saveGameboyThemeId(const String.fromEnvironment('GBTHEME'));
    }
    await widget.state.boot();
    if (mounted) widget.driver.start();
  }

  @override
  void dispose() {
    widget.driver.stop();
    widget.state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gather Companion — Harness',
      debugShowCheckedModeBanner: false,
      theme: buildGatherTheme(),
      home: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          // The same phase switch as `main.dart`, so the harness exercises the
          // real booting→pairing→home handover rather than jumping past it.
          final screen = switch (widget.state) {
            AppState(isLoaded: false) => ColoredBox(
                color: GatherTokens.dark.background,
                child: const SizedBox.expand(),
              ),
            AppState(isConfigured: false) => PairScreen(state: widget.state),
            _ => HomeShell(state: widget.state, onUnpair: widget.state.unpair),
          };
          return screen;
        },
      ),
    );
  }
}
