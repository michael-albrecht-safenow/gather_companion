/// `package:test` glue for the E2E files: the skip gate and per-test socket
/// bookkeeping. Kept apart from `harness.dart`, which the bot imports and which
/// therefore must not depend on the test framework.
///
/// ## Running
///
/// ```sh
/// # in bether-backend
/// scripts/e2e.sh up && scripts/e2e.sh seed
/// # here
/// set -a; . ../../../bether-backend/e2e/.env.generated; set +a
/// dart test -t e2e                                   # H1–H8 (+ the bot peer)
/// # H9 needs a stack that expires tokens quickly:
/// #   E2E_JWT_ACCESS_TTL=5 scripts/e2e.sh up
/// # H10 bounces the gateway, which disconnects every socket on the stack, so it
/// # runs on its own:
/// BETHER_E2E_RESTART_CMD='bash <bether-backend>/scripts/e2e.sh restart-gateway' \
///   dart test -t e2e test/e2e/gateway_restart_test.dart
/// ```
library;

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'harness.dart';

/// The stack, or null — in which case every E2E group is skipped, not failed.
final E2eEnv? e2eEnv = E2eEnv.load();

/// `skip:` for an E2E group: the stack reason first, then any [extra] gate.
Object e2eSkip([String? extra]) {
  if (e2eEnv == null) return e2eSkipReason;
  return extra ?? false;
}

/// Every collector a test starts, so tearDown can close them all.
///
/// Each collector logs into one buffer, prefixed by its label; the buffer is
/// printed only when the test fails, so a green run stays quiet and a red one
/// shows both sides of the socket conversation in order.
class Sockets {
  final _collectors = <DirectCollector>[];
  final _log = <String>[];

  void Function(String) logger(String label) =>
      (line) => _log.add(
        '${DateTime.now().toIso8601String().substring(11, 23)} [$label] $line',
      );

  /// Builds a collector the way the app does and starts it.
  DirectCollector start(
    E2eUser user, {
    String? spaceId,
    required String label,
  }) {
    final collector = user.collector(spaceId: spaceId, log: logger(label));
    track(collector);
    collector.start();
    return collector;
  }

  /// Registers a collector built elsewhere for disposal.
  T track<T extends DirectCollector>(T collector) {
    _collectors.add(collector);
    return collector;
  }

  Future<void> closeAll() async {
    for (final collector in _collectors) {
      await collector.dispose();
    }
    _collectors.clear();
    if (_log.isNotEmpty) printOnFailure(_log.join('\n'));
    _log.clear();
  }
}
