/// `ext.gc.sfu.debug`: what the media session *believes* — its node, the
/// peer-node cache, its transports and their states, every producer and
/// consumer, the consumes in flight and the heal machinery's state (plan task
/// 2.6).
///
/// The pair to `media.snapshot`. Packet counters say what is happening; this
/// says what the session thinks is happening, and every deaf-call bug this app
/// has had lived in the gap between the two: a consumer on a producer id the
/// peer had since replaced (#61), a peer cached on a node that had died (#83), a
/// send transport still bound to the node we moved off (#67), a peer stranded
/// on a refusing node (#90). `media.snapshot` shows `missing` or `stalled`;
/// `sfu.debug` shows *why*. Read it alongside, not instead.
///
/// One handler, one read: `LiveCall.debugSfuSnapshot` → `SfuSession.
/// debugSnapshot`, synchronous, nothing sent on any socket, no token anywhere in
/// it. Read-only (`outward: false`).
///
/// Three answers, kept apart (the honesty rule): no call at all is
/// `refused('no_call')`; a call with nothing on the wire to describe is
/// `refused('no_sfu_session')` — a scripted call (the harness, `source:
/// "scripted"`) never has one, a live call has none until the first thing that
/// needs the SFU opens it — and anything else is the snapshot, `source: "live"`.
library;

import '../media/call.dart';
import '../media/live_call.dart';
import 'debug_drive.dart';
import 'drive_result.dart';

/// `ext.gc.sfu.debug`.
DriveFeature sfuFeature({required Call? Function() call}) => DriveFeature('sfu', [
      DriveAction('debug', (args) async {
        final handle = call();
        if (handle == null) return const DriveResult.refused('no_call');
        if (handle is! LiveCall) {
          return const DriveResult.refused('no_sfu_session', {
            'source': 'scripted',
            'detail': 'a scripted call has no media session to describe',
          });
        }
        final snapshot = handle.debugSfuSnapshot();
        if (snapshot == null) {
          return const DriveResult.refused('no_sfu_session', {
            'source': 'live',
            'detail': 'the call has not opened a media session yet (nothing has needed the SFU)',
          });
        }
        return DriveResult.ok({'source': 'live', ...snapshot});
      }),
    ]);
