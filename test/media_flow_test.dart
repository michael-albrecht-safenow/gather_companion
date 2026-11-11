/// The flow probe's two halves: crediting stats rows to the right track, and
/// judging a stream from two readings.
///
/// Attribution is the half that fails quietly. A producer's `getStats()` can
/// return the whole peer connection, and on 2026-09-17 a silent microphone read
/// as healthy because the bytes being read were the camera's. So every fixture
/// here is a *mixed* peer connection — mic and camera, two peers' audio, the
/// transport's combined totals — and the assertions are that only the named
/// track's numbers come back.
///
/// The verdict half is the plan's table, one row per test, including the two
/// rules that matter most: DTX silence is not a failure, and a stats call that
/// timed out is never a stall.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/media/live_call.dart';
import 'package:gather_companion/src/media/media_flow.dart';

import 'fake_capture_engine.dart';
import 'sfu_rig.dart';

/// One send peer connection carrying a microphone and a three-layer camera.
final List<Map<String, Object?>> _sendPc = [
  {'id': 'T1', 'type': 'transport', 'bytesSent': 999999, 'bytesReceived': 5555, 'iceState': 'connected', 'dtlsState': 'connected', 'selectedCandidatePairId': 'CP1'},
  {'id': 'CP1', 'type': 'candidate-pair', 'state': 'succeeded', 'currentRoundTripTime': 0.031, 'bytesSent': 999999},
  {'id': 'CP2', 'type': 'candidate-pair', 'state': 'failed', 'selected': false},
  {'id': 'MS-A', 'type': 'media-source', 'kind': 'audio', 'trackIdentifier': 'mic-1', 'audioLevel': 0.0, 'totalAudioEnergy': 0.0},
  {'id': 'MS-V', 'type': 'media-source', 'kind': 'video', 'trackIdentifier': 'cam-1', 'framesPerSecond': 30},
  {'id': 'OA', 'type': 'outbound-rtp', 'kind': 'audio', 'mid': '0', 'ssrc': 1111, 'mediaSourceId': 'MS-A', 'packetsSent': 300, 'bytesSent': 9000},
  {'id': 'OV0', 'type': 'outbound-rtp', 'kind': 'video', 'mid': '1', 'ssrc': 2221, 'rid': 'r0', 'mediaSourceId': 'MS-V', 'packetsSent': 1000, 'bytesSent': 400000, 'framesEncoded': 300, 'frameWidth': 320, 'frameHeight': 180, 'qualityLimitationReason': 'none'},
  {'id': 'OV1', 'type': 'outbound-rtp', 'kind': 'video', 'mid': '1', 'ssrc': 2222, 'rid': 'r1', 'mediaSourceId': 'MS-V', 'packetsSent': 2000, 'bytesSent': 800000, 'framesEncoded': 300, 'frameWidth': 1280, 'frameHeight': 720, 'qualityLimitationReason': 'bandwidth'},
  {'id': 'OV2', 'type': 'outbound-rtp', 'kind': 'video', 'mid': '1', 'ssrc': 2223, 'rid': 'r2', 'mediaSourceId': 'MS-V', 'packetsSent': 1500, 'bytesSent': 600000, 'framesEncoded': 300, 'frameWidth': 640, 'frameHeight': 360, 'qualityLimitationReason': 'cpu'},
];

/// One receive peer connection carrying Bob's audio and video and Carol's audio.
final List<Map<String, Object?>> _recvPc = [
  {'id': 'T2', 'type': 'transport', 'bytesReceived': 2000000, 'iceState': 'connected', 'dtlsState': 'connected'},
  {'id': 'CP3', 'type': 'candidate-pair', 'state': 'succeeded', 'nominated': true, 'currentRoundTripTime': 0.05, 'bytesReceived': 2000000},
  {'id': 'IA1', 'type': 'inbound-rtp', 'kind': 'audio', 'trackIdentifier': 'bob-a', 'mid': '0', 'ssrc': 5001, 'packetsReceived': 500, 'bytesReceived': 40000, 'packetsLost': 3, 'jitter': 0.002, 'totalAudioEnergy': 1.5, 'concealedSamples': 10, 'totalSamplesReceived': 48000},
  {'id': 'IV1', 'type': 'inbound-rtp', 'kind': 'video', 'trackIdentifier': 'bob-v', 'mid': '1', 'ssrc': 5002, 'packetsReceived': 900, 'bytesReceived': 900000, 'framesReceived': 250, 'framesDecoded': 240, 'framesDropped': 2, 'frameWidth': 640, 'frameHeight': 360, 'framesPerSecond': 24.0, 'freezeCount': 1, 'totalFreezesDuration': 0.4},
  {'id': 'IA2', 'type': 'inbound-rtp', 'kind': 'audio', 'trackIdentifier': 'carol-a', 'mid': '2', 'ssrc': 5003, 'packetsReceived': 50, 'bytesReceived': 4000, 'totalAudioEnergy': 0.0},
];

final _t0 = DateTime.utc(2026, 11, 11, 9);
DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

InboundFlow _in(String src, String tag, {bool paused = false, int? packets, int? bytes, double? energy, int? frames, bool rowFound = true, bool measured = true, String consumer = 'c1', int lost = 0}) =>
    InboundFlow(
      srcId: src,
      tag: tag,
      paused: paused,
      consumerId: consumer,
      rowFound: rowFound,
      counters: !measured
          ? null
          : InboundCounters(packetsReceived: packets, bytesReceived: bytes, totalAudioEnergy: energy, framesDecoded: frames, packetsLost: rowFound ? lost : null),
    );

MediaFlowSample _sample(int ms, {List<InboundFlow> inbound = const [], List<OutboundFlow> outbound = const [], List<ExpectedStream> expected = const []}) =>
    MediaFlowSample(at: _at(ms), source: 'scripted', inbound: inbound, outbound: outbound, expected: expected);

void main() {
  group('outbound attribution, on a peer connection carrying mic and camera', () {
    const mic = TrackKeys(kind: 'audio', trackId: 'mic-1', mid: '0', ssrcs: {1111});
    const camera = TrackKeys(kind: 'video', trackId: 'cam-1', mid: '1', ssrcs: {2221, 2222, 2223});

    test('the mic gets its own row only — never the camera bytes, never the transport totals', () {
      final parsed = parseOutboundStats(_sendPc, mic);
      expect(parsed.rowFound, isTrue);
      expect(parsed.counters.bytesSent, 9000, reason: 'the camera sends 1.8 MB and the transport 1 MB; neither is the mic');
      expect(parsed.counters.packetsSent, 300);
      expect(parsed.counters.audioLevel, 0.0, reason: 'from the audio media-source, not the video one');
      expect(parsed.counters.totalAudioEnergy, 0.0);
      expect(parsed.counters.framesEncoded, isNull);
    });

    test('the camera sums its simulcast layers and reports the widest one', () {
      final parsed = parseOutboundStats(_sendPc, camera);
      expect(parsed.counters.bytesSent, 1800000);
      expect(parsed.counters.packetsSent, 4500);
      expect(parsed.counters.framesEncoded, 900);
      expect(parsed.counters.frameWidth, 1280);
      expect(parsed.counters.frameHeight, 720);
      expect(parsed.counters.qualityLimitationReason, 'bandwidth');
      expect(parsed.counters.audioLevel, isNull);
    });

    test('any one identifier is enough: track id (via media-source), mid, or ssrc', () {
      for (final keys in const [
        TrackKeys(kind: 'audio', trackId: 'mic-1'),
        TrackKeys(kind: 'audio', mid: '0'),
        TrackKeys(kind: 'audio', ssrcs: {1111}),
      ]) {
        expect(parseOutboundStats(_sendPc, keys).counters.bytesSent, 9000);
      }
    });

    test('an identifier that contradicts is not attributed, even with another that agrees', () {
      final parsed = parseOutboundStats(_sendPc, const TrackKeys(kind: 'audio', mid: '0', ssrcs: {9999}));
      expect(parsed.rowFound, isFalse);
      expect(parsed.counters.bytesSent, isNull);
    });

    test('kind alone attributes nothing', () {
      final parsed = parseOutboundStats(_sendPc, const TrackKeys(kind: 'audio'));
      expect(parsed.rowFound, isFalse);
      expect(parsed.counters.bytesSent, isNull);
    });
  });

  group('inbound attribution, on a receive transport carrying two peers', () {
    test("Bob's audio is Bob's audio: not his video, not Carol's, not the transport", () {
      final parsed = parseInboundStats(_recvPc, const TrackKeys(kind: 'audio', trackId: 'bob-a', mid: '0', ssrcs: {5001}));
      expect(parsed.rowFound, isTrue);
      final c = parsed.counters;
      expect(c.bytesReceived, 40000);
      expect(c.packetsReceived, 500);
      expect(c.packetsLost, 3);
      expect(c.jitter, 0.002);
      expect(c.totalAudioEnergy, 1.5);
      expect(c.concealedSamples, 10);
      expect(c.totalSamplesReceived, 48000);
      expect(c.framesDecoded, isNull);
    });

    test("Bob's video carries the frame counters", () {
      final c = parseInboundStats(_recvPc, const TrackKeys(kind: 'video', trackId: 'bob-v')).counters;
      expect(c.bytesReceived, 900000);
      expect(c.framesReceived, 250);
      expect(c.framesDecoded, 240);
      expect(c.framesDropped, 2);
      expect(c.frameWidth, 640);
      expect(c.frameHeight, 360);
      expect(c.framesPerSecond, 24.0);
      expect(c.freezeCount, 1);
      expect(c.totalFreezesDuration, 0.4);
    });

    test('two audio rows and a key with only a kind: nothing, rather than a coin flip', () {
      final parsed = parseInboundStats(_recvPc, const TrackKeys(kind: 'audio'));
      expect(parsed.rowFound, isFalse);
      expect(parsed.counters.bytesReceived, isNull);
    });

    test('a track with no row yet (no packet has arrived) is rowFound: false', () {
      expect(parseInboundStats(_recvPc, const TrackKeys(kind: 'audio', trackId: 'dave-a')).rowFound, isFalse);
    });

    test('older WebRTC: the RTP row points at a legacy track row, which supplies id and counters', () {
      final legacy = [
        {'id': 'TR1', 'type': 'track', 'kind': 'audio', 'trackIdentifier': 'bob-a', 'totalAudioEnergy': 2.0, 'concealedSamples': 5},
        {'id': 'TR2', 'type': 'track', 'kind': 'audio', 'trackIdentifier': 'carol-a', 'totalAudioEnergy': 9.0},
        {'id': 'R1', 'type': 'inbound-rtp', 'mediaType': 'audio', 'trackId': 'TR1', 'packetsReceived': 70.0, 'bytesReceived': '5600'},
        {'id': 'R2', 'type': 'inbound-rtp', 'mediaType': 'audio', 'trackId': 'TR2', 'packetsReceived': 99},
      ];
      final parsed = parseInboundStats(legacy, const TrackKeys(kind: 'audio', trackId: 'bob-a'));
      expect(parsed.rowFound, isTrue);
      expect(parsed.counters.packetsReceived, 70, reason: 'doubles off the platform channel become ints');
      expect(parsed.counters.bytesReceived, 5600, reason: 'and numeric strings too');
      expect(parsed.counters.totalAudioEnergy, 2.0);
      expect(parsed.counters.concealedSamples, 5);
    });
  });

  group('transport rows', () {
    test('the selected pair by id, with the transport row\'s own totals', () {
      final t = parseTransportStats(_sendPc, direction: 'send');
      expect(t.direction, 'send');
      expect(t.iceState, 'connected');
      expect(t.dtlsState, 'connected');
      expect(t.selectedPairState, 'succeeded');
      expect(t.currentRoundTripTime, 0.031);
      expect(t.bytesSent, 999999);
    });

    test('with no selectedCandidatePairId, a nominated succeeded pair', () {
      final t = parseTransportStats(_recvPc, direction: 'recv');
      expect(t.selectedPairState, 'succeeded');
      expect(t.currentRoundTripTime, 0.05);
      expect(t.bytesReceived, 2000000);
    });

    test('a platform that sends a state as a non-string costs nothing: it is stringified, not a TypeError', () {
      final t = parseTransportStats(const [
        {'id': 'T', 'type': 'transport', 'iceState': 2, 'dtlsState': 1},
      ], direction: 'send');
      expect(t.iceState, '2');
      expect(t.dtlsState, '1');
      final out = parseOutboundStats(const [
        {'id': 'O', 'type': 'outbound-rtp', 'kind': 'video', 'mid': '1', 'packetsSent': 5, 'qualityLimitationReason': 0},
      ], const TrackKeys(kind: 'video', mid: '1'));
      expect(out.counters.qualityLimitationReason, '0');
    });

    test('no rows at all is a transport with nothing known, not zeros', () {
      final t = parseTransportStats(const [], direction: 'recv');
      expect(t.iceState, isNull);
      expect(t.bytesReceived, isNull);
    });
  });

  group('verdicts', () {
    const bob = ExpectedStream('bob', 'audio');
    const bobVideo = ExpectedStream('bob', 'video');

    test('a first reading has no verdict to give: not_measured / no_baseline', () {
      final v = FlowJudge().judge(_sample(0, inbound: [_in('bob', 'audio', packets: 10, energy: 0.1)], expected: [bob])).single;
      expect(v.verdict, FlowVerdict.notMeasured);
      expect(v.detail, 'no_baseline');
    });

    test('flowing: packets and energy rise', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 10, bytes: 800, energy: 0.1)]));
      final v = judge.judge(_sample(1000, inbound: [_in('bob', 'audio', packets: 60, bytes: 4800, energy: 0.2)])).single;
      expect(v.verdict, FlowVerdict.flowing);
      expect(v.packets, 50);
      expect(v.bytes, 4000);
      expect(v.intervalMs, 1000);
      expect(v.key, 'in:bob|audio');
      expect(v.toJson()['verdict'], 'flowing');
    });

    test('silent: Opus DTX comfort noise — a trickle of packets, no energy — and it never becomes a stall', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 100, energy: 0.5)]));
      for (var s = 1; s <= 10; s++) {
        final v = judge.judge(_sample(s * 1000, inbound: [_in('bob', 'audio', packets: 100 + s * 2, energy: 0.5)])).single;
        expect(v.verdict, FlowVerdict.silent, reason: 'at ${s}s');
      }
    });

    test('stalled only once counters are flat for the whole window; a flat second in between keeps the last verdict', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 10, energy: 0.1)]));
      expect(judge.judge(_sample(1000, inbound: [_in('bob', 'audio', packets: 60, energy: 0.2)])).single.verdict, FlowVerdict.flowing);

      final grace = judge.judge(_sample(2000, inbound: [_in('bob', 'audio', packets: 60, energy: 0.2)])).single;
      expect(grace.verdict, FlowVerdict.flowing);
      expect(grace.detail, 'grace');
      expect(grace.flatForMs, 1000);

      final stalled = judge.judge(_sample(3000, inbound: [_in('bob', 'audio', packets: 60, energy: 0.2)])).single;
      expect(stalled.verdict, FlowVerdict.stalled);
      expect(stalled.flatForMs, 2000);

      expect(judge.judge(_sample(4000, inbound: [_in('bob', 'audio', packets: 110, energy: 0.3)])).single.verdict, FlowVerdict.flowing,
          reason: 'and recovers the moment packets move');
    });

    test('flat from the start: settling, then stalled — never invented as flowing', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 0, energy: 0)]));
      final first = judge.judge(_sample(1000, inbound: [_in('bob', 'audio', packets: 0, energy: 0)])).single;
      expect(first.verdict, FlowVerdict.notMeasured);
      expect(first.detail, 'settling');
      expect(judge.judge(_sample(2000, inbound: [_in('bob', 'audio', packets: 0, energy: 0)])).single.verdict, FlowVerdict.stalled);
    });

    test('the stall window is configurable', () {
      final judge = FlowJudge(stallAfter: const Duration(milliseconds: 500));
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 5, energy: 0)]));
      expect(judge.judge(_sample(500, inbound: [_in('bob', 'audio', packets: 5, energy: 0)])).single.verdict, FlowVerdict.stalled);
    });

    test('paused: their wire mute, flat counters expected, never a stall however long', () {
      final judge = FlowJudge();
      for (var s = 0; s <= 10; s++) {
        final v = judge.judge(_sample(s * 1000, inbound: [_in('bob', 'audio', paused: true, packets: 40, energy: 0.1)])).single;
        expect(v.verdict, FlowVerdict.paused, reason: 'at ${s}s');
      }
    });

    test('missing: expected (subscribed, producer announced) but no consumer', () {
      final verdicts = FlowJudge().judge(_sample(0, inbound: [_in('bob', 'audio', packets: 1)], expected: [bob, bobVideo]));
      final missing = verdicts.singleWhere((v) => v.tag == 'video');
      expect(missing.verdict, FlowVerdict.missing);
      expect(missing.detail, 'consumer_missing');
      expect(missing.srcId, 'bob');
    });

    test('a consumer nobody expects any more is still judged while it exists', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('eve', 'audio', packets: 1, energy: 0)]));
      expect(judge.judge(_sample(1000, inbound: [_in('eve', 'audio', packets: 51, energy: 0.1)])).single.verdict, FlowVerdict.flowing);
    });

    test('not_measured (stats timed out) is never folded into stalled, and keeps the last real baseline', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 10, energy: 0.1)]));
      for (var s = 1; s <= 10; s++) {
        final v = judge.judge(_sample(s * 1000, inbound: [_in('bob', 'audio', measured: false)])).single;
        expect(v.verdict, FlowVerdict.notMeasured);
        expect(v.detail, 'stats_failed');
      }
      final back = judge.judge(_sample(11000, inbound: [_in('bob', 'audio', packets: 560, energy: 1.2)])).single;
      expect(back.verdict, FlowVerdict.flowing);
      expect(back.intervalMs, 11000, reason: 'judged against the last real reading');
    });

    test('video is judged on frames decoded: bytes arriving with no decode is a frozen picture', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'video', bytes: 1000, packets: 10, frames: 24)]));
      expect(judge.judge(_sample(1000, inbound: [_in('bob', 'video', bytes: 60000, packets: 100, frames: 48)])).single.verdict, FlowVerdict.flowing);
      judge.judge(_sample(2000, inbound: [_in('bob', 'video', bytes: 120000, packets: 200, frames: 48)]));
      final frozen = judge.judge(_sample(3000, inbound: [_in('bob', 'video', bytes: 180000, packets: 300, frames: 48)])).single;
      expect(frozen.verdict, FlowVerdict.stalled);
      expect(frozen.detail, 'decode_stalled');
    });

    test('no inbound row yet reads as zero packets, and the first row is a rise, not a reset', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', rowFound: false)]));
      final v = judge.judge(_sample(1000, inbound: [_in('bob', 'audio', packets: 50, energy: 0.1)])).single;
      expect(v.verdict, FlowVerdict.flowing);
      expect(v.packets, 50);
    });

    test('a new consumer id (they republished) starts a fresh baseline', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 900, energy: 3)]));
      final v = judge.judge(_sample(1000, inbound: [_in('bob', 'audio', packets: 5, energy: 0, consumer: 'c2')])).single;
      expect(v.verdict, FlowVerdict.notMeasured);
      expect(v.detail, 'no_baseline');
    });

    test('counters that go down are a reset, not a stall', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 900, energy: 3)]));
      final v = judge.judge(_sample(1000, inbound: [_in('bob', 'audio', packets: 5, energy: 0)])).single;
      expect(v.detail, 'counter_reset');
    });

    test('paused holds even when the stats call failed: a muted peer is not a measurement gap', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', paused: true, packets: 40, energy: 0.1)]));
      final v = judge.judge(_sample(1000, inbound: [_in('bob', 'audio', paused: true, measured: false)])).single;
      expect(v.verdict, FlowVerdict.paused);
      expect(v.detail, 'stats_failed');
      expect(FlowJudge().judge(_sample(0, inbound: [_in('bob', 'audio', paused: true, measured: false)])).single.verdict, FlowVerdict.paused,
          reason: 'with no baseline at all, too');
    });

    test('a paused stream whose counters went backwards is paused with no deltas, never negative ones', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'video', paused: true, packets: 900, bytes: 90000, frames: 300)]));
      final v = judge.judge(_sample(1000, inbound: [_in('bob', 'video', paused: true, rowFound: false)])).single;
      expect(v.verdict, FlowVerdict.paused);
      expect([v.bytes, v.packets, v.frames], [null, null, null]);
    });

    test('packetsLost going down (a late packet un-lost, RFC 3550) is a zero-loss interval, not a negative one', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 100, energy: 0.1, lost: 5)]));
      final v = judge.judge(_sample(1000, inbound: [_in('bob', 'audio', packets: 150, energy: 0.2, lost: 3)])).single;
      expect(v.verdict, FlowVerdict.flowing);
      expect(v.packetsLost, 0);
    });

    test("an unattributable stream (null counters) stays not_measured however long — never a stall", () {
      final judge = FlowJudge();
      for (var s = 0; s <= 4; s++) {
        final v = judge.judge(_sample(s * 1000, outbound: [const OutboundFlow(tag: 'audio', paused: false, producerId: 'p1')])).single;
        expect(v.verdict, FlowVerdict.notMeasured, reason: 'at ${s}s');
      }
    });

    test("each stream's interval is its own read time, not the sample's: one slow sibling skews nothing", () {
      final judge = FlowJudge();
      InboundFlow at(int ms, int packets, double energy) => InboundFlow(
            srcId: 'bob',
            tag: 'audio',
            paused: false,
            consumerId: 'c1',
            rowFound: true,
            measuredAt: _at(ms),
            counters: InboundCounters(packetsReceived: packets, totalAudioEnergy: energy),
          );
      // Both samples were stamped 2 s late by a sibling that timed out; bob's
      // own reads were one second apart.
      judge.judge(_sample(2000, inbound: [at(0, 10, 0.1)]));
      final v = judge.judge(_sample(4000, inbound: [at(1000, 60, 0.2)])).single;
      expect(v.intervalMs, 1000);
    });

    test('a subscribed peer that never announced is missing, and says what is known', () {
      final v = FlowJudge().judge(_sample(0, expected: [const ExpectedStream('bob', 'audio', why: 'awaiting_addr')])).single;
      expect(v.verdict, FlowVerdict.missing);
      expect(v.detail, 'awaiting_addr');
    });

    test('audio with no energy counter is flowing on packets, and says so', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 0)]));
      final v = judge.judge(_sample(1000, inbound: [_in('bob', 'audio', packets: 50)])).single;
      expect(v.verdict, FlowVerdict.flowing);
      expect(v.detail, 'energy_unknown');
    });

    test('outbound: a mic that sends packets but whose media source hears nothing is silent', () {
      final judge = FlowJudge();
      OutboundFlow mic(int packets, double energy, {bool paused = false}) => OutboundFlow(
            tag: 'audio',
            paused: paused,
            producerId: 'p1',
            rowFound: true,
            counters: OutboundCounters(packetsSent: packets, bytesSent: packets * 80, totalAudioEnergy: energy),
          );
      judge.judge(_sample(0, outbound: [mic(0, 0)]));
      final v = judge.judge(_sample(1000, outbound: [mic(50, 0)])).single;
      expect(v.key, 'out:audio');
      expect(v.direction, 'outbound');
      expect(v.verdict, FlowVerdict.silent);
      expect(judge.judge(_sample(2000, outbound: [mic(100, 0.4)])).single.verdict, FlowVerdict.flowing);
      expect(judge.judge(_sample(3000, outbound: [mic(100, 0.4, paused: true)])).single.verdict, FlowVerdict.paused);
    });

    test('outbound video flows on frames encoded', () {
      final judge = FlowJudge();
      OutboundFlow cam(int frames) => OutboundFlow(
            tag: 'video',
            paused: false,
            producerId: 'p2',
            rowFound: true,
            counters: OutboundCounters(packetsSent: frames * 4, bytesSent: frames * 2000, framesEncoded: frames),
          );
      judge.judge(_sample(0, outbound: [cam(0)]));
      expect(judge.judge(_sample(1000, outbound: [cam(30)])).single.verdict, FlowVerdict.flowing);
    });

    test('the log line is compact and names every stream', () {
      final judge = FlowJudge();
      judge.judge(_sample(0, inbound: [_in('bob', 'audio', packets: 0, energy: 0)], expected: [bob, bobVideo]));
      final line = flowLogLine(
        judge.judge(_sample(1000, inbound: [_in('bob', 'audio', packets: 50, energy: 0.1)], expected: [bob, bobVideo])),
        errors: const [FlowError('out:audio', 'x')],
      );
      expect(line, 'flow: in:bob|audio=flowing in:bob|video=missing(consumer_missing) errors=1');
      expect(flowLogLine(const []), 'flow: no streams');
    });
  });

  group('SfuSession.flowStats over the rig', () {
    late Rig rig;
    setUp(() => rig = Rig());
    tearDown(() => rig.close());
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    StatsReport row(String id, String type, Map<String, Object?> values) => StatsReport(id, type, 0, values);

    test('attributes each consumer\'s rows, reports what is expected, and times out per call', () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.announce(them, {'audio': 'p-a', 'video': 'p-v'});
      await settle();
      await settle();

      final consumers = rig.device.transports.expand((t) => t.consumers).toList();
      final audio = consumers.singleWhere((c) => c.appData['tag'] == 'audio');
      final video = consumers.singleWhere((c) => c.appData['tag'] == 'video');
      // The audio consumer's getStats answers for the whole receive connection:
      // its own row, the video's much larger one, and the transport's totals.
      audio.stats = [
        row('T', 'transport', {'bytesReceived': 5000000}),
        row('V', 'inbound-rtp', {'kind': 'video', 'trackIdentifier': 'track-${video.id}', 'bytesReceived': 900000, 'framesDecoded': 100}),
        row('A', 'inbound-rtp', {'kind': 'audio', 'trackIdentifier': 'track-${audio.id}', 'packetsReceived': 77, 'bytesReceived': 6160, 'totalAudioEnergy': 0.3}),
      ];
      video.statsHang = true;

      final sample = await rig.session.flowStats(timeout: const Duration(milliseconds: 50));
      expect(sample.source, 'live');
      expect(sample.expected.map((e) => e.key), unorderedEquals(['in:$them|audio', 'in:$them|video']));

      final inAudio = sample.inbound.singleWhere((i) => i.tag == 'audio');
      expect(inAudio.srcId, them);
      expect(inAudio.rowFound, isTrue);
      expect(inAudio.counters!.bytesReceived, 6160, reason: 'not the video row, not the transport');
      expect(inAudio.consumerId, audio.id);
      expect(inAudio.producerId, 'p-a');

      final inVideo = sample.inbound.singleWhere((i) => i.tag == 'video');
      expect(inVideo.counters, isNull, reason: 'its stats never answered');
      expect(sample.errors.map((e) => e.scope), contains('in:$them|video'));
      expect(sample.errors.singleWhere((e) => e.scope == 'in:$them|video').error, contains('timed out'));

      expect(FlowJudge().judge(sample).singleWhere((v) => v.tag == 'video').verdict, FlowVerdict.notMeasured);
      expect(sample.transports.map((t) => t.direction), contains('recv'));
    });

    test('a subscribed peer whose node never announced is expected for audio, with the reason', () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      await settle();
      final sample = await rig.session.flowStats(timeout: const Duration(milliseconds: 50));
      final e = sample.expected.single;
      expect(e.key, 'in:$them|audio');
      expect(e.why, isNotNull);
      expect(sample.errors.map((e) => e.scope), contains('in:$them|audio'));
      expect(FlowJudge().judge(sample).single.verdict, FlowVerdict.missing);

      rig.announce(them, const {});
      await settle();
      final muted = await rig.session.flowStats(timeout: const Duration(milliseconds: 50));
      expect(muted.expected, isEmpty, reason: 'announced nothing: legitimately muted, expected for nothing');
    });

    test('a stats call that never returns is not asked again while it is still pending', () async {
      await rig.session.start();
      await rig.session.subscribe(them);
      rig.announce(them, {'audio': 'p-a'});
      await settle();
      await settle();
      final audio = rig.device.transports.expand((t) => t.consumers).single..statsHang = true;
      expect(audio.appData['tag'], 'audio');

      final first = await rig.session.flowStats(timeout: const Duration(milliseconds: 20));
      expect(first.errors.singleWhere((e) => e.scope == 'in:$them|audio').error, contains('timed out'));
      final second = await rig.session.flowStats(timeout: const Duration(milliseconds: 20));
      expect(second.errors.singleWhere((e) => e.scope == 'in:$them|audio').error, startsWith('previous_still_pending'));
    });

    test('a second call while one is in flight shares it', () async {
      await rig.session.start();
      final a = rig.session.flowStats();
      final b = rig.session.flowStats();
      expect(identical(a, b), isTrue);
      await a;
      expect(identical(rig.session.flowStats(), a), isFalse, reason: 'and the next one is fresh');
    });
  });

  group('LiveCall flow log line (2.7)', () {
    LiveCall build(Rig rig, List<String> logs, {Duration? every}) => LiveCall(
          auth: GatherAuth(credentials: const GatherCredentials(refreshToken: 'unused')),
          spaceId: spaceId,
          srcId: me,
          engine: FakeCaptureEngine(),
          buildSfu: () => rig.session,
          log: logs.add,
          flowLogEvery: every,
        );

    // Only ever a false pass under load, never a false failure: an idle call
    // logs nothing however many ticks land.
    test('with the timer on but no session and nobody to hear, nothing is sampled', () async {
      final rig = Rig();
      final logs = <String>[];
      final call = build(rig, logs, every: const Duration(milliseconds: 20));
      addTearDown(() async {
        await call.dispose();
        await rig.close();
      });
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(logs.where((l) => l.startsWith('flow:')), isEmpty);
    });

    test('one tick with the mic published: one compact line naming the stream', () async {
      final rig = Rig();
      final logs = <String>[];
      final call = build(rig, logs);
      addTearDown(() async {
        await call.dispose();
        await rig.close();
      });
      expect(await call.setMicOn(true), isNull);
      await call.debugLogFlowNow();
      final lines = logs.where((l) => l.startsWith('flow:')).toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('out:audio='));
      expect(lines.single, isNot(contains('stalled')), reason: 'an unattributable mic is not_measured, never a stall');
    });
  });

  group('LiveCall.sampleFlow', () {
    test('with no media session: an empty live sample that says why', () async {
      final call = LiveCall(
        auth: GatherAuth(credentials: const GatherCredentials(refreshToken: 'unused')),
        spaceId: spaceId,
        srcId: me,
        engine: FakeCaptureEngine(),
      );
      addTearDown(call.dispose);
      final sample = await call.sampleFlow();
      expect(sample.source, 'live');
      expect(sample.inbound, isEmpty);
      expect(sample.errors.single.toJson(), {'scope': 'call', 'error': 'no_sfu_session'});
    });

    test('with the mic published but nothing to match it by: the stream is listed, and the decoy camera row is not credited to it', () async {
      final rig = Rig();
      final call = LiveCall(
        auth: GatherAuth(credentials: const GatherCredentials(refreshToken: 'unused')),
        spaceId: spaceId,
        srcId: me,
        engine: FakeCaptureEngine(),
        buildSfu: () => rig.session,
      );
      addTearDown(() async {
        await call.dispose();
        await rig.close();
      });
      expect(await call.setMicOn(true), isNull);
      final sample = await call.sampleFlow();
      final out = sample.outbound.single;
      expect(out.tag, 'audio');
      // The fake producer has no track id, mid or ssrc to match by, and its
      // stats are a whole connection's worth of decoys: so nothing is credited
      // to the mic rather than the camera's outbound row — and "no row of
      // ours" is no evidence of zero packets, so the counters are null
      // (not_measured), not zeros a judge would turn into a stall.
      expect(out.counters, isNull);
      expect(out.rowFound, isFalse);
      expect(sample.errors.map((e) => e.toJson()), contains(equals({'scope': 'out:audio', 'error': 'no track id, mid or ssrc to attribute rows by'})));
    });
  });

  // Every fixture above is hand-written, so it can only ever agree with the
  // parser's author about what a row looks like. This one is not: it is what
  // the vendored flutter_webrtc actually handed back on the iOS simulator
  // (test/fixtures/sim_loopback_stats.json, see its `_about`), field types as
  // the platform channel delivered them — `ssrc` an int, `mid` a String,
  // `jitter` a double, `concealedSamples` an int. A parser that only matched
  // the hand-written shape would read every real call as `not_measured`.
  group('real native rows (iOS simulator loopback)', () {
    final fixture = jsonDecode(File('test/fixtures/sim_loopback_stats.json').readAsStringSync()) as Map<String, Object?>;
    List<Map<String, Object?>> rows(int snap, String side) => [
          for (final r in ((fixture['snapshots'] as List)[snap] as Map)[side] as List) (r as Map).cast<String, Object?>(),
        ];
    final sendKeys = TrackKeys(
      kind: 'audio',
      trackId: fixture['localTrackId'] as String,
      mid: fixture['senderMid'] as String,
      ssrcs: {for (final s in fixture['senderSsrcs'] as List) s as int},
    );
    final recvKeys = TrackKeys(kind: 'audio', trackId: fixture['remoteTrackId'] as String, mid: fixture['receiverMid'] as String);

    test('the sender report is the whole peer connection, not just the track', () {
      final types = rows(0, 'sender').map((r) => r['type']).toSet();
      expect(types, containsAll(['outbound-rtp', 'media-source', 'transport', 'candidate-pair', 'remote-inbound-rtp']));
    });

    test('outbound audio: packets and bytes from outbound-rtp, level and energy from media-source', () {
      final out = parseOutboundStats(rows(1, 'sender'), sendKeys);
      expect(out.rowFound, isTrue);
      expect(out.counters.packetsSent, 353);
      expect(out.counters.bytesSent, 19791);
      expect(out.counters.audioLevel, closeTo(0.000824, 1e-6));
      expect(out.counters.totalAudioEnergy, greaterThan(0));
    });

    test('outbound matches by mid alone and by ssrc alone, as a mediasoup producer may only know one', () {
      final r = rows(1, 'sender');
      expect(parseOutboundStats(r, const TrackKeys(kind: 'audio', mid: '0')).counters.packetsSent, 353);
      expect(parseOutboundStats(r, TrackKeys(kind: 'audio', ssrcs: sendKeys.ssrcs)).counters.packetsSent, 353);
      expect(parseOutboundStats(r, const TrackKeys(kind: 'audio', mid: '7')).rowFound, isFalse);
    });

    test('inbound audio: every counter the plan reads, with the types the platform sent', () {
      final r = rows(1, 'receiver');
      final raw = r.firstWhere((row) => row['type'] == 'inbound-rtp');
      expect(raw['ssrc'], isA<int>());
      expect(raw['mid'], isA<String>());
      final got = parseInboundStats(r, recvKeys);
      expect(got.rowFound, isTrue);
      final c = got.counters;
      expect(c.packetsReceived, 353);
      expect(c.bytesReceived, 19791);
      expect(c.packetsLost, 0);
      expect(c.jitter, closeTo(0.002, 1e-9));
      expect(c.concealedSamples, 378);
      expect(c.totalSamplesReceived, 335040);
      expect(c.totalAudioEnergy, greaterThan(0));
      // Audio has no frames; null, not zero.
      expect(c.framesDecoded, isNull);
    });

    test('a video key never picks up the audio row', () {
      expect(parseInboundStats(rows(1, 'receiver'), TrackKeys(kind: 'video', trackId: recvKeys.trackId, mid: '0')).rowFound, isFalse);
    });

    test('transport state and RTT come from the transport row and its selected pair', () {
      final t = parseTransportStats(rows(1, 'receiver'), direction: 'recv');
      expect(t.iceState, 'connected');
      expect(t.dtlsState, 'connected');
      expect(t.selectedPairState, 'succeeded');
      expect(t.currentRoundTripTime, isNotNull);
      expect(t.bytesReceived, 34081);
    });

    test('two real readings two seconds apart judge as moving audio', () {
      MediaFlowSample sample(int snap, DateTime at) => MediaFlowSample(
            at: at,
            source: 'live',
            inbound: [
              InboundFlow(
                srcId: 'peer',
                tag: 'audio',
                paused: false,
                counters: parseInboundStats(rows(snap, 'receiver'), recvKeys).counters,
                rowFound: true,
                measuredAt: at,
              ),
            ],
            outbound: [
              OutboundFlow(
                tag: 'audio',
                paused: false,
                counters: parseOutboundStats(rows(snap, 'sender'), sendKeys).counters,
                rowFound: true,
                measuredAt: at,
              ),
            ],
            expected: const [ExpectedStream('peer', 'audio')],
          );
      final judge = FlowJudge();
      final t0 = DateTime(2026, 11, 11, 12);
      judge.judge(sample(0, t0));
      final verdicts = judge.judge(sample(1, t0.add(const Duration(seconds: 2))));
      expect({for (final v in verdicts) v.key: v.verdict}, {'in:peer|audio': FlowVerdict.flowing, 'out:audio': FlowVerdict.flowing});
    });
  });
}
