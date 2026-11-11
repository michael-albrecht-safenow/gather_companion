/// `ext.gc.state.dump`: what the app believes, in one read.
///
/// The first question in any check is "where is the app right now" — booted,
/// paired, connected, in which space, standing where, in a call with whom — and
/// answering it from a screenshot means navigating to four screens. This is the
/// same answer from the getters `AppState` already exposes to the UI, so it is
/// what the screen would show and not a second account of it.
///
/// **No secrets, ever.** The Gather refresh and id tokens, the bridge token,
/// cookies and the like are not read here, not even to be masked: a masked field
/// is still a field someone will one day unmask "just for debugging", and a dump
/// is exactly the thing that gets pasted into an issue. `state_dump_test.dart`
/// boots an `AppState` on secret-shaped credentials and asserts none of them
/// appear in the output. Add a field here only if it is something the UI shows.
///
/// `boot` and `testSpace` are here because the same JSON can come from the
/// harness or the live wire, and from the test space or a real office; a reading
/// that does not say which is a reading somebody will misattribute.
library;

import '../app_state.dart';
import 'debug_drive.dart';
import 'drive_result.dart';

/// `ext.gc.state.dump`. [boot] and [inTestSpace] are read per call so a
/// rebound drive reports the new values.
DriveFeature stateFeature({
  required AppState Function() app,
  required String Function() boot,
  required bool Function() inTestSpace,
}) =>
    DriveFeature('state', [
      DriveAction('dump', (_) async => DriveResult.ok(dumpState(app(), boot: boot(), testSpace: inTestSpace()))),
    ]);

/// The dump itself, separate from the action so a test can read it directly.
Map<String, Object?> dumpState(AppState app, {required String boot, required bool testSpace}) {
  final tile = app.myTile;
  final call = app.call;
  final health = app.snapshot.health;
  final phase = switch (app) {
    AppState(isLoaded: false) => 'booting',
    AppState(isConfigured: false) => 'pairing',
    _ => 'home',
  };
  return {
    'boot': boot,
    'phase': phase,
    'loaded': app.isLoaded,
    'configured': app.isConfigured,
    'link': {
      'state': app.link.state.name,
      'detail': app.link.detail,
      'needsPairing': app.link.needsPairing,
    },
    'collector': {
      'healthy': health.gather,
      'logTail': health.logTail,
      'detail': health.detail,
      'canWalk': app.canWalk,
      'canCall': app.canCall,
    },
    'me': {
      'id': app.meId,
      'tile': tile == null ? null : {'x': tile.x, 'y': tile.y},
      'room': tile == null ? null : app.map?.roomAt(tile.x, tile.y)?.name,
      'availability': app.myAvailability,
      'handRaised': app.myHandRaised,
      'atMyDesk': app.atMyDesk,
    },
    'spaceId': app.snapshot.self.spaceId,
    'spaceName': app.spaceName,
    'testSpace': testSpace,
    'roster': {
      'peopleOnMap': app.peopleOnMap.length,
      'followers': app.followers.length,
    },
    'call': {
      'micOn': call.media.audioEnabled,
      'cameraOn': call.media.videoEnabled,
      'screenOn': call.media.screenCapturing,
      'publishingAudio': call.publishingAudio,
      'publishingVideo': call.publishingVideo,
      'participants': call.participants.length,
      'connecting': call.connecting.length,
      'unreachable': call.unreachable.length,
      'detail': call.detail,
      'inHuddle': app.inHuddle,
      'inCall': app.inCall,
    },
    'settings': {
      'gameboyMode': app.gameboyMode,
      'soundEffects': app.soundEffects,
      'partyMode': app.partyMode,
    },
  };
}
