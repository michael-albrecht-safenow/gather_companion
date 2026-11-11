/// `ext.gc.harness.*`: script the simulator scene instead of waiting for the
/// timed one (plan task 5, feature `harness`).
///
/// The app harness (`lib/main_harness.dart`, `TARGET=app`) runs the real
/// `AppState` against a [FakeCollector] (the presence plane) and a
/// [ScriptedCall] (the media plane), with an [AppScenarioDriver] milling the
/// cast about on a 600 ms clock. That is the right thing to watch and the wrong
/// thing to assert against: "is Ada next to me" depends on when you look. These
/// actions put the scene where a check wants it, through the same three objects
/// the scenario itself drives, so everything downstream — `Walk`, the cluster
/// debounce, the call build, the call screen's spotlight — runs for real:
///
/// ```
/// harness.scenario  {"name":"still"}           # nobody wanders off
/// harness.placePerson {"id":"ada","dx":2}      # seat Ada two tiles to my right
/// state.dump                                   # → inHuddle, a call (after ~1.5 s)
/// ui.openCall                                  # the spotlight lives on the call screen
/// call.spotlight.mode {"mode":"auto"}
/// harness.call.speak {"id":"ada"}              # hold the floor on Ada
/// call.spotlight                               # → target space-ada after the dwell
/// ```
///
/// The place → speak → `call.spotlight` flow needs the call screen open: the
/// spotlight controller is the call screen's, so with only the office showing
/// there is nothing to promote anyone. Open the call screen with `ui.openCall`,
/// or tap the in-call banner, before `call.spotlight.mode`.
///
/// ## Why this file lives in `lib/harness/`, and never in a live boot
///
/// It is registered only from `lib/main_harness.dart`, as an `extraFeatures`
/// entry to `installDebugDrive`, inside the same compile-time `kDebugMode`
/// guard. `lib/main.dart` does not import it, so a live debug boot has no
/// `harness.*` names at all, and nothing under `lib/src/` imports `lib/harness/`
/// to make that possible. As a second fence every action refuses
/// `not_harness` when the drive reports any boot but `"harness"` — a test that
/// wires it to a live-booted drive gets a no, not a fake person on a real map.
///
/// ## None of it is outward
///
/// Every action moves, waves, talks or emits on fakes that exist only in this
/// process. Nobody in any Gather space can see it, because no Gather space is
/// involved; so `outward: false` throughout, which is also what lets an agent
/// script the harness without `confirm`.
///
/// ## People
///
/// `id` names one of the *seated* cast (the first `PARTICIPANTS` of
/// [kCast]) by `spaceId` (`space-ada`), media id (`acc-ada`) or name (`Ada`,
/// any case). Anyone else is `refused('no_such_person', {id, people})`.
/// `harness.call.speak` also takes `"me"`.
///
/// ## Holds
///
/// The scenario's clock rewrites the speaking rings and the call state every
/// tick. `harness.call.speak` and `harness.call.emit` therefore *hold* what they
/// set on the driver ([AppScenarioDriver.heldSpeakers] /
/// [AppScenarioDriver.heldCall]) until `{"release":true}` hands it back —
/// otherwise the ring would last 600 ms and a spotlight check would flake. The
/// first `call.speak` takes the whole floor: from then on exactly the held
/// voices are lit (`{"id":"ada"}` → only Ada; `{"id":"me"}` adds me;
/// `{"id":"ada","speaking":false}` drops her).
/// Placements are not held: in the `office` scenario a placed person who is
/// out of call range keeps milling, which the readout says (`scenario`). Switch
/// to `still` for a placement to stick.
///
/// Every action answers with [harnessReadout] after applying the change.
library;

import 'dart:math';

import '../src/debug_drive/debug_drive.dart';
import '../src/debug_drive/drive_result.dart';
import '../src/media/call.dart';
import '../src/media/media_engine.dart';
import 'call_scenarios.dart';
import 'fake_collector.dart';
import 'harness_data.dart';
import 'scripted_call.dart';

/// `ext.gc.harness.{placePerson, stepPerson, wave, call.emit, call.speak, scenario}`.
DriveFeature harnessFeature({
  required FakeCollector collector,
  required ScriptedCall call,
  required AppScenarioDriver driver,
  required String Function() boot,
}) {
  DriveResult? notHarness() =>
      boot() == 'harness' ? null : DriveResult.refused('not_harness', {'boot': boot()});

  DriveResult ok() => DriveResult.ok(harnessReadout(collector: collector, call: call, driver: driver, boot: boot()));

  DriveResult noSuchPerson(String id) => DriveResult.refused('no_such_person', {
        'id': id,
        'people': collector.peopleIds.toList(),
      });

  return DriveFeature('harness', [
    DriveAction('placePerson', (args) async {
      final id = args.requireString('id');
      final x = args.optionalInt('x', min: 0, max: kOfficeWidth - 1);
      final y = args.optionalInt('y', min: 0, max: kOfficeHeight - 1);
      final dx = args.optionalInt('dx');
      final dy = args.optionalInt('dy');
      final direction = args.containsKey('direction') ? _requireDirection(args) : null;
      if ((x != null || y != null) && (dx != null || dy != null)) {
        throw const DriveInvalidParams('pass "x"/"y" (a tile) or "dx"/"dy" (an offset from me), not both');
      }
      if (x == null && y == null && dx == null && dy == null) {
        throw const DriveInvalidParams('pass "x"/"y" (a tile) or "dx"/"dy" (an offset from me)');
      }
      final refused = notHarness();
      if (refused != null) return refused;
      final who = _resolve(collector, id);
      if (who == null) return noSuchPerson(id);
      final at = collector.standing(who)!;
      final me = collector.selfTile;
      final tx = x ?? (dx != null || dy != null ? me.x + (dx ?? 0) : at.x);
      final ty = y ?? (dx != null || dy != null ? me.y + (dy ?? 0) : at.y);
      if (tx < 0 || tx >= kOfficeWidth || ty < 0 || ty >= kOfficeHeight) {
        return DriveResult.refused('off_floor', {
          'x': tx,
          'y': ty,
          'width': kOfficeWidth,
          'height': kOfficeHeight,
        });
      }
      collector.placePerson(who, x: tx, y: ty, direction: direction);
      driver.settle();
      return ok();
    }),
    DriveAction('stepPerson', (args) async {
      final id = args.requireString('id');
      final direction = _requireDirection(args);
      final steps = args.optionalInt('steps', min: 1, max: kOfficeWidth + kOfficeHeight) ?? 1;
      final refused = notHarness();
      if (refused != null) return refused;
      final who = _resolve(collector, id);
      if (who == null) return noSuchPerson(id);
      for (var i = 0; i < steps; i++) {
        collector.stepPerson(who, direction);
      }
      driver.settle();
      return ok();
    }),
    DriveAction('wave', (args) async {
      final from = args.requireString('from');
      final refused = notHarness();
      if (refused != null) return refused;
      final who = _resolve(collector, from);
      if (who == null) return noSuchPerson(from);
      // An *incoming* wave on the event bus — what reaches the Activity feed
      // through `AppState._noteActivity`, exactly as the scenario's own waves do.
      collector.injectWave(who);
      return DriveResult.ok({
        'waved': {'from': who, 'to': kSelfId},
        ...harnessReadout(collector: collector, call: call, driver: driver, boot: boot()),
      });
    }),
    DriveAction('call.emit', (args) async {
      final release = _optionalBool(args, 'release') ?? false;
      final raw = args['participants'];
      if (release && raw != null) {
        throw const DriveInvalidParams('pass "participants" or "release", not both');
      }
      if (!release && raw is! List) {
        throw const DriveInvalidParams('"participants" must be a list of {id, audio?, video?, audioPaused?, videoPaused?, screen?}');
      }
      final publishingAudio = _optionalBool(args, 'publishingAudio') ?? true;
      final specs = <({String id, bool audio, bool video, bool audioPaused, bool videoPaused, bool screen})>[];
      if (!release) {
        for (final (i, entry) in (raw! as List).indexed) {
          if (entry is! Map) throw DriveInvalidParams('"participants[$i]" must be an object');
          final m = entry.cast<String, Object?>();
          final id = m['id'];
          if (id is! String || id.isEmpty) throw DriveInvalidParams('"participants[$i].id" must be a non-empty string');
          specs.add((
            id: id,
            audio: _optionalBool(m, 'audio', at: 'participants[$i].') ?? true,
            video: _optionalBool(m, 'video', at: 'participants[$i].') ?? false,
            audioPaused: _optionalBool(m, 'audioPaused', at: 'participants[$i].') ?? false,
            videoPaused: _optionalBool(m, 'videoPaused', at: 'participants[$i].') ?? false,
            screen: _optionalBool(m, 'screen', at: 'participants[$i].') ?? false,
          ));
        }
      }
      final refused = notHarness();
      if (refused != null) return refused;
      if (release) {
        driver.heldCall = null;
        driver.settle();
        return ok();
      }
      final participants = <CallParticipant>[];
      for (final spec in specs) {
        final who = _resolve(collector, spec.id);
        if (who == null) return noSuchPerson(spec.id);
        participants.add(CallParticipant(
          srcId: collector.standing(who)!.person.accountId,
          hasAudio: spec.audio,
          hasVideo: spec.video,
          audioPaused: spec.audioPaused,
          videoPaused: spec.videoPaused,
          sharingScreen: spec.screen,
        ));
      }
      driver.heldCall = CallState(
        media: const LocalMediaState(capturing: true, audioEnabled: true),
        publishingAudio: publishingAudio,
        participants: participants,
      );
      driver.settle();
      return ok();
    }),
    DriveAction('call.speak', (args) async {
      final release = _optionalBool(args, 'release') ?? false;
      final id = args['id'];
      if (release && id != null) throw const DriveInvalidParams('pass "id" or "release", not both');
      final name = release ? null : args.requireString('id');
      final speaking = _optionalBool(args, 'speaking') ?? true;
      final refused = notHarness();
      if (refused != null) return refused;
      if (release) {
        driver.heldSpeakers = null;
        driver.settle();
        return ok();
      }
      final who = name!.toLowerCase() == kSelfId ? kSelfId : _resolve(collector, name);
      if (who == null) return noSuchPerson(name);
      // The first hold starts empty: once the drive has the floor, the rotation
      // and the babble stand down entirely, so "only Ada is talking" is a state
      // one call reaches rather than a race with the scenario's last pick.
      final held = driver.heldSpeakers ?? const <String>{};
      driver.heldSpeakers = speaking ? ({...held, who}) : ({...held}..remove(who));
      driver.settle();
      return ok();
    }),
    DriveAction('scenario', (args) async {
      final name = args.requireString('name');
      final scenario = AppScenario.values.where((s) => s.name.toLowerCase() == name.toLowerCase()).firstOrNull;
      if (scenario == null) {
        throw DriveInvalidParams('"name" must be one of ${AppScenario.values.map((s) => s.name).join(', ')}');
      }
      final refused = notHarness();
      if (refused != null) return refused;
      driver.scenario = scenario;
      return ok();
    }),
  ]);
}

/// The scene as the harness holds it: me, everyone seated, who is in call range,
/// the holds, and what the scripted call is carrying. Distances are tiles,
/// Euclidean, against [FakeCollector.kCallRange] — the same test the fake uses to
/// put somebody in my cluster.
Map<String, Object?> harnessReadout({
  required FakeCollector collector,
  required ScriptedCall call,
  required AppScenarioDriver driver,
  required String boot,
}) {
  final me = collector.selfTile;
  final mates = {for (final p in collector.callmates) p.spaceId};
  final held = driver.heldSpeakers;
  final pinned = driver.heldCall;
  return {
    'boot': boot,
    'scenario': driver.scenario.name,
    'callRange': FakeCollector.kCallRange,
    'me': {'id': kSelfId, 'x': me.x, 'y': me.y, 'speaking': call.isSpeaking},
    'people': [
      for (final id in collector.peopleIds)
        if (collector.standing(id) case final s?)
          {
            'id': id,
            'accountId': s.person.accountId,
            'name': s.person.name,
            'x': s.x,
            'y': s.y,
            'direction': s.direction,
            'speaking': s.speaking,
            'distance': _distance(s.x - me.x, s.y - me.y),
            'inCallRange': mates.contains(id),
          },
    ],
    'callmates': mates.toList(),
    'heldSpeakers': held?.toList(),
    'heldCall': pinned != null,
    'call': {
      'participants': [
        for (final p in call.state.participants)
          {
            'srcId': p.srcId,
            'audio': p.hasAudio,
            'video': p.hasVideo,
            'audioPaused': p.audioPaused,
            'videoPaused': p.videoPaused,
            'screen': p.sharingScreen,
          },
      ],
      'publishingAudio': call.state.publishingAudio,
    },
  };
}

/// Two decimals: enough to see 2.83 against 3, without float noise in the JSON.
double _distance(int dx, int dy) => (sqrt(dx * dx + dy * dy) * 100).round() / 100;

/// A seated person's `spaceId` from any of their three spellings, or null.
String? _resolve(FakeCollector collector, String id) {
  final want = id.toLowerCase();
  for (final p in collector.peopleIds) {
    final s = collector.standing(p)!;
    if (p.toLowerCase() == want ||
        s.person.accountId.toLowerCase() == want ||
        s.person.name.toLowerCase() == want) {
      return p;
    }
  }
  return null;
}

/// The D-pad's own spelling (`Up`, `Down`, `Left`, `Right`), accepted in any case.
String _requireDirection(Map<String, Object?> args) {
  final raw = args.requireString('direction');
  for (final d in const ['Up', 'Down', 'Left', 'Right']) {
    if (d.toLowerCase() == raw.toLowerCase()) return d;
  }
  throw const DriveInvalidParams('"direction" must be one of up, down, left, right');
}

bool? _optionalBool(Map<String, Object?> args, String key, {String at = ''}) {
  final value = args[key];
  if (value == null || value is bool) return value as bool?;
  throw DriveInvalidParams('"$at$key" must be true or false');
}
