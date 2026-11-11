/// `ext.gc.call.spotlight*`: who the call screen enlarges, and why — the state
/// `docs/sim_test_plan.md` C1–C7 used to be checked by screenshot (plan task
/// 4.1).
///
/// The spotlight is a state machine with a clock: a dwell before a new speaker
/// is promoted, stickiness while the target keeps talking, a linger before a
/// silent big view drops to the grid. Every one of those rules is a moment in
/// time, and a screenshot catches the moment it happens to be taken at. These
/// read the `SpotlightController` the screen itself renders from
/// (`../media/spotlight_controller.dart`), including its record of every change
/// of the face on screen, so "a blip never takes the big view" is "no
/// transition to a non-null target" and "one promotion per turn" is a count.
///
/// Four actions, one controller:
///
///  * `call.spotlight {historyMax?}` — the readout: `mode`, `view`
///    (`empty`/`grid`/`spotlight`), `target`, `since`/`sinceMs`, the raw
///    `decided` picks, `speaking`, `tiles`, the director's `candidate` and
///    `lingering` countdowns, the armed `timer`, `dwellMs`/`lingerMs`,
///    `promotions` and `transitions`. Read-only.
///  * `call.spotlight.mode {mode}` — the header toggle (`auto` | `manual`).
///  * `call.spotlight.pick {id}` — a tap on a face. Yourself in auto is the
///    screen's own no-op, answered `refused('self_in_auto')`.
///  * `call.spotlight.overview` — the return button.
///
/// The three levers are the same public methods the screen's buttons call,
/// and each answers with the readout after it. None is `outward`: the big view
/// is this phone's business. What it changes on the wire is which simulcast
/// layer the SFU sends *us*, which nobody else can see.
///
/// The controller exists only while a call screen is mounted, so every action
/// answers `refused('call_screen_closed')` without one — a closed screen is not
/// "nobody is enlarged", and saying so would be the dishonest empty reading the
/// drive's rules forbid.
///
/// ## The call's own controls (Phase 5)
///
/// [callControlsFeature] adds the dock's buttons to the same `call` namespace —
/// registered as its own [DriveFeature] so the spotlight readers stay screen
/// bound while these need no screen at all:
///
///  * `call.state` — the readout: `hasCall`, `canCall`, `source`
///    (`live`/`scripted`/`none`), `inHuddle`/`inCall`, mic/camera/screen and
///    what is actually being published, `frontCamera`, `audioOutput`,
///    `needsHandoff`, `detail`, `participants`, `connecting`, `unreachable`.
///    With no call yet it says `hasCall: false` rather than reading as a call
///    with everything off.
///  * `call.setMic {on}`, `call.setCamera {on}`, `call.setScreen {on}` — **ops**
///    over `AppState.setMicOn` / `setCameraOn` / `setScreenShareOn`. The first
///    one opens the hardware and the media session (router, node, transports),
///    and screen share waits on the system picker, so none of them may hold the
///    RPC open. **Outward**: they decide what colleagues hear and see — a live
///    mic, your face, your screen — and the mute or the camera going dark is
///    itself visible on their tile. The gate is per action, so `on:false` is
///    gated too — the same rule `gameboy.menu.confirm` follows.
///  * `call.setSpeaker {on}` — `AppState.setSpeakerOn`. Not outward: the route
///    is this phone's loudspeaker or earpiece; nothing on the wire changes.
///  * `call.switchCamera` — `AppState.switchCamera`. **Outward**: with the
///    camera on it changes the picture the room sees (the back camera shows
///    whatever the phone is pointed at). With the camera off the product call is
///    a no-op, so the drive refuses `camera_off` instead of answering ok for
///    nothing.
///  * `call.leave` — `AppState.leaveHuddle`. **Outward** (the plan's (O)): the
///    conversation sees you step out. `refused('not_in_huddle')` when there is
///    none to leave.
///  * `call.rebuild` — an op over `Call.rebuild`, the issue #41 self-heal.
///    Not outward: it republishes exactly what was already published, so the
///    room sees at most the blip any reconnect causes — the same one the app
///    fires on its own after a desktop lock. Documented as a reconnect loop, per
///    the plan's "Test space" section.
///  * `call.pullSessionOver` — an op over `AppState.pullSessionOver`, the
///    issue #67 "Pull session over to this app" button. **Outward**: it takes
///    publishing back from whichever of your devices holds it, which the room
///    sees as your media moving and your other device goes quiet. The button
///    only exists while `needsHandoff` is up, so without it the drive refuses
///    `no_handoff_needed` — a control the screen hides is refused, not performed.
///
/// A sentence back from `AppState` (its null-or-a-sentence contract) is
/// `refused('failed', {detail, state})` — the sentence, and the readout under
/// `state` so it cannot clobber the call's own `detail` — never `ok`.
/// `cannot_call` means there is no call and not enough identity to open one
/// (`AppState.canCall`); `no_call` means the action needs a call that already
/// exists. Every success answers
/// with the `call.state` readout after it.
library;

import '../app_state.dart';
import '../media/call.dart';
import '../media/live_call.dart';
import '../media/spotlight_controller.dart';
import 'debug_drive.dart';
import 'drive_ops.dart';
import 'drive_result.dart';

/// `ext.gc.call.*`. [screens] is the registry the call screen writes to
/// (`spotlightRegistry` in the app); a seam so a test can hand its own.
DriveFeature callFeature({
  required Call? Function() call,
  required String Function() boot,
  SpotlightRegistry? screens,
}) {
  final registry = screens ?? spotlightRegistry;

  Map<String, Object?> readout(SpotlightController c, {int historyMax = kSpotlightHistory}) => {
        'boot': boot(),
        'inCall': call() != null,
        'screens': registry.count,
        ...c.debugSnapshot(historyMax: historyMax),
      };

  DriveResult closed() => DriveResult.refused('call_screen_closed', {'boot': boot()});

  return DriveFeature('call', [
    DriveAction('spotlight', (args) async {
      final historyMax = args.optionalInt('historyMax', min: 0, max: kSpotlightHistory);
      final c = registry.current;
      if (c == null) return closed();
      return DriveResult.ok(readout(c, historyMax: historyMax ?? kSpotlightHistory));
    }),
    DriveAction('spotlight.mode', (args) async {
      final name = args.requireString('mode');
      final mode = SpotlightMode.values.where((m) => m.name == name).firstOrNull;
      if (mode == null) throw DriveInvalidParams('"mode" must be "auto" or "manual"');
      final c = registry.current;
      if (c == null) return closed();
      c.setMode(mode);
      return DriveResult.ok(readout(c));
    }),
    DriveAction('spotlight.pick', (args) async {
      final id = args.requireString('id');
      final c = registry.current;
      if (c == null) return closed();
      final tiles = c.tiles;
      final tile = tiles.where((t) => t.id == id).firstOrNull;
      if (tile == null) {
        return DriveResult.refused('no_such_tile', {
          'id': id,
          'tiles': [for (final t in tiles) t.id],
        });
      }
      if (!c.tap(tile.id, isSelf: tile.isSelf)) {
        return DriveResult.refused('self_in_auto', {'id': id, 'mode': c.mode.name});
      }
      return DriveResult.ok(readout(c));
    }),
    DriveAction('spotlight.overview', (args) async {
      final c = registry.current;
      if (c == null) return closed();
      c.returnToOverview();
      return DriveResult.ok(readout(c));
    }),
  ]);
}

/// `call.state` on its own — also what every control answers with.
Map<String, Object?> callStateReadout(AppState app, {required String boot}) {
  final handle = app.callHandle;
  final c = app.call;
  return {
    'boot': boot,
    'hasCall': handle != null,
    'canCall': app.canCall,
    'source': switch (handle) {
      null => 'none',
      LiveCall() => 'live',
      _ => 'scripted',
    },
    'inHuddle': app.inHuddle,
    'inCall': app.inCall,
    'live': c.live,
    'micOn': c.micOn,
    'cameraOn': c.cameraOn,
    'screenOn': c.screenOn,
    'frontCamera': c.media.frontCamera,
    'audioOutput': c.audioOutput.name,
    'publishingAudio': c.publishingAudio,
    'publishingVideo': c.publishingVideo,
    'publishingScreen': c.publishingScreen,
    'needsHandoff': c.needsHandoff,
    'detail': c.detail,
    'participants': [
      for (final p in c.participants)
        {
          'srcId': p.srcId,
          'hasAudio': p.hasAudio,
          'hasVideo': p.hasVideo,
          'audioPaused': p.audioPaused,
          'videoPaused': p.videoPaused,
          'sharingScreen': p.sharingScreen,
        },
    ],
    'connecting': c.connecting.toList()..sort(),
    'unreachable': c.unreachable.toList()..sort(),
  };
}

/// `ext.gc.call.{state, setMic, setCamera, setScreen, setSpeaker, switchCamera,
/// leave, rebuild, pullSessionOver}` — see the library comment.
DriveFeature callControlsFeature({
  required AppState Function() app,
  required String Function() boot,
  required DriveOps ops,
}) {
  Map<String, Object?> readout() => callStateReadout(app(), boot: boot());

  /// The dock's contract: null took, a sentence did not.
  DriveResult answer(String? failed) =>
      failed == null ? DriveResult.ok(readout()) : DriveResult.refused('failed', {'detail': failed, 'state': readout()});

  /// Mic, camera, screen and speaker open a call on first use, exactly as the
  /// dock's buttons do — unless there is not enough identity to.
  DriveResult? cannotCall() {
    final a = app();
    if (a.callHandle != null || a.canCall) return null;
    return DriveResult.refused('cannot_call', {
      'boot': boot(),
      'detail': 'no call, and not enough identity to open one (not connected to a space yet?)',
    });
  }

  DriveResult noCall() => DriveResult.refused('no_call', {'boot': boot()});

  /// Starts [work] as an op of [kind] and answers its id at once.
  DriveResult asOp(String kind, Future<DriveResult> Function() work) =>
      DriveResult.ok({'id': ops.start(kind, work()), 'kind': kind, 'boot': boot()});

  DriveAction toggle(String name, Future<String?> Function(AppState, bool) set) => DriveAction(
        name,
        (args) async {
          final on = _requireBool(args, 'on');
          final refused = cannotCall();
          if (refused != null) return refused;
          return asOp(name, () async => answer(await set(app(), on)));
        },
        outward: true,
      );

  return DriveFeature('call', [
    DriveAction('state', (args) async => DriveResult.ok(readout())),
    toggle('setMic', (a, on) => a.setMicOn(on)),
    toggle('setCamera', (a, on) => a.setCameraOn(on)),
    toggle('setScreen', (a, on) => a.setScreenShareOn(on)),
    DriveAction('setSpeaker', (args) async {
      final on = _requireBool(args, 'on');
      final refused = cannotCall();
      if (refused != null) return refused;
      return answer(await app().setSpeakerOn(on));
    }),
    DriveAction(
      'switchCamera',
      (args) async {
        final a = app();
        if (a.callHandle == null) return noCall();
        if (!a.call.cameraOn) return DriveResult.refused('camera_off', {'boot': boot()});
        await a.switchCamera();
        return DriveResult.ok(readout());
      },
      outward: true,
    ),
    DriveAction(
      'leave',
      (args) async {
        final a = app();
        if (!a.inHuddle) return DriveResult.refused('not_in_huddle', {'boot': boot()});
        return answer(await a.leaveHuddle());
      },
      outward: true,
    ),
    DriveAction('rebuild', (args) async {
      final handle = app().callHandle;
      if (handle == null) return noCall();
      return asOp('rebuild', () async {
        await handle.rebuild();
        return DriveResult.ok(readout());
      });
    }),
    DriveAction(
      'pullSessionOver',
      (args) async {
        final a = app();
        if (a.callHandle == null) return noCall();
        if (!a.call.needsHandoff) {
          return DriveResult.refused('no_handoff_needed', {
            'boot': boot(),
            'detail': 'the call is not flagged needsHandoff, so the pull-over button is not on screen',
          });
        }
        return asOp('pullSessionOver', () async => answer(await a.pullSessionOver()));
      },
      outward: true,
    ),
  ]);
}

bool _requireBool(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is bool) return value;
  throw DriveInvalidParams(value == null ? '"$key" is required' : '"$key" must be a boolean');
}
