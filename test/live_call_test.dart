/// [LiveCall] — the two buttons, and the order everything has to happen in.
///
/// Driven end to end: a real [SfuSession] over the shared [Rig], with only the
/// hardware and mediasoup faked. So these assert on what actually reached the
/// wire rather than on a mock being called, which is the difference between
/// testing the code and testing the test.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/media/live_call.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/src/media/sfu_session.dart';
import 'package:gather_companion/src/media/voice_activity.dart';

import 'fake_capture_engine.dart';
import 'sfu_rig.dart';

void main() {
  late Rig rig;
  late FakeCaptureEngine engine;
  late LiveCall call;

  setUp(() {
    rig = Rig();
    engine = FakeCaptureEngine();
    call = LiveCall(
      auth: GatherAuth(
        credentials: const GatherCredentials(refreshToken: 'unused'),
      ),
      spaceId: spaceId,
      srcId: me,
      engine: engine,
      buildSfu: () => rig.session,
      // No hold, so a stop is visible on the next poll rather than a second
      // later. What the real hold does is asserted in `voice_activity_test.dart`;
      // what these want to know is whether the poll runs at all, and when.
      voice: VoiceActivity(hold: Duration.zero),
    );
  });

  tearDown(() async {
    await call.dispose();
    await rig.close();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('the microphone', () {
    test('opens capture with only the tracks in use, and publishes it',
        () async {
      expect(await call.setMicOn(true), isNull);

      expect(engine.calls, contains('startCapture(audio: true, video: false)'));
      expect(rig.node().argsFor('produce')?['tag'], 'audio');
      expect(call.state.publishingAudio, isTrue);
      expect(call.state.micOn, isTrue);
    });

    test('muting stops the device and pauses the stream, keeping the producer',
        () async {
      await call.setMicOn(true);
      rig.node().drain();

      await call.setMicOn(false);

      // Both halves, and neither is redundant: the device mute is what makes iOS
      // drop the orange indicator, the pause is what draws the crossed-out
      // microphone next to your name on everybody else's screen.
      expect(engine.calls, contains('setAudioEnabled(false)'));
      expect(rig.node().argsFor('produce-pause'), {'tag': 'audio'});
      expect(rig.session.publishing(SfuTag.audio), isTrue,
          reason: 'closing it would make unmuting a fresh negotiation');
    });
  });

  group('speaking', () {
    // The poll interval, plus enough slack for the platform-channel round trip
    // the fake is standing in for.
    Future<void> poll() =>
        Future<void>.delayed(const Duration(milliseconds: 280));

    test('a live microphone with somebody talking into it says so', () async {
      await call.setMicOn(true);
      final said = <bool>[];
      call.speaking.listen(said.add);

      rig.micProducer!.level = 0.09;
      await poll();

      expect(said, [true]);
      expect(call.isSpeaking, isTrue);

      rig.micProducer!.level = 0.0004;
      await poll();

      expect(said, [true, false]);
    });

    test('a quiet room is never reported as talking', () async {
      await call.setMicOn(true);
      final said = <bool>[];
      call.speaking.listen(said.add);

      // The level measured on the phone in a silent room on 2026-09-17. The
      // whole feature is worthless if this lights the ring.
      rig.micProducer!.level = 0.00104;
      await poll();
      await poll();

      expect(said, isEmpty);
      expect(call.isSpeaking, isFalse);
    });

    test('muting stops it at once, and stops the polling with it', () async {
      await call.setMicOn(true);
      rig.micProducer!.level = 0.09;
      await poll();
      final said = <bool>[];
      call.speaking.listen(said.add);

      await call.setMicOn(false);
      await settle();

      // On the tap itself, not on the next poll and certainly not after the
      // hold — either would leave a ring lit on everybody else's screen for
      // somebody who has already pressed mute mid-sentence.
      expect(said, [false]);
      expect(call.isSpeaking, isFalse);

      // And nothing starts it again while muted, however loud the room is: the
      // producer is paused, so the level is not even read.
      await poll();
      await poll();
      expect(said, [false]);
    });

    test('nothing is polled before the microphone is ever turned on', () async {
      final said = <bool>[];
      call.speaking.listen(said.add);

      await call.setListeningTo({them});
      await poll();

      // A phone sitting in a conversation listening runs no timer and holds no
      // microphone, which is the difference between this and a call app.
      expect(said, isEmpty);
      expect(rig.micProducer, isNull);
    });
  });

  group('the camera', () {
    test('turning it on later restarts capture and republishes both tracks',
        () async {
      await call.setMicOn(true);
      rig.node().drain();

      expect(await call.setCameraOn(true), isNull);

      // The capture session holds exactly the tracks in use, so growing it means
      // restarting it — the alternative, capturing video and leaving the track
      // disabled, keeps the camera light on for a camera nobody asked for.
      expect(engine.calls, containsAllInOrder(<String>[
        'startCapture(audio: true, video: false)',
        'stopCapture',
        'startCapture(audio: true, video: true)',
      ]));
      final produced = rig.node()
          .sent
          .where((f) => f.method == 'produce')
          .map((f) => f.args['tag'])
          .toList();
      expect(produced, containsAll(<String>['audio', 'video']));
      expect(call.state.publishingVideo, isTrue);
    });
  });

  group('sharing the screen (issue #43)', () {
    test('opens its own capture and publishes it as a screen producer',
        () async {
      expect(await call.setScreenShareOn(true), isNull);

      expect(engine.calls, contains('startScreenCapture'));
      expect(rig.node().argsFor('produce')?['tag'], 'screen');
      expect(call.state.publishingScreen, isTrue);
      expect(call.state.screenOn, isTrue);
    });

    test('is a second capture that leaves the camera/mic session untouched',
        () async {
      await call.setMicOn(true);
      await call.setCameraOn(true);
      rig.node().drain();

      // Sharing must not restart the camera capture — that would cut audio and
      // flip the picture — so no `stopCapture`/`startCapture` follows the share.
      final before = engine.calls.length;
      expect(await call.setScreenShareOn(true), isNull);
      final after = engine.calls.sublist(before);
      expect(after, contains('startScreenCapture'));
      expect(after, isNot(contains('stopCapture')));
      expect(after, isNot(contains('startCapture(audio: true, video: true)')));

      expect(rig.node().argsFor('produce')?['tag'], 'screen');
      // The camera producer is still up: a screen share does not replace the face.
      expect(call.state.publishingVideo, isTrue);
      expect(call.state.publishingScreen, isTrue);
    });

    test('stopping it closes the producer and releases only the screen capture',
        () async {
      await call.setScreenShareOn(true);
      rig.node().drain();

      await call.setScreenShareOn(false);

      expect(rig.node().argsFor('produce-close'), {'tag': 'screen'});
      expect(engine.calls, contains('stopScreenCapture'));
      expect(rig.session.publishing(SfuTag.screen), isFalse);
      expect(call.state.publishingScreen, isFalse);
      expect(call.state.screenOn, isFalse);
    });

    test('the OS ending the broadcast drops the producer on its own', () async {
      await call.setScreenShareOn(true);
      rig.node().drain();

      // No tap in the app — the system "Stop" control ended it, which the engine
      // reports as the screen capture simply vanishing.
      engine.endScreenFromOs();
      await settle();

      expect(rig.node().argsFor('produce-close'), {'tag': 'screen'});
      expect(call.state.publishingScreen, isFalse);
      expect(call.state.screenOn, isFalse);
    });

    test('a declined picker leaves the button off and says why', () async {
      engine.failScreenWith = const MediaFailure(
        MediaFailureKind.unknown,
        'Screen sharing did not start. Tap it again and allow the broadcast.',
      );

      final detail = await call.setScreenShareOn(true);

      expect(detail, isNotNull);
      expect(call.state.publishingScreen, isFalse);
      expect(call.state.screenOn, isFalse);
      expect(rig.sockets, isEmpty,
          reason: 'a capture that never opened connects nothing to publish onto');
    });

    test('survives the camera restart that adding video forces', () async {
      // Turning the camera on with only the mic open restarts the capture
      // session. That tears the camera/mic stream down and back up — but the
      // screen is a separate capture and must ride through untouched, or the
      // engine would look like the broadcast ended and the producer would be
      // dropped the moment somebody turned their camera on.
      await call.setMicOn(true);
      await call.setScreenShareOn(true);
      rig.node().drain();

      await call.setCameraOn(true);
      await settle();

      expect(call.state.publishingScreen, isTrue,
          reason: 'the share was not caught in the camera restart');
      expect(call.state.screenOn, isTrue);
      expect(rig.session.publishing(SfuTag.screen), isTrue);
      // And it was not needlessly republished — the capture never stopped.
      expect(
        rig.node().sent.where(
            (f) => f.method == 'produce' && f.args['tag'] == 'screen'),
        isEmpty,
        reason: 'the screen producer was left alone, not torn down and rebuilt',
      );
    });

    test('a lost socket puts the screen share back with everything else',
        () async {
      await call.setScreenShareOn(true);
      rig.node().drain();

      rig.node().drop();
      rig.node().comeBack();
      await settle();
      await settle();
      await settle();

      expect(rig.node().argsFor('produce')?['tag'], 'screen',
          reason: 'the screen producer died with the socket and was put back');
      expect(call.state.publishingScreen, isTrue);
    });
  });

  group('being in a conversation', () {
    test('connects the media plane without anybody tapping anything', () async {
      // The fix this pins, and the reason it matters: the SFU socket is what
      // carries *other people's* audio. Waiting for a tap meant the phone could
      // not hear a conversation until it started talking in one.
      await call.setListeningTo({them});

      expect(rig.session.ready, isTrue);
      expect(rig.node().has('consume-request'), isTrue);
      // The audio session is configured so the sound lands on the loudspeaker
      // the moment it arrives — but no *capture* is opened, so there is still no
      // permission prompt and no indicator for something nobody asked for.
      expect(engine.calls, ['prepareAudioSession']);
      expect(call.state.media.capturing, isFalse);
    });

    test('standing alone opens nothing at all', () async {
      await call.setListeningTo(const {});

      expect(rig.sockets, isEmpty);
    });

    test('who may see us is handed over before the first track goes out',
        () async {
      await call.setVisibleTo({them});
      await call.setMicOn(true);

      final order = rig.node().sent.map((f) => f.method).toList();
      expect(order.contains('consume-allow'), isTrue);
      expect(order.indexOf('consume-allow'), lessThan(order.indexOf('produce')),
          reason: 'publishing into an empty allow list reaches nobody');
    });

    test('the conversation id reaches the node, once it exists', () async {
      await call.setConversation('bubble-1');
      await call.setMicOn(true);
      await settle();

      expect(rig.node().argsFor('set-player-conversation-metadata'),
          {'meetingId': '', 'clusterId': 'bubble-1'});
    });
  });

  group('when the wire fails', () {
    test('a lost socket gets the same tracks put back', () async {
      await call.setMicOn(true);
      rig.node().drain();

      rig.node().drop();
      rig.node().comeBack();
      await settle();
      await settle();
      await settle();

      expect(rig.node().sent.where((f) => f.method == 'produce'), hasLength(1),
          reason: 'the producers died with the socket and only this class '
              'holds the tracks');
      expect(call.state.publishingAudio, isTrue);
    });

    test('a publish that fails leaves the button on and says why', () async {
      // Connect first, so the failure comes from the wire rather than from
      // there being no wire.
      await call.setListeningTo({them});
      rig.node().failing.add('produce');

      final detail = await call.setMicOn(true);

      // The hardware is live and only the wire failed, so flipping the button
      // back would read as the tap not registering.
      expect(detail, isNotNull);
      expect(call.state.micOn, isTrue);
      expect(call.state.publishingAudio, isFalse);
      expect(call.state.detail, contains('has not picked up'));
    });

    test('the Mac taking it back is named, with what to do about it', () async {
      await call.setMicOn(true);

      for (var i = 0; i < 3; i++) {
        rig.node().push('double-connected', const {});
      }
      await settle();
      await settle();

      expect(rig.session.displaced, isTrue);
      expect(call.state.detail, contains('Quit Gather there'));
      // Still receiving: half a call is much better than none, and the desktop
      // is carrying the microphone.
      expect(rig.session.remotes, isEmpty);
    });
  });

  group('the audio route', () {
    test('walking into a conversation sends the sound to the loudspeaker',
        () async {
      // The whole bug: you could hear a conversation only with the phone at your
      // ear. Listening connects the media plane, and that is where the route is
      // set — before any capture, with nobody having tapped a thing.
      await call.setListeningTo({them});
      await settle();

      expect(engine.calls, contains('prepareAudioSession'));
      expect(call.state.audioOutput, AudioOutput.speaker);
      expect(call.state.media.capturing, isFalse);
    });

    test('turning the microphone on prepares the session too', () async {
      await call.setMicOn(true);

      expect(engine.calls, contains('prepareAudioSession'));
    });

    test('the button flips to the earpiece and back, through the queue',
        () async {
      await call.setListeningTo({them});
      await settle();

      expect(await call.setSpeakerOn(false), isNull);
      await settle();
      expect(call.state.audioOutput, AudioOutput.earpiece);

      expect(await call.setSpeakerOn(true), isNull);
      await settle();
      expect(call.state.audioOutput, AudioOutput.speaker);
    });

    test('a headset takes the audio, and a tap can still force the speaker',
        () async {
      await call.setListeningTo({them});
      await settle();

      // AirPods arrive mid-call: they win, without a tap.
      engine.connectHeadset(AudioOutput.bluetooth);
      await settle();
      expect(call.state.audioOutput, AudioOutput.bluetooth);

      // But the person can still override to the loudspeaker.
      await call.setSpeakerOn(true);
      await settle();
      expect(call.state.audioOutput, AudioOutput.speaker);
    });
  });

  group('rebuilding a torn-down session (issue #41 safety net)', () {
    test('throws the stale session away and restores everything on a fresh one',
        () async {
      // The self-heal's safety net, driven through a real [SfuSession] rather than a
      // counter: the desktop's `suspendWebRTCTransports` kills the session
      // server-side, so `rebuild()` must dispose the stale one and stand a fresh one
      // back up with everything the suspend took — the allow list, the conversation,
      // the subscriptions, and both producers. Each `buildSfu` hands out its own rig,
      // so the before and the after are separate wires we can compare.
      final rigs = <Rig>[];
      final localEngine = FakeCaptureEngine();
      final localCall = LiveCall(
        auth: GatherAuth(
          credentials: const GatherCredentials(refreshToken: 'unused'),
        ),
        spaceId: spaceId,
        srcId: me,
        engine: localEngine,
        buildSfu: () {
          final rig = Rig();
          rigs.add(rig);
          return rig.session;
        },
        voice: VoiceActivity(hold: Duration.zero),
      );
      addTearDown(() async {
        await localCall.dispose();
        for (final rig in rigs) {
          await rig.close();
        }
      });

      // A full call: visible to them, in a conversation, listening, mic + camera live.
      await localCall.setVisibleTo({them});
      await localCall.setConversation('bubble-1');
      await localCall.setListeningTo({them});
      await localCall.setMicOn(true);
      await localCall.setCameraOn(true);
      await settle();
      expect(rigs, hasLength(1), reason: 'one session built so far');

      // The suspend tore it down server-side. Rebuild.
      await localCall.rebuild();
      await settle();

      // A second session was built, and the stale one's socket was disposed rather
      // than left dangling — the whole point, since a resync alone would re-subscribe
      // onto the dead one and wait out the deaf-timer.
      expect(rigs, hasLength(2));
      expect(rigs[0].node().disposed, isTrue,
          reason: 'the stale session was thrown away');

      // The fresh node replays everything the suspend took with it.
      final fresh = rigs[1].node();
      expect(fresh.has('consume-allow'), isTrue, reason: 'allow list replayed');
      expect(fresh.argsFor('set-player-conversation-metadata'),
          {'meetingId': '', 'clusterId': 'bubble-1'},
          reason: 'conversation replayed');
      expect(fresh.has('consume-request'), isTrue,
          reason: 'subscriptions replayed');
      final produced = fresh.sent
          .where((f) => f.method == 'produce')
          .map((f) => f.args['tag'])
          .toList();
      expect(produced, containsAll(<String>['audio', 'video']),
          reason: 'mic and camera republished onto the fresh session');
      expect(localCall.state.publishingAudio, isTrue);
      expect(localCall.state.publishingVideo, isTrue);
    });
  });

  group('a stale SFU token after a transport change (#57)', () {
    /// A call whose sessions come from a fresh [Rig] each build, with the first
    /// [refuseCount] of them refusing `produce` the way the server does when the
    /// token went stale across a network gap. Mirrors the #41 harness above.
    ({LiveCall call, List<Rig> rigs, _CountingAuthHttp authHttp}) staleTokenCall(
        {required int refuseCount}) {
      final rigs = <Rig>[];
      final localEngine = FakeCaptureEngine();
      // A fake token endpoint so the heal's `invalidateIdToken` stays offline and
      // its refreshes can be counted — a bad-auth heal must mint a fresh token,
      // not re-present the one the SFU just refused (#84).
      final authHttp = _CountingAuthHttp();
      final localCall = LiveCall(
        auth: GatherAuth(
          credentials: const GatherCredentials(refreshToken: 'unused'),
          http: authHttp,
        ),
        spaceId: spaceId,
        srcId: me,
        engine: localEngine,
        buildSfu: () {
          final rig = Rig();
          rigs.add(rig);
          if (rigs.length <= refuseCount) {
            rig.nodeRefusals['produce'] =
                'produce refused: {message: bad auth, '
                'data: {reason: TokenVerificationFailed}}';
          }
          return rig.session;
        },
        voice: VoiceActivity(hold: Duration.zero),
      );
      addTearDown(() async {
        await localCall.dispose();
        for (final rig in rigs) {
          await rig.close();
        }
      });
      return (call: localCall, rigs: rigs, authHttp: authHttp);
    }

    test('rebuilds to mint a fresh token and republishes the track', () async {
      // The first session carries the stale token and refuses every produce; the
      // rebuilt one does not. Turning the mic on must survive that without a tap
      // being needed to retry.
      final (:call, :rigs, :authHttp) = staleTokenCall(refuseCount: 1);

      final detail = await call.setMicOn(true);
      await settle();

      // The heal dropped the cached token and minted a fresh one before rebuilding
      // — without this the rebuild re-presents the token the SFU just refused and
      // loops forever (#84).
      expect(authHttp.refreshes, greaterThanOrEqualTo(1),
          reason: 'the bad-auth heal forced a token refresh');

      // The stale session was thrown away and a second stood up in its place —
      // exactly the restart the person used to have to do by hand.
      expect(rigs, hasLength(2), reason: 'one rebuild, no more');
      expect(rigs[0].node().disposed, isTrue,
          reason: 'the session with the dead token was disposed');
      final produced = rigs[1]
          .node()
          .sent
          .where((f) => f.method == 'produce')
          .map((f) => f.args['tag'])
          .toList();
      expect(produced, contains('audio'),
          reason: 'the track was republished onto the fresh session');
      expect(detail, isNull, reason: 'the unmute succeeded, so it says nothing');
      expect(call.state.publishingAudio, isTrue);
    });

    test('a token still bad after the rebuild fails once, it does not loop',
        () async {
      // Every session refuses, so the heal cannot win. It must give up after a
      // single rebuild and surface the ordinary failure, not rebuild forever.
      final (:call, :rigs, authHttp: _) = staleTokenCall(refuseCount: 99);

      final detail = await call.setMicOn(true);
      await settle();

      expect(rigs, hasLength(2),
          reason: 'exactly one rebuild attempt, then it stands down');
      // One produce on the fresh session, not two: the rebuild's own republish is
      // the single retry, so the heal must not issue a second produce the fresh
      // session would also refuse.
      final retried = rigs[1]
          .node()
          .sent
          .where((f) => f.method == 'produce' && f.args['tag'] == 'audio');
      expect(retried, hasLength(1),
          reason: 'the heal retries the produce exactly once, no duplicate');
      expect(detail, isNotNull);
      expect(call.state.detail, contains('has not picked up'));
      expect(call.state.publishingAudio, isFalse);
      // The hardware is live and only the wire failed, so the button stays on.
      expect(call.state.micOn, isTrue);
    });
  });

  group('pulling the session over (issue #67)', () {
    test('a publish stuck for 5s raises the handoff banner, then clears when it '
        'recovers', () {
      fakeAsync((clock) {
        // A fresh call over a fresh rig, so the whole stuck-then-heal arc runs
        // inside the virtual clock.
        final localEngine = FakeCaptureEngine();
        final localRig = Rig();
        final localCall = LiveCall(
          auth: GatherAuth(
            credentials: const GatherCredentials(refreshToken: 'unused'),
          ),
          spaceId: spaceId,
          srcId: me,
          engine: localEngine,
          buildSfu: () => localRig.session,
          voice: VoiceActivity(hold: Duration.zero),
        );

        // Connect first, by walking into a conversation — that opens nodeA — so
        // the refusal can be seeded before the first produce reaches it.
        localCall.setListeningTo({them}).ignore();
        clock.flushMicrotasks();

        // The node refuses every produce: the mic is unmuted but the room never
        // hears it, the ordinary "not picked up yet" stuck state.
        localRig.node(nodeA).failingWith['produce'] = 'produce refused';
        localCall.setMicOn(true).ignore();
        clock.flushMicrotasks();

        expect(localCall.state.micOn, isTrue);
        expect(localCall.state.publishingAudio, isFalse);
        expect(localCall.state.needsHandoff, isFalse,
            reason: 'the 5s grace window has not passed yet');

        clock.elapse(const Duration(seconds: 5));
        clock.flushMicrotasks();
        expect(localCall.state.needsHandoff, isTrue,
            reason: 'a wanted track stuck for 5s raises the banner');

        // The move settles: produce is accepted, the track is republished, and
        // the banner lowers on the success. The fake builds its producer on the
        // event queue, so a zero-length elapse is needed past the microtasks.
        localRig.node(nodeA).failingWith.remove('produce');
        localCall.setMicOn(true).ignore();
        clock.elapse(Duration.zero);
        clock.flushMicrotasks();
        expect(localCall.state.publishingAudio, isTrue);
        expect(localCall.state.needsHandoff, isFalse,
            reason: 'a successful publish takes the banner down');

        localCall.dispose().ignore();
        localRig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('turning an unrelated track off leaves the banner up while the mic is '
        'still stuck (#67)', () {
      fakeAsync((clock) {
        final localEngine = FakeCaptureEngine();
        final localRig = Rig();
        final localCall = LiveCall(
          auth: GatherAuth(
            credentials: const GatherCredentials(refreshToken: 'unused'),
          ),
          spaceId: spaceId,
          srcId: me,
          engine: localEngine,
          buildSfu: () => localRig.session,
          voice: VoiceActivity(hold: Duration.zero),
        );

        localCall.setListeningTo({them}).ignore();
        clock.flushMicrotasks();

        // The mic is stuck: unmuted, but the node refuses every produce.
        localRig.node(nodeA).failingWith['produce'] = 'produce refused';
        localCall.setMicOn(true).ignore();
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 5));
        clock.flushMicrotasks();
        expect(localCall.state.needsHandoff, isTrue,
            reason: 'the stuck mic raised the banner');

        // Turning the camera off is a deliberate stand-down for the *camera*, not
        // a cure for the mic. The old single global clear lowered the banner here;
        // it must now stay up because a wanted track is still off the wire.
        localCall.setCameraOn(false).ignore();
        clock.elapse(Duration.zero);
        clock.flushMicrotasks();
        expect(localCall.state.needsHandoff, isTrue,
            reason: 'the mic is still stuck, so the banner stays up');

        localCall.dispose().ignore();
        localRig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('a reclaim onto a session that still cannot publish reports the failure '
        'and keeps the banner (#67)', () async {
      // Every node this call builds refuses produce, so the reclaim rebuilds a
      // fresh session that is just as unable to put the mic back.
      final rigs = <Rig>[];
      final localEngine = FakeCaptureEngine();
      final localCall = LiveCall(
        auth: GatherAuth(
          credentials: const GatherCredentials(refreshToken: 'unused'),
        ),
        spaceId: spaceId,
        srcId: me,
        engine: localEngine,
        buildSfu: () {
          final r = Rig()..nodeRefusals['produce'] = 'produce refused';
          rigs.add(r);
          return r.session;
        },
        voice: VoiceActivity(hold: Duration.zero),
      );
      addTearDown(() async {
        await localCall.dispose();
        for (final r in rigs) {
          await r.close();
        }
      });

      await localCall.setMicOn(true);
      for (var i = 0; i < 3; i++) {
        rigs[0].node().push('double-connected', const {});
      }
      await settle();
      await settle();
      expect(localCall.state.needsHandoff, isTrue);

      final detail = await localCall.pullSessionOver();
      await settle();

      expect(detail, isNotNull,
          reason: 'the fresh session still cannot publish, so this is not '
              'success');
      expect(localCall.state.needsHandoff, isTrue,
          reason: 'the banner stays up for another try, not a silent dead call');
    });

    test('three double-connected notices raise the banner immediately, no wait',
        () async {
      await call.setMicOn(true);

      for (var i = 0; i < 3; i++) {
        rig.node().push('double-connected', const {});
      }
      await settle();
      await settle();

      expect(rig.session.displaced, isTrue);
      // No 5s wait: the sticky latch sets the flag the moment it fires.
      expect(call.state.needsHandoff, isTrue);
    });

    test('pullSessionOver clears displaced and republishes on a fresh session',
        () async {
      // Two rigs: the first latches displaced, the pull builds the second.
      final rigs = <Rig>[];
      final localEngine = FakeCaptureEngine();
      final localCall = LiveCall(
        auth: GatherAuth(
          credentials: const GatherCredentials(refreshToken: 'unused'),
        ),
        spaceId: spaceId,
        srcId: me,
        engine: localEngine,
        buildSfu: () {
          final r = Rig();
          rigs.add(r);
          return r.session;
        },
        voice: VoiceActivity(hold: Duration.zero),
      );
      addTearDown(() async {
        await localCall.dispose();
        for (final r in rigs) {
          await r.close();
        }
      });

      await localCall.setMicOn(true);
      await localCall.setCameraOn(true);
      for (var i = 0; i < 3; i++) {
        rigs[0].node().push('double-connected', const {});
      }
      await settle();
      await settle();
      expect(rigs[0].session.displaced, isTrue);
      expect(localCall.state.needsHandoff, isTrue);

      final detail = await localCall.pullSessionOver();
      await settle();

      expect(detail, isNull, reason: 'the reclaim succeeded');
      expect(rigs, hasLength(2), reason: 'a fresh session was built');
      expect(localCall.state.needsHandoff, isFalse,
          reason: 'the banner is lowered once the session is reclaimed');
      final produced = rigs[1]
          .node()
          .sent
          .where((f) => f.method == 'produce')
          .map((f) => f.args['tag'])
          .toSet();
      expect(produced, containsAll(<String>['audio', 'video']),
          reason: 'both wanted tracks are republished onto the fresh node');
    });
  });

  test('hanging up releases the hardware and the session', () async {
    await call.setMicOn(true);

    await call.hangUp();

    // The audio session is handed back before the capture, and both are gone.
    expect(engine.calls, containsAllInOrder(<String>[
      'releaseAudioSession',
      'stopCapture',
    ]));
    expect(rig.node().disposed, isTrue);
    expect(call.state.micOn, isFalse);
  });
}

/// A [GatherHttp] token endpoint that never touches the network and counts how
/// many times it was asked to mint — so a test can prove the bad-auth heal
/// forced a refresh rather than re-presenting the refused token (#84).
class _CountingAuthHttp implements GatherHttp {
  int refreshes = 0;

  @override
  Future<({int status, Map<String, Object?> body})> postForm(
    Uri uri,
    Map<String, String> fields,
  ) async {
    refreshes++;
    return (
      status: 200,
      body: {
        'id_token': 'tok-$refreshes',
        'refresh_token': fields['refresh_token'],
        'user_id': 'uid-1',
      },
    );
  }

  @override
  Future<({int status, Object? body})> getJson(Uri uri, String bearer) async =>
      (status: 200, body: null);

  @override
  Future<({int status, List<int> body})> getBytes(Uri uri, String bearer) async =>
      (status: 200, body: const <int>[]);

  @override
  Future<({int status, List<int> body})> postJson(
    Uri uri,
    String bearer,
    Object? body,
  ) async =>
      (status: 200, body: const <int>[]);
}
