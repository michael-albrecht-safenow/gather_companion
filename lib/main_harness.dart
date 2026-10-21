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
import 'harness/demo_footage.dart';
import 'harness/fake_collector.dart';
import 'harness/harness_data.dart';
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

  // One harness, the whole app, by default: the real pair→home→office flow with a
  // fake backend, so the office is walkable, Dial warps into a real call, Gameboy
  // mode opens, and the call's door walks you back to your desk. `TARGET=call`
  // still boots straight into the call-only scene for a quick spotlight look.
  const target = String.fromEnvironment('TARGET', defaultValue: 'app');
  const callScenario = String.fromEnvironment('SCENARIO', defaultValue: 'group');
  const appScenario = String.fromEnvironment('SCENARIO', defaultValue: 'office');
  const participantsRaw = int.fromEnvironment('PARTICIPANTS');
  final participants = participantsRaw == 0 ? 4 : participantsRaw;

  runApp(target == 'app' ? _buildApp(appScenario, participants) : _buildCall(callScenario, participants));
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
  // The scripted roster seats us in a huddle, and the call screen's control bar
  // offers the real Leave door. Without a collector behind it that door calls
  // `leaveHuddle()` on nothing and pops a spurious "Not connected to Gather." —
  // a harness exit reporting itself as a failure. Stand a [FakeCollector] in so
  // `leaveCluster()` resolves cleanly; it is attached, not started, so it never
  // emits a roster of its own to fight the scripted one the driver pushes.
  // ignore: invalid_use_of_visible_for_testing_member
  state.debugAttachCollector(FakeCollector(participants: participants));

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
      // A stand-in "office" sits under the call so the door and the back arrow
      // have somewhere to pop to — on the real app the call is pushed over the
      // home shell, but this target boots straight into the faces, so without a
      // route beneath it `Navigator.pop` is a no-op and there is no way out. The
      // office auto-pushes the call on first frame, so you still land in it.
      home: _HarnessOffice(state: widget.state),
    );
  }
}

/// The floor the simulated call stands on, so leaving it lands somewhere. It
/// pushes the call itself on first frame — matching the app, where you are in the
/// call when the screen appears — and offers a button to walk back in after you
/// have left, so the leave/return loop can be driven on a bare simulator.
class _HarnessOffice extends StatefulWidget {
  const _HarnessOffice({required this.state});

  final AppState state;

  @override
  State<_HarnessOffice> createState() => _HarnessOfficeState();
}

class _HarnessOfficeState extends State<_HarnessOffice> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _enterCall());
  }

  void _enterCall() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        // The demo footage is wired in here, not in the app target: stand-in
        // video for every face, since the simulator has no camera to fill them.
        builder: (_) => CallScreen(state: widget.state, buildTile: demoFootageTile),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF171A23),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Office (sim)', style: TextStyle(color: Colors.white70, fontSize: 18)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _enterCall,
              icon: const Icon(Icons.videocam),
              label: const Text('Enter call'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---- the app target ---------------------------------------------------------

Widget _buildApp(String scenarioName, int participants) {
  // Every call opened from the walkable office — Dial warp, proximity huddle —
  // gets stand-in footage in its tiles, since the simulator has no camera to fill
  // them. One assignment, read by every `openCallScreen`.
  // ignore: invalid_use_of_visible_for_testing_member
  debugCallTileBuilder = demoFootageTile;

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
    // Seed the Plans tab so the timeline redesign can be eyeballed on a bare sim —
    // boot loads an empty keychain here, so without this the tab reads "No plans
    // yet". Set *after* boot, which otherwise overwrites `_plannedMeetings` with the
    // store's (empty) load. `--dart-define=PLANS=empty` leaves it blank to watch the
    // empty-state and create flow instead.
    if (const String.fromEnvironment('PLANS', defaultValue: 'demo') != 'empty') {
      final now = DateTime.now();
      // ignore: invalid_use_of_visible_for_testing_member
      widget.state.debugPlannedMeetings = demoPlannedMeetings(now);
      // Canned colleague calendars too, so tapping someone on the map or Dial opens a
      // populated timeline — the sheet's whole point — rather than "no calendar".
      // ignore: invalid_use_of_visible_for_testing_member
      widget.state.debugPeopleCalendars = demoPeopleCalendars(now);
    }
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
