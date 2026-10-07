/// Scripts a multi-party call forward in time, so the call screen animates on a
/// simulator with no network behind it.
///
/// The decision — who is in the call, who is talking, right now — is a pure
/// function of elapsed time ([scenarioFrame]); [CallScenarioDriver] is the thin
/// part that owns a timer and pushes each frame into [AppState] through its test
/// seams. Keeping the decision pure is what lets `call_scenario_driver_test.dart`
/// assert a whole scenario without a clock, the same split
/// `spotlight_director.dart` keeps one level down.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../src/media/call.dart';
import '../src/media/media_engine.dart';
import 'fake_collector.dart';
import 'harness_data.dart';
import 'scripted_call.dart';

/// The shapes of call the harness can play.
enum Scenario {
  /// Just me. The spotlight has nobody to follow — the empty baseline.
  solo,

  /// Me and one other, who talks in bursts.
  pair,

  /// A few people, nobody talking. The manual-mode grid at rest.
  group,

  /// Each person takes the floor for 3s in turn. Auto mode should follow,
  /// promoting one speaker per turn with no jump between.
  roundRobin,

  /// Two dominant speakers. One holds the floor, the other talks over without
  /// stealing it (sticky), then the first stops and the second earns it.
  debate,

  /// Short blips, none held past the 1.5s dwell. Auto mode must stay on the
  /// overview — the cough-and-chair-scrape rejection test.
  briefNoise,

  /// People join and leave mid-call. Tiles and the strip track it; the spotlight
  /// target survives or re-floors cleanly.
  churn;

  static Scenario fromName(String name) => Scenario.values.firstWhere(
        (s) => s.name.toLowerCase() == name.toLowerCase(),
        orElse: () => Scenario.group,
      );
}

/// A single moment of a scenario: who is present, who is audible, and whether I
/// am talking.
@immutable
class ScenarioFrame {
  const ScenarioFrame({
    required this.count,
    required this.speaking,
    this.ownSpeaking = false,
  });

  /// How many of [kCast] are in the call this instant.
  final int count;

  /// The `accountId`s talking right now.
  final Set<String> speaking;

  /// Whether my own ring is lit.
  final bool ownSpeaking;

  @override
  bool operator ==(Object other) =>
      other is ScenarioFrame &&
      other.count == count &&
      other.ownSpeaking == ownSpeaking &&
      setEquals(other.speaking, speaking);

  @override
  int get hashCode => Object.hash(count, ownSpeaking, Object.hashAllUnordered(speaking));

  @override
  String toString() =>
      'ScenarioFrame(count: $count, speaking: $speaking, ownSpeaking: $ownSpeaking)';
}

/// The dwell the auto spotlight gates on. Scenarios are timed around it.
const Duration kDwell = Duration(milliseconds: 1500);

String _acc(int i) => kCast[i].accountId;

/// Who is where, and talking, at [elapsed] into [scenario] with [participants]
/// seated at the start. Pure: the same inputs always give the same frame.
ScenarioFrame scenarioFrame(
  Scenario scenario,
  Duration elapsed,
  int participants,
) {
  final ms = elapsed.inMilliseconds;
  final n = participants.clamp(0, castSize);

  switch (scenario) {
    case Scenario.solo:
      return const ScenarioFrame(count: 0, speaking: {});

    case Scenario.pair:
      // One other, talking 2.5s on / 1s off.
      const count = 1;
      final on = ms % 3500 < 2500;
      return ScenarioFrame(count: count, speaking: on ? {_acc(0)} : const {});

    case Scenario.group:
      return ScenarioFrame(count: n, speaking: const {});

    case Scenario.roundRobin:
      if (n == 0) return const ScenarioFrame(count: 0, speaking: {});
      // Each holds the floor 3s — twice the dwell — so every turn promotes.
      final active = (ms ~/ 3000) % n;
      return ScenarioFrame(count: n, speaking: {_acc(active)});

    case Scenario.debate:
      final count = n < 2 ? 2 : n;
      // A 12s cycle: A earns it, B talks over (A sticky), A stops, B earns it.
      final t = ms % 12000;
      final Set<String> speaking;
      if (t < 5000) {
        speaking = {_acc(0)}; // A holds the floor.
      } else if (t < 7000) {
        speaking = {_acc(0), _acc(1)}; // B over A — A keeps it.
      } else {
        speaking = {_acc(1)}; // A done; B holds long enough to earn it.
      }
      return ScenarioFrame(count: count, speaking: speaking);

    case Scenario.briefNoise:
      if (n == 0) return const ScenarioFrame(count: 0, speaking: {});
      // 1.5s slots; a different person blips for only the first 800ms of each —
      // under the dwell — so nobody is ever promoted.
      final slot = ms ~/ 1500;
      final blip = ms % 1500 < 800;
      final who = slot % n;
      return ScenarioFrame(count: n, speaking: blip ? {_acc(who)} : const {});

    case Scenario.churn:
      final base = n < 2 ? 2 : n;
      // Drop to base-2 and back, 2s a step, so people leave and rejoin.
      const steps = [0, 1, 2, 1];
      final drop = steps[(ms ~/ 2000) % steps.length];
      final count = (base - drop).clamp(1, castSize);
      // Round-robin the floor among whoever is present.
      final active = (ms ~/ 3000) % count;
      return ScenarioFrame(count: count, speaking: {_acc(active)});
  }
}

/// Plays a [Scenario] into an [AppState] by pushing a fresh roster and call state
/// on every tick, the same two seams `call_screen_test.dart` uses by hand.
class CallScenarioDriver {
  CallScenarioDriver({
    required this.state,
    required this.call,
    required this.scenario,
    required this.participants,
    this.period = const Duration(milliseconds: 250),
  });

  final AppState state;
  final ScriptedCall call;
  final Scenario scenario;
  final int participants;

  /// How often the scene is re-evaluated. Finer than the dwell so the ring and
  /// the promotion timer both look live.
  final Duration period;

  Timer? _timer;
  int _ticks = 0;

  /// The state the self tile needs to exist: the camera "open", so `_tiles`
  /// draws a "You" avatar at the head of the strip.
  static const _selfMedia = LocalMediaState(capturing: true, audioEnabled: true);

  /// Applies the frame at [elapsed]. Public and clock-free so a test can step the
  /// scenario without a timer.
  void applyAt(Duration elapsed) {
    final frame = scenarioFrame(scenario, elapsed, participants);
    // Call state first — the roster push below is what notifies the screen, and
    // the rebuild then reads this. Participants carry audio; video stays off, so
    // tiles are avatars.
    call.emit(CallState(
      media: _selfMedia,
      publishingAudio: true,
      participants: participantsFor(frame.count),
    ));
    call.speak(frame.ownSpeaking);
    // This harness is the one lib entrypoint that drives the test seams on
    // purpose — the roster push is what notifies the screen.
    // ignore: invalid_use_of_visible_for_testing_member
    state.debugApplyRoster(
      rosterFor(frame.count, speakingAccountIds: frame.speaking),
    );
  }

  /// Seeds the first frame and starts the clock.
  void start() {
    applyAt(Duration.zero);
    _ticks = 0;
    _timer = Timer.periodic(period, (_) {
      _ticks++;
      applyAt(period * _ticks);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

// ---- the office -------------------------------------------------------------

/// The shapes of office the whole-app harness (TARGET=app) can play.
enum AppScenario {
  /// People drift around the floor and somebody waves every few seconds — the
  /// map and the Activity tab both alive.
  office,

  /// Nobody moves. The resting floor, for looking at one frame.
  still;

  static AppScenario fromName(String name) => AppScenario.values.firstWhere(
        (s) => s.name.toLowerCase() == name.toLowerCase(),
        orElse: () => AppScenario.office,
      );
}

/// Animates the office by driving a [FakeCollector]: walks the cast around the
/// floor and lands waves in the activity feed, so the map and the Activity tab
/// are alive on a sim with no network.
///
/// This moves *other* people — the fake playing the server's position frames. My
/// own avatar is driven by the real `Walk` off the D-pad and is never touched
/// here, which is the whole point: the thing under test (walking, following,
/// party mode) runs for real against the same fake.
///
/// It also plays the *call*. When I warp next to someone (the Dial tab) or walk
/// into them on the floor, [FakeCollector.callmates] fills, the roster puts us in
/// one cluster, and this driver pushes the matching [CallState] onto the injected
/// [ScriptedCall] and rotates a speaking ring — so the call screen lights up with
/// real faces, reached through the app's own paths rather than mounted directly
/// the way `TARGET=call` does. The people beside me stop milling while we talk,
/// so the call holds until I walk away.
class AppScenarioDriver {
  AppScenarioDriver({
    required this.state,
    required this.collector,
    required this.call,
    this.scenario = AppScenario.office,
    this.period = const Duration(milliseconds: 600),
  });

  final AppState state;
  final FakeCollector collector;
  final ScriptedCall call;
  final AppScenario scenario;
  final Duration period;

  /// A six-step loop with zero net displacement, so people mill about near where
  /// they started rather than all piling into a corner against the clamp.
  static const _wander = ['Right', 'Right', 'Down', 'Left', 'Left', 'Up'];

  /// The self tile's media, so the call screen draws a "You" avatar at the head
  /// of the strip. Same state `CallScenarioDriver` uses.
  static const _selfMedia = LocalMediaState(capturing: true, audioEnabled: true);

  Timer? _timer;
  int _ticks = 0;
  bool _wasInCall = false;

  final Random _rng = Random();

  /// Per-person talking bursts, in ticks still to run. A person with a positive
  /// count is mid-burst; zero means silent and free to start a fresh one. Driving
  /// speech off this — rather than the tick parity — is what makes talkers come
  /// and go independently instead of handing the floor round one at a time.
  final Map<String, int> _speakingTicksLeft = {};

  /// Seeds the activity history and starts the clock. The timer runs even on
  /// [AppScenario.still] — the cast stay put there, but a warp still has to form
  /// a call, which is what each tick drives.
  void start() {
    _seedActivity();
    _timer = Timer.periodic(period, (_) => _tick());
  }

  /// A few waves already waiting when the app opens, newest first — the Activity
  /// tab's equivalent of opening the app after a weekend. Pushed through the same
  /// seam `call_screen_test.dart` uses by hand.
  void _seedActivity() {
    final now = DateTime.now().toUtc();
    final ids = collector.peopleIds.toList();
    final items = <ActivityItem>[
      for (var i = 0; i < ids.length && i < 4; i++)
        WaveActivity(
          id: 'seed-wave-$i',
          at: now.subtract(Duration(minutes: (i + 1) * 7)),
          actorSpaceUserId: ids[i],
        ),
    ];
    // The one lib entrypoint that drives the test seams on purpose.
    // ignore: invalid_use_of_visible_for_testing_member
    state.debugApplyActivity(items);
  }

  void _tick() {
    _ticks++;
    final mates = collector.callmates;
    final mateIds = {for (final p in mates) p.spaceId};
    final ids = collector.peopleIds.toList();

    final milling = scenario != AppScenario.still;
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      // Whoever is in my call stays put, so the conversation holds until I walk
      // away rather than someone wandering out of range a tick later.
      if (mateIds.contains(id)) continue;
      if (milling) {
        collector.stepPerson(id, _wander[(_ticks + i) % _wander.length]);
      }
      // Each of the *rest* talks in their own random bursts: a silent person
      // starts one with a small chance each tick, then holds the floor for a
      // random spell (2–6 ticks ≈ 1.2–3.6s at the 600ms period). Independent
      // draws mean nobody owns the floor on a rota and several can be lit at
      // once — a real babble rather than a hand-off round robin. Call-mates'
      // rings are driven below; a still office stays quiet.
      var left = _speakingTicksLeft[id] ?? 0;
      if (milling && left == 0 && _rng.nextDouble() < 0.18) {
        left = 2 + _rng.nextInt(5);
      }
      collector.placePerson(id, speaking: left > 0);
      _speakingTicksLeft[id] = left > 0 ? left - 1 : 0;
    }

    _driveCall(mates);
    collector.publish();

    // A wave into the feed every ~5s.
    if (milling && ids.isNotEmpty && _ticks % 8 == 0) {
      collector.wave(ids[(_ticks ~/ 8) % ids.length]);
    }
  }

  /// Plays the call with whoever is standing beside me. Rotates the floor among
  /// the [mates] and my own voice so every tile's ring animates, and pushes the
  /// matching media-plane state onto the [ScriptedCall]. When nobody is near, the
  /// call empties once and goes quiet.
  ///
  /// The roster rows for [mates] are re-marked here each tick (by [collector]'s
  /// `placePerson`) so the map ring and the call-screen ring agree; the call
  /// state carries the same people as audio-only participants.
  void _driveCall(List<CallPerson> mates) {
    if (mates.isEmpty) {
      if (_wasInCall) {
        call.emit(const CallState());
        call.speak(false);
        _wasInCall = false;
      }
      return;
    }
    _wasInCall = true;

    // The floor passes between the people beside me and, every few turns, me —
    // one speaker at a time, changing about every 1.2s (two 600ms ticks).
    final turn = (_ticks ~/ 2) % (mates.length + 1);
    final ownSpeaking = turn == mates.length;
    for (var i = 0; i < mates.length; i++) {
      collector.placePerson(mates[i].spaceId, speaking: !ownSpeaking && i == turn);
    }
    call.speak(ownSpeaking);
    call.emit(CallState(
      media: _selfMedia,
      publishingAudio: true,
      participants: participantsForPeople(mates),
    ));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
