/// `ext.gc.fault.*`: put the app into the states its known bugs start from, on
/// cue, so the recovery code can be watched doing its job (plan Phase 5).
///
/// Every one of these is a failure a device produces only when it feels like it
/// — a silent SFU node change (issue #67), a Wi-Fi drop mid-call (#8, #70), a
/// collector that goes deaf — and every one already has a `debug*` seam the unit
/// tests drive. These hand those seams to the drive, so `media.watch` or
/// `state.dump` can read the heal as it happens instead of waiting for the bug:
///
///  * `fault.silentMove {addr}` — an op over `LiveCall.debugSilentMove` →
///    `SfuSession.debugSilentMove`: repoint the own node at `addr` (a `ws://` or
///    `wss://` node URL) and leave the send transport on the old one, the drifted
///    state the send-heal has to notice. Live calls only: a scripted call has no
///    session (`refused('no_sfu_session', {source:'scripted'})`), nor has a live
///    one that has not opened it yet (`{source:'live'}`). An op because the
///    move connects to the new node.
///  * `fault.offline {on}` — `AppState.debugNoteConnectivity`: `on:true` notes
///    `[none]`, the app's own "went offline" path (link offline, reconnects
///    suspended, `setReachable(false)`); `on:false` notes `[wifi]`, which the app
///    treats as a transport coming back and resyncs on. The radio itself is not
///    touched — only the app's belief — and the readout says which set was
///    noted, and that the next real plugin event overrides it.
///  * `fault.collectorStatus {healthy, detail?, needsPairing?}` —
///    `AppState.debugNoteCollectorStatus`: the report the collector's status
///    stream would make. The readout is the link and collector health after it.
///
/// ## The guard: outward, deliberately
///
/// A fault on the live wire is felt by the room, not just this phone: a silent
/// move drops our outgoing audio until the heal fires, going "offline" pulls the
/// presence plane down and coming back reconnects — which re-enters the space
/// and bumps `numTimesEnteredSpace` on the account for good (root `AGENTS.md`) —
/// and an unhealthy collector report suspends online activity. That is the
/// `outward` definition ("anyone else in the space could see it"), so all three
/// are flagged `outward: true` and ride the registry's one proven gate:
/// refused `outward_outside_test_space` on `boot: "live"` outside
/// `DRIVE_TEST_SPACE` unless `confirm: true` — which, by the agent rule, only
/// follows the user saying yes to that fault in that session. A second,
/// fault-only guard was the alternative; it would be a second path to keep in
/// step with the first, and reproducing a bug in the space it happened in, with
/// the user's yes, is a legitimate thing to want. The harness is never gated.
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:gather_client/gather_client.dart';

import '../app_state.dart';
import '../media/live_call.dart';
import 'debug_drive.dart';
import 'drive_ops.dart';
import 'drive_result.dart';

/// `ext.gc.fault.{silentMove, offline, collectorStatus}`.
DriveFeature faultFeature({
  required AppState Function() app,
  required String Function() boot,
  required DriveOps ops,
}) {
  Map<String, Object?> link() {
    final a = app();
    final health = a.snapshot.health;
    return {
      'boot': boot(),
      'link': {'state': a.link.state.name, 'detail': a.link.detail, 'needsPairing': a.link.needsPairing},
      'collector': {'healthy': health.gather, 'detail': health.detail},
    };
  }

  return DriveFeature('fault', [
    DriveAction(
      'silentMove',
      (args) async {
        final addr = args.requireString('addr');
        final uri = Uri.tryParse(addr);
        if (uri == null || !(uri.isScheme('ws') || uri.isScheme('wss')) || uri.host.isEmpty) {
          throw const DriveInvalidParams('"addr" must be a ws:// or wss:// node URL');
        }
        final handle = app().callHandle;
        if (handle == null) return DriveResult.refused('no_call', {'boot': boot()});
        if (handle is! LiveCall) {
          return DriveResult.refused('no_sfu_session', {
            'boot': boot(),
            'source': 'scripted',
            'detail': 'a scripted call has no media session to move',
          });
        }
        if (handle.debugSfuSnapshot() == null) {
          return DriveResult.refused('no_sfu_session', {
            'boot': boot(),
            'source': 'live',
            'detail': 'the call has not opened a media session yet (nothing has needed the SFU)',
          });
        }
        final from = handle.debugSfuSnapshot()?['node'];
        final id = ops.start('silentMove', () async {
          final moved = await handle.debugSilentMove(addr);
          if (!moved) {
            return const DriveResult.refused('no_sfu_session', {
              'source': 'live',
              'detail': 'the media session closed before the move',
            });
          }
          return DriveResult.ok({'from': from, 'to': addr, 'node': handle.debugSfuSnapshot()?['node']});
        }());
        return DriveResult.ok({'id': id, 'kind': 'silentMove', 'boot': boot()});
      },
      outward: true,
    ),
    DriveAction(
      'offline',
      (args) async {
        final on = _requireBool(args, 'on');
        final noted = on ? const [ConnectivityResult.none] : const [ConnectivityResult.wifi];
        // The seam the connectivity tests drive; a fault is exactly its job.
        // ignore: invalid_use_of_visible_for_testing_member
        app().debugNoteConnectivity(noted);
        return DriveResult.ok({
          'offline': on,
          'noted': [for (final r in noted) r.name],
          'note': 'the radio was not touched; the next real connectivity event overrides this',
          ...link(),
        });
      },
      outward: true,
    ),
    DriveAction(
      'collectorStatus',
      (args) async {
        final healthy = _requireBool(args, 'healthy');
        final detail = args['detail'];
        if (detail != null && detail is! String) throw const DriveInvalidParams('"detail" must be a string');
        final needsPairing = args['needsPairing'] ?? false;
        if (needsPairing is! bool) throw const DriveInvalidParams('"needsPairing" must be a boolean');
        // ignore: invalid_use_of_visible_for_testing_member
        app().debugNoteCollectorStatus(
          CollectorStatus(healthy: healthy, detail: detail as String?, needsPairing: needsPairing),
        );
        return DriveResult.ok({
          'noted': {'healthy': healthy, 'detail': detail, 'needsPairing': needsPairing},
          ...link(),
        });
      },
      outward: true,
    ),
  ]);
}

bool _requireBool(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is bool) return value;
  throw DriveInvalidParams(value == null ? '"$key" is required' : '"$key" must be a boolean');
}
