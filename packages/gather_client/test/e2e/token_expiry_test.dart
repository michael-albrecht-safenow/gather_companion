/// H9: an access token outlives its TTL — both planes refuse it, and the client
/// gets back in by refreshing rather than re-presenting it.
///
/// Needs a stack that actually expires tokens within a test's patience:
/// `E2E_JWT_ACCESS_TTL=5 scripts/e2e.sh up` (the runner exports the TTL as
/// `BETHER_E2E_JWT_ACCESS_TTL`). On the default 3600 s stack it skips.
///
/// What the gateway does on expiry is part of what this pins: it checks the JWT
/// at `Authenticate` only, so a socket opened with a since-expired token keeps
/// working; the refusal bites at the *next* connect. A client that reconnected
/// with the cached token would be met with Gather-style silence — which is why
/// the reconnect must go through [GatherAuth.idToken].
@Tags(['e2e'])
@TestOn('vm')
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'suite.dart';

/// The longest TTL the scenario will wait out.
const _maxTtl = 30;

void main() {
  final ttl = e2eEnv?.jwtAccessTtl;
  group(
    'bether E2E: token expiry',
    skip: e2eSkip(
      ttl != null && ttl <= _maxTtl
          ? null
          : 'H9 needs a short-TTL stack: E2E_JWT_ACCESS_TTL=5 scripts/e2e.sh up '
                '(this stack: ${ttl ?? 'unknown'}s, limit ${_maxTtl}s)',
    ),
    () {
      late E2eEnv env;
      late BackendConfig config;
      final sockets = Sockets();

      setUpAll(() async {
        env = e2eEnv!;
        config = await discover(env.base);
      });

      tearDown(sockets.closeAll);

      test(
        'H9 stale access token → gateway refuses it → client refreshes + reconnects',
        () async {
          final alice = await signUp(env, config, 'h9a');
          final bob = await signUp(env, config, 'h9b');
          final spaceId = await alice.rest.createSpace('H9 ${randomTag()}');
          await bob.rest.join(spaceId);

          final a = sockets.start(alice, spaceId: spaceId, label: 'alice');
          final b = sockets.start(bob, spaceId: spaceId, label: 'bob');
          final aliceId = (await connected(a)).selfId!;
          await connected(b);
          await sees(b, aliceId);

          // The token alice's socket authenticated with, and when it dies.
          final stale = alice.auth.credentials.idToken!;
          final expiry = expiryOf(stale)!;
          // A clock deadline, not a readiness guess: the condition is the wall clock
          // passing the token's own `exp` (plus a second of skew).
          await until(
            () =>
                DateTime.now().toUtc().isAfter(
                  expiry.add(const Duration(seconds: 1)),
                )
                ? true
                : null,
            reason: 'the access token to expire',
            timeout: Duration(seconds: ttl! + 10),
            interval: const Duration(milliseconds: 200),
          );

          // REST refuses it outright…
          final rest = await const IoGatherHttp().getJson(
            Uri.parse('${config.apiBase}/users/me'),
            stale,
          );
          expect(rest.status, 401);

          // …and the gateway with silence: a collector made to present exactly this
          // token (its clock frozen inside the token's life, so GatherAuth hands it
          // over as is) gets heartbeats and never a state dump.
          final frozen = GatherAuth(
            credentials: GatherCredentials(
              refreshToken: 'unused',
              idToken: stale,
            ),
            config: config,
            now: () => expiry.subtract(const Duration(hours: 1)),
          );
          final refused = sockets.track(
            DirectCollector(
              auth: frozen,
              spaceId: spaceId,
              socketUrl: config.gameSocket,
              log: sockets.logger('stale'),
            ),
          )..start();
          await until(
            () => (refused.detail ?? '').contains('holding no state')
                ? true
                : null,
            reason: 'the stale-token socket to be reported as not accepted',
          );
          expect(refused.hasState, isFalse);
          expect(refused.healthy, isFalse);
          expect(
            // roster() keeps deleted rows (connected: false), so a mere
            // non-null row would not catch a refused socket tearing alice down.
            rowOf(b.reader.roster(), aliceId)?.connected,
            isTrue,
            reason:
                'the refused socket must not disturb alice\'s live presence',
          );

          // The socket opened before expiry is not cut off: actions still land.
          expect(a.teleport(x: 5, y: 5).ok, isTrue);
          await sees(b, aliceId, x: 5, y: 5);

          // A reconnect must refresh — the held token is past its expiry — and get in.
          final rotationsBefore = alice.rotations;
          final connectsBefore = a.stats()['connects']! as int;
          await a.resync();
          await until(
            () =>
                (a.stats()['connects']! as int) > connectsBefore ? true : null,
            reason: 'alice to reconnect',
          );
          await connected(a);
          expect(
            alice.rotations,
            greaterThan(rotationsBefore),
            reason: 'the reconnect refreshed',
          );
          final fresh = alice.auth.credentials.idToken!;
          expect(fresh, isNot(stale));
          expect(expiryOf(fresh)!.isAfter(DateTime.now().toUtc()), isTrue);

          // And the new connection is a live, entered one: it acts, and someone sees
          // it. A *fresh* observer, deliberately — bob's reader keeps alice's row
          // gone after her reconnect (the remove/re-add bug pinned in
          // presence_test.dart, "H6 A reconnects"), which is not what H9 is about.
          expect(a.teleport(x: 7, y: 7).ok, isTrue);
          final carol = await signUp(env, config, 'h9c');
          await carol.rest.join(spaceId);
          final c = sockets.start(carol, spaceId: spaceId, label: 'carol');
          await connected(c);
          await sees(c, aliceId, x: 7, y: 7);
        },
      );
    },
  );
}
