/// H7–H8: what reaches a phone that is not looking — a wave over the game socket
/// (gateway → webhook → sink) and a meeting invite over REST (API → sink), read
/// back from `/__e2e/pushes` by the recipient's own device token.
///
/// Every test registers a fresh token and never clears the sink: the clear is
/// global and the files run in parallel.
@Tags(['e2e'])
@TestOn('vm')
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'suite.dart';

void main() {
  group('bether E2E: push', skip: e2eSkip(), () {
    late E2eEnv env;
    late BackendConfig config;
    final sockets = Sockets();

    setUpAll(() async {
      env = e2eEnv!;
      config = await discover(env.base);
    });

    tearDown(sockets.closeAll);

    test(
      'H7 A waves at B → WaveEvent on B\'s socket and a "wave" push to B\'s device',
      () async {
        final alice = await signUp(env, config, 'h7a');
        final bob = await signUp(env, config, 'h7b');
        final spaceId = await alice.rest.createSpace('H7 ${randomTag()}');
        final bobId = await bob.rest.join(spaceId);
        final bobDevice = 'e2e-fcm-h7-${randomTag(8)}';
        await bob.rest.registerPush(bobDevice);

        final a = sockets.start(alice, spaceId: spaceId, label: 'alice');
        final b = sockets.start(bob, spaceId: spaceId, label: 'bob');
        final aliceId = (await connected(a)).selfId!;
        await connected(b);
        await sees(a, bobId);

        // Listen before sending: the bus is broadcast and unbuffered.
        final onBob = b.interactions
            .firstWhere((e) => e.name == 'WaveEvent' && e.isFor(bobId))
            .timeout(const Duration(seconds: 10));
        expect(a.wave(bobId).ok, isTrue);

        final event = await onBob;
        expect(
          event.senderId,
          aliceId,
          reason: 'who waved is payload.senderId',
        );
        expect(event.sentTime, isNotNull);

        final push = await awaitPush(env, bobDevice, 'wave');
        expect(push['token'], bobDevice);
        expect(
          push['title'],
          isA<String>().having((t) => t, 'title', isNotEmpty),
        );
        expect((push['data'] as Map)['type'], 'notification.shown');
      },
    );

    test(
      'H7 A follows B → followTargetId on B\'s roster and a "follow" push',
      skip:
          'contract gap on both sides: DirectCollector has no follow action '
          '(lib/src/direct_collector.dart — the client only reads followTargetId, '
          'lib/src/game_protocol.dart:1113), and the gateway maps no action to '
          'PresenceEngine.follow (bether-backend src/gateway/gateway.ts:287 default: '
          'ack + no-op) although the engine (src/presence/engine.ts:300) and the push '
          "policy (src/push/describe.ts, follow: true) are ready. Gather's wire shape is "
          'SpaceUser `follow` {followTargetId} / `unfollow` '
          '(docs/protocol/client-action-surface.md:406,433)',
      // No body can be written until DirectCollector has a follow action; fail
      // loudly so an unskip (or --run-skipped) cannot pass with zero coverage.
      () => fail(
        'not implemented: write the follow → followTargetId + "follow" push '
        'scenario once DirectCollector can follow',
      ),
    );

    test(
      'H8 meeting create + invite → "meeting invite" push for the invitee',
      () async {
        final alice = await signUp(env, config, 'h8a');
        final bob = await signUp(env, config, 'h8b');
        final spaceId = await alice.rest.createSpace('H8 ${randomTag()}');
        final bobId = await bob.rest.join(spaceId);
        final bobDevice = 'e2e-fcm-h8-${randomTag(8)}';
        await bob.rest.registerPush(bobDevice);

        final meetingId = await alice.rest.createMeeting(spaceId);
        final participant = await alice.rest.invite(meetingId, bobId);
        expect(participant['spaceUserId'], bobId);

        final push = await awaitPush(env, bobDevice, 'meeting invite');
        expect((push['data'] as Map)['type'], 'notification.shown');
        expect(
          push['title'],
          isA<String>().having((t) => t, 'title', isNotEmpty),
        );

        // Only members may hold meetings, and only members may be invited.
        final stranger = await signUp(env, config, 'h8c');
        final refused = await stranger.rest.post(
          '/spaces/$spaceId/meetings',
          <String, Object?>{},
        );
        expect(refused.status, 403);
        final outsider = await alice.rest.post('/meetings/$meetingId/invite', {
          'spaceUserId': '00000000-0000-0000-0000-000000000000',
        });
        expect(outsider.status, 400);
      },
    );
  });
}
