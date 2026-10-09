/// [SfuSession] — the conversation with Gather's media plane.
///
/// `packages/gather_client` tests the *transport* against a real socket; this
/// tests what is said over it and in what order, which is where the
/// reverse-engineered risk actually lives. Both halves it depends on are faked:
/// the signalling ([FakeSignalling]) and mediasoup ([FakeDevice]), the latter
/// because `Device.load()` wants a platform channel this runner does not have.
///
/// The cases worth having are the ones a device cannot be made to perform on
/// cue: a router that has not placed somebody yet, a socket that drops and comes
/// back holding nothing, and a node being drained underneath a live call.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/sfu_session.dart';

import 'fake_mediasoup.dart';
import 'fake_signalling.dart';
import 'sfu_rig.dart';

void main() {
  late Rig rig;

  setUp(() => rig = Rig());
  tearDown(() => rig.close());

  /// Let every pending microtask and zero-length timer run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('assignment', () {
    test('asks the router for our UserAccount id and connects what it names',
        () async {
      await rig.session.start();

      expect(rig.router.argsFor('get-addr'),
          {'srcId': me, 'srcStreamId': spaceId});
      expect(rig.session.sfuAddr, nodeA);
      expect(rig.sockets.containsKey(nodeA), isTrue,
          reason: 'the node the router named should be connected');
      expect(rig.device.loaded, isTrue);
      expect(rig.session.ready, isTrue);
    });

    test('a router that has not placed us yet is asked again, not given up on',
        () async {
      // `addrFound: false` is a normal answer — measured, and documented as
      // such. Treating it as fatal is what made the first tap after opening the
      // app fail permanently.
      rig.addresses.remove(me);
      var asked = 0;
      rig.session.start().ignore();
      await settle();
      asked = rig.router.asked.length;
      expect(asked, greaterThan(0));

      rig.addresses[me] = nodeA;
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(rig.session.sfuAddr, nodeA);
      expect(rig.router.asked.length, greaterThan(asked),
          reason: 'it should have asked a second time');
    });

    test('a router that never places us fails rather than hanging', () async {
      rig.addresses.remove(me);
      await expectLater(rig.session.start(), throwsA(isA<SfuException>()));
    });
  });

  group('the allow list', () {
    test('is replayed to a node the moment it connects', () async {
      // It lives on the node, so a list built before the socket existed means
      // nothing to it — the same replay `playerConnectedSFU` does.
      rig.session.setAllowed({them, 'acct-other'});
      await rig.session.start();

      final allows = rig.node().said.where((f) => f.method == 'consume-allow');
      expect(allows.map((f) => f.args['dstId']), containsAll([them, 'acct-other']));
      expect(allows.every((f) => f.args['allowed'] == true), isTrue);
    });

    test('is diffed rather than re-sent, and never aimed at ourselves',
        () async {
      await rig.session.start();
      rig.node().drain();

      rig.session.setAllowed({them, me});
      rig.session.setAllowed({them, 'acct-third'});

      final allows = rig.node().said.where((f) => f.method == 'consume-allow');
      expect(
        allows.map((f) => (f.args['dstId'], f.args['allowed'])),
        [(them, true), ('acct-third', true)],
        reason: 'ourselves is not a peer, and an unchanged grant is not news',
      );
      expect(rig.session.allowed, {them, 'acct-third'});
    });

    test('grants before asking, because consuming is reciprocal', () async {
      await rig.session.start();
      rig.node().drain();

      await rig.session.subscribe(them);

      final order = rig.node().sent.map((f) => f.method).toList();
      expect(order.indexOf('consume-allow'), lessThan(order.indexOf('consume-request')));
      expect(rig.node().argsFor('consume-request'),
          {'srcId': them, 'srcStreamId': spaceId, 'requested': true});
    });
  });

  group('receiving', () {
    test('a peer the router cannot place is kept, and asked for again', () {
      // The bug this pins: dropping them from the subscribed set meant
      // `setSubscriptions` — which diffs against that set — never retried, so a
      // colleague whose client was still connecting stayed silent forever.
      fakeAsync((clock) {
        rig.addresses.remove(them);
        rig.session.start().ignore();
        clock.flushMicrotasks();

        rig.session.subscribe(them).ignore();
        clock.flushMicrotasks();
        expect(rig.node().has('consume-request'), isFalse);

        rig.addresses[them] = nodeA;
        clock.elapse(const Duration(seconds: 11));
        clock.flushMicrotasks();

        expect(rig.node().has('consume-request'), isTrue);
        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('consume-try builds a consumer, and an empty map takes it away',
        () async {
      await rig.session.start();
      await rig.session.subscribe(them);

      rig.announce(them, {'audio': 'p-audio'});
      await settle();

      expect(rig.session.remotes, hasLength(1));
      expect(rig.session.remotes.single.srcId, them);
      expect(rig.session.remotes.single.streams.keys, [SfuTag.audio]);
      // The SFU wants telling that the consumer was actually built, which is
      // unusual enough to be worth pinning.
      expect(rig.node().has('consume-created'), isTrue);
      expect(rig.node().has('consume-resume'), isTrue);

      // Full state, not a delta: an empty map means they publish nothing.
      rig.announce(them, {});
      await settle();
      expect(rig.session.remotes, isEmpty);
    });

    test('a producer id that changed under us is a new stream', () async {
      await rig.session.start();
      await rig.session.subscribe(them);

      rig.announce(them, {'video': 'p-1'});
      await settle();
      final first = rig.device.transports
          .expand((t) => t.consumers)
          .singleWhere((c) => c.producerId == 'p-1');

      // They turned the camera off and on again. The old consumer points at a
      // producer that no longer exists.
      rig.announce(them, {'video': 'p-2'});
      await settle();

      expect(first.closed, isTrue);
      expect(rig.session.remotes.single.streams.keys, [SfuTag.video]);
    });

    test('unsubscribing tells the node, the router, and takes the grant back',
        () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.node().drain();
      rig.router.drain();

      await rig.session.unsubscribe(them);

      expect(rig.node().argsFor('consume-request'),
          {'srcId': them, 'srcStreamId': spaceId, 'requested': false});
      expect(rig.router.argsFor('unsubscribe'),
          {'srcId': them, 'srcStreamId': spaceId});
      expect(rig.node().sent.any((f) =>
          f.method == 'consume-allow' && f.args['allowed'] == false), isTrue);
    });
  });

  group('recovery', () {
    test('a socket that comes back is a fresh session, and is rebuilt as one',
        () async {
      await rig.session.start();
      rig.session.setAllowed({them});
      await rig.session.subscribe(them);
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);
      rig.node().drain();

      rig.node().drop();
      rig.node().comeBack();
      await settle();
      await settle();

      final sent = rig.node().sent;
      expect(sent.any((f) => f.method == 'consume-allow' && f.args['allowed'] == true),
          isTrue, reason: 'the allow list lives on the node and died with it');
      expect(sent.any((f) => f.method == 'consume-request'), isTrue,
          reason: 'the server has forgotten we wanted them');
      expect(rig.republishes, 1,
          reason: 'the producers went with the socket, and only the caller '
              'holds the tracks to put them back');
    });

    test('a drained node is left for the one the router names next', () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      final old = rig.node();

      // `cordon-sfu` is *router* vocabulary. Nothing was listening to the router
      // before, so this notice could never arrive — which made every other part
      // of draining dead code.
      rig.addresses[me] = nodeB;
      rig.addresses[them] = nodeB;
      rig.router.push('cordon-sfu', {'sfuAddr': nodeA});
      await settle();
      await settle();

      expect(rig.session.sfuAddr, nodeB);
      expect(old.disposed, isTrue);
      expect(rig.node(nodeB).has('get-rtp-capabilities'), isTrue);
      expect(rig.node(nodeB).has('consume-request'), isTrue,
          reason: 'whoever was on the old node has to be asked for again');
      expect(rig.republishes, 1);
    });
  });

  group('publishing', () {
    test('produce carries the tag Gather keys on, and keeps the producer',
        () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);

      expect(rig.node().argsFor('produce')?['tag'], 'audio');
      expect(rig.session.publishing(SfuTag.audio), isTrue);

      // Mute is a pause, not a close: the producer stays so unmuting is not a
      // fresh negotiation, and `produce-pause` carries only a tag.
      rig.session.pause(SfuTag.audio);
      expect(rig.node().argsFor('produce-pause'), {'tag': 'audio'});
      expect(rig.device.transports.first.producers.single.closed, isFalse);
    });

    test('nothing is produced until the transport has a peer connection',
        () async {
      await rig.session.start();

      // The window the real library leaves open: `Transport`'s constructor calls
      // `handler.run()` without awaiting it, so for a few milliseconds the
      // transport exists with `_pc == null`. A `produce()` inside that window
      // reaches `_pc!` and throws a null check that `FlexQueue` swallows whole —
      // no log, nothing sent, and twenty seconds of silence before `publish`
      // gives up. Holding the handler reproduces it exactly.
      rig.device.holdNewHandlers = true;

      var settled = false;
      final publishing = rig.session
          .publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio)
          .then((_) => settled = true);

      await pumpEventQueue();
      final transport = rig.device.transports
          .firstWhere((t) => t.producerCallback != null);
      expect(
        transport.encodingsByTag.containsKey('audio'),
        isFalse,
        reason: 'produced before the peer connection existed',
      );
      expect(settled, isFalse);

      transport.handler.release();
      await publishing;
      expect(rig.session.publishing(SfuTag.audio), isTrue);
    });

    test('a microphone is published with no encodings, and a camera with '
        'three that each name a scalability mode', () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);
      await rig.session.publish(FakeTrack('video'), FakeStream(), tag: SfuTag.video);

      final encodings = rig.device.transports.first.encodingsByTag;

      // Audio must be empty. `flutter_webrtc` gives every encoding a
      // `scaleResolutionDownBy` and a `numTemporalLayers` before it reaches
      // libwebrtc, which rejects both on an audio transceiver — so one encoding
      // here is an `addTransceiver` that throws where nobody can see it, and a
      // microphone that never publishes. Measured 2026-09-17.
      expect(encodings['audio'], isEmpty);

      // Video keeps its simulcast layers, and every one of them has to name a
      // scalability mode: the handler reads `encodings.first.scalabilityMode!`.
      expect(encodings['video'], hasLength(3));
      for (final encoding in encodings['video']!) {
        expect(encoding.scalabilityMode, isNotNull);
      }
    });

    test('three double-connected notices stand us down for good', () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);
      final producer = rig.device.transports.first.producers.single;

      for (var i = 0; i < 3; i++) {
        rig.node().push('double-connected', const {});
      }
      await settle();

      expect(rig.session.displaced, isTrue);
      expect(producer.closed, isTrue);
      // Sticky, and enforced rather than merely documented: retrying restarts
      // the fight that standing down exists to end.
      await expectLater(
        rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio),
        throwsA(isA<SfuException>()),
      );
    });

    test('the server steering our quality is debounced, and applied once',
        () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('video'), FakeStream(), tag: SfuTag.video);
      final producer = rig.device.transports.first.producers.single;

      for (final layer in [0, 1, 2]) {
        rig.node().push('set-max-spatial-layer', {'kind': 'video', 'layer': layer});
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(producer.maxSpatialLayers, [2]);
    });

    test('a transport-create in an unknown shape says exactly that', () async {
      await rig.session.start();
      rig.node().answer('transport-create', (_) => const {});

      // The one thing in the session no capture has ever confirmed. If it is
      // ever wrong, the error has to name it rather than surface as a cast
      // failure inside a callback.
      await expectLater(
        rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio),
        throwsA(isA<SfuException>().having(
          (e) => e.message, 'message', contains('transport-create'))),
      );
    });

    test('TURN rotation puts the servers in before restarting ICE', () async {
      await rig.session.start();
      await rig.session.publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio);

      await rig.session.refreshTurn();

      final transport = rig.device.transports.first;
      expect(transport.lastIceServers, isNotEmpty);
      expect(transport.iceRestarts, 1);
    });
  });

  group('quality and metadata', () {
    test('watching a face asks for the layer, and ranks who matters', () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.node().drain();

      rig.session.setWatching([them], layer: VideoQuality.full.spatialLayer);

      expect(rig.node().argsFor('consume-set-spatial'), {
        'srcId': them,
        'srcStreamId': spaceId,
        'tag': 'video',
        'spatialLayer': 2,
      });
      expect(rig.node().argsFor('consume-set-priority'), {
        'srcStreamId': spaceId,
        'tag': 'video',
        'srcIds': [them],
      });
    });

    test('closing the screen puts everybody back to the smallest layer',
        () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.session.setWatching([them], layer: 2);
      rig.node().drain();

      rig.session.setWatching(const [], layer: 0);

      expect(rig.node().argsFor('consume-set-spatial')?['spatialLayer'], 0);
    });

    test('the conversation is named, with "" and never null', () async {
      // Measured 2026-09-17: a null in either field gets no ack at all — zod
      // rejects it and the server says nothing — while "" is what the desktop
      // sends for a missing value and is acked with `[]`.
      await rig.session.start();
      rig.node().drain();

      rig.session.setConversation(clusterId: 'bubble-1');
      await settle();
      expect(rig.node().argsFor('set-player-conversation-metadata'),
          {'meetingId': '', 'clusterId': 'bubble-1'});

      rig.node().drain();
      rig.session.setConversation(clusterId: null);
      await settle();
      expect(rig.node().argsFor('set-player-conversation-metadata'),
          {'meetingId': '', 'clusterId': ''});
    });

    test('a colleague who joined muted is resumed on the server when they unmute',
        () async {
      // A consumer is built paused on the server, and `consume` answering
      // `producerPaused: true` means nobody sent `consume-resume` for it. When
      // the producer comes back the server-side switch still has to be flipped,
      // or the colleague unmutes and stays silent here. The desktop sends
      // `consume-resume` at exactly this point (captured 2026-09-17).
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.node().answer(
          'consume',
          (args) => {
                'id': 'consumer-${args['srcId']}-${args['tag']}',
                'producerId': rig.producerIds['${args['srcId']}|${args['tag']}'],
                'producerPaused': true,
                'rtpParameters': Rig.rtpParameters,
              });

      rig.announce(them, {'audio': 'p-audio'});
      await settle();
      expect(rig.node().has('consume-created'), isTrue);
      expect(rig.node().has('consume-resume'), isFalse,
          reason: 'a paused producer is not resumed on arrival');
      expect(rig.session.remotes.single.paused, contains(SfuTag.audio));

      rig.node().drain();
      rig.node().push('producer-resumed', {'srcId': them, 'tag': 'audio'});
      await settle();
      expect(rig.node().argsFor('consume-resume'), {
        'srcId': them,
        'srcStreamId': spaceId,
        'tag': 'audio',
        'consumerId': 'consumer-$them-audio',
      });
      expect(rig.session.remotes.single.paused, isNot(contains(SfuTag.audio)));
    });
  });

  group('receive-side deafness', () {
    // The deaf join from issue #20: the SFU answers a consume-request with
    // `consume-not-allowed` instead of `consume-try`, so `_consume` never runs
    // and the lazy recv transport is never built. The watchdog has to notice and
    // rebuild the receive path.

    int consumeRequestsFor(FakeSignalling node, String srcId) => node.sent
        .where((f) => f.method == 'consume-request' && f.args['srcId'] == srcId)
        .length;

    test('heals a deaf join by re-requesting, then builds a consumer', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();

        rig.session.subscribe(them).ignore();
        clock.flushMicrotasks();

        // Deaf: the request came back denied rather than announced.
        rig.node().push(
            'consume-not-allowed', {'srcId': them, 'srcStreamId': spaceId});
        clock.flushMicrotasks();
        expect(rig.session.remotes, isEmpty);

        rig.node().drain();

        // The grace window passes and the watchdog rebuilds, re-requesting them.
        clock.elapse(const Duration(seconds: 6));
        clock.flushMicrotasks();
        expect(consumeRequestsFor(rig.node(), them), greaterThan(0),
            reason: 'the rebuild should have re-asked for the denied peer');

        // This time the server announces, and a consumer is built.
        rig.announce(them, {'audio': 'p-audio'});
        clock.flushMicrotasks();
        expect(rig.session.remotes, isNotEmpty);
        expect(rig.session.remotes.single.srcId, them);

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('retries with growing backoff and never gives up', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();
        rig.session.subscribe(them).ignore();
        clock.flushMicrotasks();

        // Every request stays denied: each re-request the rebuild issues is met
        // with another `consume-not-allowed`, so the watchdog keeps climbing.
        rig.node().push(
            'consume-not-allowed', {'srcId': them, 'srcStreamId': spaceId});
        clock.flushMicrotasks();

        // Re-arm the denial after each rebuild so the heal-needed check holds
        // and the backoff keeps doubling: 5s, 10s, 20s, 30s (capped).
        void denyAfter(Duration window) {
          final before = consumeRequestsFor(rig.node(), them);
          clock.elapse(window);
          clock.flushMicrotasks();
          expect(consumeRequestsFor(rig.node(), them), greaterThan(before),
              reason: 'a re-request was expected after ${window.inSeconds}s');
          rig.node().push(
              'consume-not-allowed', {'srcId': them, 'srcStreamId': spaceId});
          clock.flushMicrotasks();
        }

        denyAfter(const Duration(seconds: 6)); // 5s window
        denyAfter(const Duration(seconds: 11)); // 10s window
        denyAfter(const Duration(seconds: 21)); // 20s window
        denyAfter(const Duration(seconds: 31)); // 30s cap
        denyAfter(const Duration(seconds: 31)); // still capped, still trying

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('stops once a consumer is built', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();
        rig.session.subscribe(them).ignore();
        clock.flushMicrotasks();

        rig.node().push(
            'consume-not-allowed', {'srcId': them, 'srcStreamId': spaceId});
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 6));
        clock.flushMicrotasks();

        // The heal re-requested; this time the peer is announced and consumed.
        rig.announce(them, {'audio': 'p-audio'});
        clock.flushMicrotasks();
        expect(rig.session.remotes, isNotEmpty);

        rig.node().drain();

        // Well past the capped backoff, with no fresh denial: nothing re-fires.
        clock.elapse(const Duration(seconds: 90));
        clock.flushMicrotasks();
        expect(rig.node().has('consume-request'), isFalse,
            reason: 'a built consumer cancels the watchdog for good');

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('a silent room with no denial never triggers a rebuild', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();
        rig.session.subscribe(them).ignore();
        clock.flushMicrotasks();

        // Joined muted with no camera: an empty producer map, and no denial.
        rig.announce(them, {});
        clock.flushMicrotasks();
        expect(rig.session.remotes, isEmpty);

        rig.node().drain();

        clock.elapse(const Duration(seconds: 90));
        clock.flushMicrotasks();
        expect(rig.node().has('consume-request'), isFalse,
            reason: 'no denial means nothing to heal');
        expect(rig.node().has('transport-create'), isFalse);

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('a stale denial from a departed peer never rebuilds a live one', () {
      fakeAsync((clock) {
        const other = 'acct-other';
        rig.addresses[other] = nodeA;

        rig.session.start().ignore();
        clock.flushMicrotasks();

        // A peer is denied, arming the watchdog.
        rig.session.subscribe(them).ignore();
        clock.flushMicrotasks();
        rig.node().push(
            'consume-not-allowed', {'srcId': them, 'srcStreamId': spaceId});
        clock.flushMicrotasks();

        // Membership turns over before the timer fires: the denied peer leaves
        // and a replacement joins, whose receive path is healthily in flight
        // (requested, not yet a consumer). unsubscribe() leaves the denial
        // behind, so without pruning it reads as proof the cluster is deaf.
        rig.session.unsubscribe(them).ignore();
        clock.flushMicrotasks();
        rig.session.subscribe(other).ignore();
        clock.flushMicrotasks();
        final asked = consumeRequestsFor(rig.node(), other);
        expect(asked, greaterThan(0),
            reason: 'the replacement should have been requested once');

        // The watchdog fires carrying only the departed peer's denial. It must
        // stand down, not tear down and re-request the replacement's live path.
        clock.elapse(const Duration(seconds: 90));
        clock.flushMicrotasks();
        expect(consumeRequestsFor(rig.node(), other), asked,
            reason: "a departed peer's denial must not rebuild a live peer");

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('a heal leaves the send side untouched', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();
        rig.session
            .publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio)
            .ignore();
        // The fake builds the producer on the event queue, not a microtask, so
        // a zero-length elapse is needed to let it land.
        clock.elapse(Duration.zero);
        clock.flushMicrotasks();
        rig.session.subscribe(them).ignore();
        clock.flushMicrotasks();

        final sendTransport = rig.device.transports
            .firstWhere((t) => t.producerCallback != null);
        expect(sendTransport.producers, isNotEmpty);

        // The send transport connects normally, so the send-side watchdog stands
        // down and only the receive heal under test is in play.
        sendTransport.handlers['connectionstatechange']
            ?.call({'connectionState': 'connected'});
        clock.flushMicrotasks();

        rig.node().push(
            'consume-not-allowed', {'srcId': them, 'srcStreamId': spaceId});
        clock.flushMicrotasks();
        rig.node().drain();

        clock.elapse(const Duration(seconds: 6));
        clock.flushMicrotasks();

        // The rebuild touches only the receive path: no new send transport, and
        // the producer that carries our microphone is still open.
        final sendCreates = rig.node().sent.where((f) =>
            f.method == 'transport-create' && f.args['direction'] == 'send');
        expect(sendCreates, isEmpty);
        expect(sendTransport.producers.every((p) => !p.closed), isTrue);
        expect(rig.session.publishing(SfuTag.audio), isTrue);

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });
  });

  group('send-side stall', () {
    // The camera-enable freeze from the 2026-10-09 media.log: `produce` is acked
    // the instant the signalling lands, so a producer is built onto a send
    // transport whose ICE never completes. Nothing times out — the produce
    // already succeeded — so the room gets no media and, before this watchdog,
    // the app sat dead until a socket drop eventually tore it down. The send
    // heal has to notice "a producer, but a transport that never connected" and
    // rebuild.

    FakeTransport sendTransport() =>
        rig.device.transports.firstWhere((t) => t.producerCallback != null);

    void publishAudio(FakeAsync clock) {
      rig.session
          .publish(FakeTrack('audio'), FakeStream(), tag: SfuTag.audio)
          .ignore();
      // The fake builds the producer on the event queue, not a microtask.
      clock.elapse(Duration.zero);
      clock.flushMicrotasks();
    }

    test('rebuilds a produce the transport never connected, and asks to '
        'republish', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();

        publishAudio(clock);
        final send = sendTransport();
        expect(send.producers, isNotEmpty);
        expect(rig.session.publishing(SfuTag.audio), isTrue);
        final before = rig.republishes;

        // No `connectionstatechange` ever fires: the transport acked the produce
        // but its ICE stalled. The grace window passes and the watchdog rebuilds.
        clock.elapse(const Duration(seconds: 6));
        clock.flushMicrotasks();

        expect(send.closed, isTrue,
            reason: 'the poisoned send transport is torn down');
        expect(send.producers.every((p) => p.closed), isTrue);
        expect(rig.session.publishing(SfuTag.audio), isFalse,
            reason: 'the dropped producer is forgotten');
        expect(rig.republishes, greaterThan(before),
            reason: 'the owner is asked to put its tracks back');

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('a transport that connects cancels the watchdog', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();

        publishAudio(clock);
        final send = sendTransport();
        final before = rig.republishes;

        // ICE completes before the grace window is out.
        send.handlers['connectionstatechange']
            ?.call({'connectionState': 'connected'});
        clock.flushMicrotasks();

        clock.elapse(const Duration(seconds: 90));
        clock.flushMicrotasks();

        expect(send.closed, isFalse);
        expect(rig.session.publishing(SfuTag.audio), isTrue);
        expect(rig.republishes, before,
            reason: 'a connected transport means nothing to heal');

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('a healthy transport that stalls back to connecting re-arms the '
        'watchdog', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();

        publishAudio(clock);
        final send = sendTransport();
        final before = rig.republishes;

        // ICE completes, so the watchdog stands down and its timer is cancelled.
        send.handlers['connectionstatechange']
            ?.call({'connectionState': 'connected'});
        clock.flushMicrotasks();

        // Later a TURN refresh restarts ICE and the transport drops back to
        // `connecting`, then silently stalls there — never reporting
        // `disconnected` or `failed`. With nothing re-arming on `connecting`
        // this producer would ride a dead transport forever.
        send.handlers['connectionstatechange']
            ?.call({'connectionState': 'connecting'});
        clock.flushMicrotasks();

        clock.elapse(const Duration(seconds: 6));
        clock.flushMicrotasks();

        expect(send.closed, isTrue,
            reason: 'the re-stalled send transport is torn down');
        expect(rig.session.publishing(SfuTag.audio), isFalse);
        expect(rig.republishes, greaterThan(before),
            reason: 'the watchdog re-armed on connecting and rebuilt');

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('retries with growing backoff and never gives up', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();

        publishAudio(clock);
        var rebuilds = rig.republishes;

        // Each window the transport still never connects: the watchdog rebuilds,
        // asks for a republish, and we put the producer back the way LiveCall's
        // `_onNeedsRepublish` would. Backoff climbs 6 → 12 → 24 → 30 (capped).
        for (final window in const [6, 12, 24, 30, 30]) {
          clock.elapse(Duration(seconds: window));
          clock.flushMicrotasks();
          expect(rig.republishes, greaterThan(rebuilds),
              reason: 'a rebuild was expected after ${window}s');
          rebuilds = rig.republishes;
          publishAudio(clock);
        }

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });

    test('a never-connected producer tears down without throwing', () {
      fakeAsync((clock) {
        rig.session.start().ignore();
        clock.flushMicrotasks();

        publishAudio(clock);
        final send = sendTransport();
        final before = rig.republishes;

        // mediasoup's `@close` runs `createOffer` on the half-built peer
        // connection and throws. The guarded close must swallow it and still
        // leave clean state — an escaping throw would fail this test.
        for (final producer in send.producers) {
          producer.throwOnClose = true;
        }

        clock.elapse(const Duration(seconds: 6));
        clock.flushMicrotasks();

        expect(rig.session.publishing(SfuTag.audio), isFalse,
            reason: 'the producer is forgotten even though its close threw');
        expect(rig.republishes, greaterThan(before));

        rig.close().ignore();
        clock.elapse(const Duration(seconds: 1));
      });
    });
  });
}
