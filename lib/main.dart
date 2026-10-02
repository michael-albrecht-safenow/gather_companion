import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app_state.dart';
import 'src/media/live_call.dart';
import 'src/media/media_log.dart';
import 'src/media/os_call.dart';
import 'src/media/webrtc_media_engine.dart';
import 'theme/gather_theme.dart';
import 'ui/home_shell.dart';
import 'ui/pair_screen.dart';

Future<void> main() async {
  // Everything, including the binding, inside the zone.
  //
  // `WidgetsFlutterBinding.ensureInitialized()` captures `Zone.current` when it
  // builds, and every gesture and platform-channel callback is then dispatched
  // in *that* zone. Initialising it before `runZoned` therefore leaves the whole
  // app running in the root zone: the tree is built inside our zone, but a
  // button tap — and everything it calls — is not. The `print` hook below then
  // sees library output from timers and socket callbacks while silently missing
  // all of it from the publish path, which is the one place we were reading.
  //
  // That cost three rounds on a device: traces added inside mediasoup were
  // executing and going nowhere, which reads exactly like code that never ran.
  runZoned(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      // No generated `firebase_options.dart`: on Apple platforms the SDK reads
      // ios/Runner/GoogleService-Info.plist, which is the file the Firebase
      // console hands out and the only place the config should live. One fewer
      // generated file to drift.
      //
      // Wrapped because push is an enhancement, not a requirement. A missing or
      // malformed plist must degrade to "no push" — the feed and follow
      // detection both work without Firebase — rather than crash on launch.
      try {
        await Firebase.initializeApp();
      } catch (error) {
        debugPrint('firebase: not initialised, push disabled — $error');
      }
      runApp(const GatherCompanionApp());
    },
    // Library failures arrive through `print` and nowhere else. mediasoup's
    // `FlexQueue` catches every exception a queued task throws, prints it under
    // `kDebugMode`, and calls an error callback `transport.produce()` never
    // passes — so a `produce` that dies on the way to the wire surfaces twenty
    // seconds later as a timeout with no cause attached.
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        mediaLogToFile(line);
        parent.print(zone, line);
      },
    ),
  );
}

class GatherCompanionApp extends StatefulWidget {
  const GatherCompanionApp({super.key});

  @override
  State<GatherCompanionApp> createState() => _GatherCompanionAppState();
}

class _GatherCompanionAppState extends State<GatherCompanionApp> with WidgetsBindingObserver {
  /// The one place the media layer is named.
  ///
  /// `AppState` takes it as a seam rather than importing it, so everything above
  /// the microphone stays testable on a machine that has none — see
  /// `src/media/media_engine.dart`.
  final _state = AppState(
    buildCall: (auth, spaceId, srcId) => LiveCall(
      auth: auth,
      spaceId: spaceId,
      srcId: srcId,
      log: mediaLog,
      // On iOS the OS owns the route: CallKit activates the session and the
      // system call sheet is the route picker, so the engine must not force the
      // speaker from under it. Android has no such owner and routes itself.
      engine: WebrtcMediaEngine(
        log: mediaLog,
        manageAudioRoute: !Platform.isIOS,
      ),
    ),
    // CallKit on iOS, a no-op on Android until its ConnectionService lands.
    osCall: defaultOsCall(log: mediaLog),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The app is dark-only, so the status bar has to be told once rather than
    // inferred from a light theme that does not exist.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    _state.boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // The OS tears the socket down while the app is suspended, so coming back to
    // the foreground has to end up on a live socket — which also replays
    // everything missed.
    //
    // Asking rather than assuming, though. `resumed` fires for a pulled-down
    // notification banner and for Control Centre too, neither of which touches
    // the socket, and reconnecting unconditionally threw away a working
    // connection every time — a second of "Reconnecting" for nothing, which is
    // most of what made the link look unreliable.
    if (lifecycle == AppLifecycleState.resumed) {
      // Before the link check, so it goes out on the socket we still hold. If
      // `verifyLink` does reconnect, the handshake reports active again anyway.
      unawaited(_state.setActive(true));
      unawaited(_state.verifyLink());
      // A separate question with a separate answer: the computer may have gone to
      // sleep, come back, or had its push credentials set up while we were away.
      // Nothing else re-asks, so a stale "can wake this app" would sit there for the
      // rest of the session.
      unawaited(_state.refreshPushReach());
    }
    // The other half of `reportActivity`, and the half that was missing: without it
    // `Connection.isActive` stays true for as long as the socket does, and a phone
    // in a pocket goes on telling colleagues somebody is at their desk. `paused` is
    // the state that means backgrounded on both platforms; `inactive` fires for a
    // pulled-down notification banner and would be a lie.
    if (lifecycle == AppLifecycleState.paused) {
      unawaited(_state.setActive(false));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gather Companion',
      debugShowCheckedModeBanner: false,
      theme: buildGatherTheme(),
      home: ListenableBuilder(
        listenable: _state,
        builder: (context, _) {
          final (phase, screen) = switch (_state) {
            AppState(isLoaded: false) => (
              // Deliberately empty, and deliberately the same colour as the
              // launch storyboard. Booting is a preferences read — a few frames —
              // and a spinner that appears and disappears inside that window is
              // pure flicker. Holding the launch screen's own surface makes the
              // handover invisible instead.
              _Phase.booting,
              ColoredBox(
                color: GatherTokens.dark.background,
                child: const SizedBox.expand(),
              ),
            ),
            AppState(isConfigured: false) => (_Phase.pairing, PairScreen(state: _state)),
            // The tabs start here and not before: there is nothing to navigate
            // between until there is a Gather credential to navigate with.
            _ => (_Phase.home, HomeShell(state: _state, onUnpair: _state.unpair)),
          };

          // Keyed by phase, never by state identity: a ValueKey that changed on
          // every notification would restart this transition on every socket
          // frame and make the whole screen strobe.
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            child: KeyedSubtree(key: ValueKey(phase), child: screen),
          );
        },
      ),
    );
  }
}

enum _Phase { booting, pairing, home }
