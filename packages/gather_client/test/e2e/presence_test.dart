/// H5–H6: the game socket, through the production [DirectCollector] — handshake,
/// roster, movement, collision and proximity clusters as another client sees them.
@Tags(['e2e'])
@TestOn('vm')
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'suite.dart';

void main() {
  group('bether E2E: game socket', skip: e2eSkip(), () {
    late E2eEnv env;
    late BackendConfig config;
    final sockets = Sockets();

    setUpAll(() async {
      env = e2eEnv!;
      config = await discover(env.base);
    });

    tearDown(sockets.closeAll);

    test('H5 DirectCollector handshake → roster contains self', () async {
      final user = await signUp(env, config, 'h5');
      final name = 'H5 ${randomTag()}';
      final spaceId = await user.rest.createSpace(name);
      final mine = (await user.auth.recentSpaces()).single;

      // No configured space: the collector resolves it from recent-spaces, as the
      // app does on first launch, and so enters inside the handshake.
      final collector = sockets.start(user, label: 'h5');
      final roster = await connected(collector);

      expect(collector.spaceId, spaceId);
      expect(collector.stats()['authUserId'], user.userId);
      expect(collector.stats()['entered'], isTrue);
      expect(
        roster.selfId,
        mine.spaceUserId,
        reason: 'the Connection row and recent-spaces must agree on who we are',
      );
      expect(
        mine.name,
        name,
        reason: 'REST knows the real name — see the next test',
      );

      final self = rowOf(roster, roster.selfId)!;
      expect(self.connected, isTrue);
      expect(self.floorId, isNotNull);
      expect(collector.reader.selfVisible, isTrue);
      expect(collector.healthy, isTrue);
    });

    test(
      'H5 the state dump names the space as REST does',
      skip:
          'contract bug: the gateway builds its SpaceManager without a resolver '
          '(bether-backend src/gateway/main.ts:31), so every engine falls back to '
          "{name: 'Space'} (src/presence/manager.ts:31) and the dump's Space row "
          '(src/presence/engine.ts:192) says "Space" for every space — which the client '
          'reads straight into Roster.spaceName (lib/src/game_protocol.dart:898)',
      () async {
        final user = await signUp(env, config, 'h5name');
        final name = 'H5 name ${randomTag()}';
        await user.rest.createSpace(name);
        final roster = await connected(sockets.start(user, label: 'h5name'));
        expect(roster.spaceName, name);
      },
    );

    test(
      'H5 the state dump carries our UserAccount → selfAccountId',
      skip:
          'contract gap: PresenceEngine.stateDump (bether-backend '
          'src/presence/engine.ts:177) emits no UserAccount rows — the encoder could '
          '(src/protocol/encoder.ts:121) — and the client learns selfAccountId only from '
          'a UserAccount whose firebaseAuthId is ours (lib/src/game_protocol.dart:886), '
          'so selfAccountId stays null; the SFU keys on it (M5)',
      () async {
        final user = await signUp(env, config, 'h5acct');
        await user.rest.createSpace('H5 account ${randomTag()}');
        final collector = sockets.start(user, label: 'h5acct');
        await connected(collector);
        expect(collector.selfAccountId, user.userId);
      },
    );

    test(
      'H5 the state dump carries the floor plan → mapFor() builds a map',
      skip:
          'contract gap: bether sends no map models in the state dump '
          '(bether-backend src/presence/engine.ts stateDump: only Connection, Space, '
          'SpaceUser), so SpaceMapBuilder.forFloor (lib/src/space_map.dart) has nothing '
          'to build and DirectCollector.mapFor stays null — no walls, no rooms, and the '
          "client's canStep cannot mirror the server's collision grid",
      () async {
        final user = await signUp(env, config, 'h5map');
        await user.rest.createSpace('H5 map ${randomTag()}');
        final collector = sockets.start(user, label: 'h5map');
        final roster = await connected(collector);
        final floor = rowOf(roster, roster.selfId)!.floorId;
        await until(
          () => collector.mapFor(floor),
          reason: 'a floor plan for $floor',
        );
      },
    );

    test(
      'H6 two collectors: A moves → B sees it; adjacency → shared cluster',
      () async {
        final alice = await signUp(env, config, 'h6a');
        final bob = await signUp(env, config, 'h6b');
        final spaceId = await alice.rest.createSpace('H6 ${randomTag()}');
        final bobId = await bob.rest.join(spaceId);

        // A configured space id: the other entry path, entering once the dump has
        // named us rather than inside the handshake.
        final a = sockets.start(alice, spaceId: spaceId, label: 'alice');
        final b = sockets.start(bob, spaceId: spaceId, label: 'bob');
        final aliceId = (await connected(a)).selfId!;
        expect((await connected(b)).selfId, bobId);
        await sees(a, bobId);
        await sees(b, aliceId);

        // Apart: four tiles between them, outside the cluster radius.
        expect(a.teleport(x: 4, y: 6, direction: 'Right').ok, isTrue);
        expect(b.teleport(x: 8, y: 6, direction: 'Left').ok, isTrue);
        await sees(b, aliceId, x: 4, y: 6);
        await sees(a, bobId, x: 8, y: 6);
        await rosterWhere(
          b,
          (r) => r.myClusterId == null && rowOf(r, aliceId)?.clusterId == null,
          reason: 'nobody in a conversation while apart',
        );

        // One step at a time, each confirmed by the *other* client.
        expect(a.move(direction: 'Right').ok, isTrue);
        await sees(b, aliceId, x: 5, y: 6);
        expect(
          b.reader.roster().myClusterId,
          isNull,
          reason: 'three tiles is still apart',
        );

        expect(a.move(direction: 'Right').ok, isTrue);
        await sees(b, aliceId, x: 6, y: 6);

        // Two tiles: inside the radius. Both sides name the same conversation.
        final together = await rosterWhere(
          b,
          (r) =>
              r.myClusterId != null &&
              rowOf(r, aliceId)?.clusterId == r.myClusterId,
          reason: 'bob and alice in one cluster',
        );
        final cluster = together.myClusterId;
        final fromAlice = await rosterWhere(
          a,
          (r) => r.myClusterId == cluster,
          reason: 'alice to see the same cluster id',
        );
        expect(fromAlice.myCluster.map((r) => r.id), [bobId]);
        expect(together.myCluster.map((r) => r.id), [aliceId]);

        // Stepping away dissolves it.
        expect(a.move(direction: 'Left').ok, isTrue);
        await rosterWhere(
          b,
          (r) => r.myClusterId == null && rowOf(r, aliceId)?.x == 5,
          reason: 'the cluster to dissolve when alice steps away',
        );

        // Collision: the border wall is the server's. A step into it is not applied —
        // proven by ordering rather than by waiting: the next legal step lands one
        // tile down from the wall-side tile, not from inside the wall.
        expect(a.teleport(x: 1, y: 6, direction: 'Left').ok, isTrue);
        await sees(b, aliceId, x: 1, y: 6);
        expect(a.move(direction: 'Left').ok, isTrue);
        expect(a.move(direction: 'Down').ok, isTrue);
        await sees(b, aliceId, x: 1, y: 7);
      },
    );

    // What every iOS resume does: the app drops its socket and opens a new one.
    test(
      'H6 A reconnects → B still sees A, and A still sees itself',
      skip:
          'contract bug, both sides. Backend: the old socket\'s close removes the '
          'user and queues deletemodel SpaceUser (bether-backend '
          'src/presence/engine.ts:230); the coalesced flush lands ~50 ms later on '
          'every sink — including the new connection, *after* its full state dump '
          '(src/gateway/gateway.ts:315) — so a stale delta outlives the snapshot. '
          'Client: deletemodel marks the row gone (lib/src/game_protocol.dart:916; '
          'bridge/lib/game-protocol.js:299 the same) and a later addmodel merges into '
          'that row (game_protocol.dart:863 via _row :985) without clearing gone, so a '
          'person removed and re-added on one connection stays invisible — to peers '
          'until *they* reconnect, and to themselves until the presence ladder forces '
          'a reconnect',
      () async {
        final alice = await signUp(env, config, 'h6ra');
        final bob = await signUp(env, config, 'h6rb');
        final spaceId = await alice.rest.createSpace('H6r ${randomTag()}');
        await bob.rest.join(spaceId);

        final a = sockets.start(alice, spaceId: spaceId, label: 'alice');
        final b = sockets.start(bob, spaceId: spaceId, label: 'bob');
        final aliceId = (await connected(a)).selfId!;
        await connected(b);
        await sees(b, aliceId);

        final connectsBefore = a.stats()['connects']! as int;
        await a.resync();
        await until(
          () => (a.stats()['connects']! as int) > connectsBefore ? true : null,
          reason: 'alice to reconnect',
        );
        await connected(a);

        expect(a.teleport(x: 7, y: 7).ok, isTrue);
        await sees(b, aliceId, x: 7, y: 7);
        await rosterWhere(
          a,
          (r) => a.reader.selfVisible && rowOf(r, aliceId)?.x == 7,
          reason: 'alice to see herself placed after the reconnect',
        );
      },
    );
  });
}
