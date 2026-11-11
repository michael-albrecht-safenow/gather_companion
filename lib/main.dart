import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'src/app_state.dart';
import 'src/debug_drive/install.dart';
import 'src/fonts_license.dart';
import 'src/google_calendar.dart';
import 'src/media/live_call.dart';
import 'src/media/media_log.dart';
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
      // The debug drive's log tail, from the first line rather than from the
      // install in initState — the boot lines below land in media.log before
      // runApp, and the tail should agree with the file. Compile-time guard, as
      // for the install. See `src/debug_drive/install.dart`.
      if (kDebugMode) {
        startDriveLog(enabled: kDebugMode);
      }
      WidgetsFlutterBinding.ensureInitialized();
      // File the bundled fonts' licences with Flutter before the first frame, so
      // the required OFL notice ships with the app. See [registerFontLicenses].
      registerFontLicenses();
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

/// The Google OAuth iOS client id, supplied at build time rather than committed:
/// `flutter run --dart-define=GOOGLE_CLIENT_ID=NNN-xxx.apps.googleusercontent.com`.
/// Empty in a plain build, which leaves the Plans tab's Google connection hidden.
const _googleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');

/// Builds the read-only Google Calendar connection, or null when no client id was
/// defined. The reversed-domain form Google wants for the redirect/callback scheme
/// is derived from the id, so only the one value need be supplied.
GoogleCalendar? _buildGoogleCalendar() {
  // Diagnostic, only in a `--dart-define=GCAL_DEBUG=true` build — the gate to rule in
  // or out when the Plans tab and the Dial's calendar affordance are absent on device.
  const gcalDebug = bool.fromEnvironment('GCAL_DEBUG');
  if (_googleClientId.isEmpty) {
    if (gcalDebug) {
      mediaLogToFile('gcal: no GOOGLE_CLIENT_ID compiled in — feature disabled');
    }
    return null;
  }
  if (gcalDebug) {
    mediaLogToFile('gcal: client id compiled in (len=${_googleClientId.length})');
  }
  const suffix = '.apps.googleusercontent.com';
  final base = _googleClientId.endsWith(suffix)
      ? _googleClientId.substring(0, _googleClientId.length - suffix.length)
      : _googleClientId;
  return GoogleCalendar(
    config: GoogleOAuthConfig(
      clientId: _googleClientId,
      reversedClientId: 'com.googleusercontent.apps.$base',
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
      // A compact per-stream flow verdict line in media.log while in a call, so a
      // field report has packet-level evidence and not only the signalling.
      flowLogEvery: const Duration(seconds: 5),
    ),
    // The same sink the call uses, so the movement, socket and cluster diagnostics
    // land in `tmp/media.log` alongside the media ones — the file a standalone phone
    // build keeps and `devicectl` can copy off. Without this the collector and walk
    // log into a `_noop` and a desk-desync leaves no trace.
    log: mediaLog,
    // The read-only Google Calendar connection, or null when this build carries no
    // OAuth client id — see [_buildGoogleCalendar]. The one place it is named, like
    // the media engine above it.
    googleCalendar: _buildGoogleCalendar(),
  );

  /// The wakelock state we last pushed to the OS, so [_syncWakelock] toggles the
  /// idle timer only on a real `inCall` transition and not on every socket-frame
  /// notification `AppState` fires.
  bool _wakelockOn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The app is dark-only, so the status bar has to be told once rather than
    // inferred from a light theme that does not exist.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    // Hold the screen awake for as long as a call lasts, like watching a video,
    // so the idle timer cannot lock the phone mid-conversation. Driven off the
    // same `inCall` boolean every widget already listens to.
    _state.addListener(_syncWakelock);
    // The debug drive: a JSON API into this state over the VM service, for an
    // agent or `tool/drive.sh`. The guard must stay the compile-time constant —
    // it is what strips every handler from a release build. See
    // `src/debug_drive/install.dart`.
    if (kDebugMode) {
      installDebugDrive(enabled: kDebugMode, app: _state, boot: 'live');
    }
    _state.boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.removeListener(_syncWakelock);
    // Never leave the idle timer suspended past the app: if we were still holding
    // the screen awake, hand it back on the way out.
    if (_wakelockOn) {
      unawaited(WakelockPlus.disable().catchError((Object e) {
        debugPrint('wakelock: $e');
      }));
    }
    _state.dispose();
    super.dispose();
  }

  /// Mirror `AppState.inCall` onto the OS idle timer: enabled while in a call,
  /// released the moment it ends (hang-up, roster empties, network drop, unpair).
  void _syncWakelock() {
    final shouldHold = _state.inCall;
    if (shouldHold == _wakelockOn) return;
    _wakelockOn = shouldHold;
    // Enhancement, not a requirement: a platform without a wakelock (or a test
    // host) must degrade to normal auto-lock, not crash — the same posture as the
    // Firebase.initializeApp guard in main().
    unawaited(
      (shouldHold ? WakelockPlus.enable() : WakelockPlus.disable())
          .catchError((Object e) {
        debugPrint('wakelock: $e');
      }),
    );
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
