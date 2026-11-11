/// H10: the game gateway restarts under two connected clients — both reconnect by
/// themselves and the roster comes back.
///
/// The restart throws away the gateway's in-memory presence (positions,
/// clusters) while the API and the database keep running. So "restored" means
/// what a fresh connection can rebuild: each side sees the other again, entered
/// and acting — not the old coordinates.
///
/// Gated on `BETHER_E2E_RESTART_CMD` (e.g.
/// `bash <bether-backend>/scripts/e2e.sh restart-gateway`, which handles both the
/// docker and the --native stack). It disconnects *every* socket on the stack, so
/// run this file on its own rather than beside the rest of the suite.
///
/// The test budget sits well above the sum of its waits: it runs the restart
/// command and then waits up to [_reconnectPatience] several times, and a bare
/// "test timed out" would hide which of those waits was the slow one.
@Tags(['e2e'])
@Timeout(Duration(minutes: 5))
@TestOn('vm')
library;

import 'dart:io';

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'suite.dart';

/// Reconnect is the collector's own backoff (1 s, 2 s, 4 s, … while the port is
/// closed), on top of however long the container takes to come back.
const _reconnectPatience = Duration(seconds: 60);

void main() {
  group(
    'bether E2E: gateway restart',
    skip: e2eSkip(
      e2eEnv?.restartGatewayCommand != null
          ? null
          : 'H10 bounces the gateway: set BETHER_E2E_RESTART_CMD='
                "'bash <bether-backend>/scripts/e2e.sh restart-gateway' and run this file alone",
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
        'H10 gateway restart → both collectors reconnect, roster restored',
        () async {
          final alice = await signUp(env, config, 'h10a');
          final bob = await signUp(env, config, 'h10b');
          final spaceId = await alice.rest.createSpace('H10 ${randomTag()}');
          final bobId = await bob.rest.join(spaceId);

          final a = sockets.start(alice, spaceId: spaceId, label: 'alice');
          final b = sockets.start(bob, spaceId: spaceId, label: 'bob');
          final aliceId = (await connected(a)).selfId!;
          await connected(b);
          await sees(a, bobId);
          await sees(b, aliceId);
          expect(a.teleport(x: 6, y: 4).ok, isTrue);
          await sees(b, aliceId, x: 6, y: 4);

          final before = (
            a: a.stats()['connects']! as int,
            b: b.stats()['connects']! as int,
          );
          final dropped = (
            a: a.statuses.firstWhere((s) => !s.healthy),
            b: b.statuses.firstWhere((s) => !s.healthy),
          );

          final restart = await Process.run('/bin/sh', [
            '-c',
            env.restartGatewayCommand!,
          ]);
          expect(
            restart.exitCode,
            0,
            reason:
                'restart command failed:\n${restart.stdout}\n${restart.stderr}',
          );

          // Both noticed the drop (a close, not a silent half-open socket)…
          await dropped.a.timeout(_reconnectPatience);
          await dropped.b.timeout(_reconnectPatience);

          // …and both came back on a new connection, without anyone calling resync.
          await until(
            () =>
                (a.stats()['connects']! as int) > before.a &&
                    (b.stats()['connects']! as int) > before.b
                ? true
                : null,
            reason: 'both collectors to reconnect',
            timeout: _reconnectPatience,
            interval: const Duration(milliseconds: 200),
          );
          expect(
            (await connected(a, timeout: _reconnectPatience)).selfId,
            aliceId,
            reason: 'same person, same SpaceUser after the restart',
          );
          expect(
            (await connected(b, timeout: _reconnectPatience)).selfId,
            bobId,
          );
          await sees(a, bobId, timeout: _reconnectPatience);
          await sees(b, aliceId, timeout: _reconnectPatience);

          // Live, not just listed: a move after the restart reaches the other side.
          expect(a.teleport(x: 9, y: 4).ok, isTrue);
          await sees(b, aliceId, x: 9, y: 4);
          expect(a.healthy && b.healthy, isTrue);
        },
      );
    },
  );
}
