/// Whether media is actually moving, per stream, and the rows that prove it.
///
/// "The call is up" has never been the question that mattered. Every call bug
/// this app has had — the consume that was refused and never retried, the send
/// transport that went on acking produces into a dead node, the stale peer-node
/// cache that left one colleague dark forever — looked like a healthy call from
/// the signalling: producers accepted, consumers built, nobody paused. What was
/// wrong was that no packets moved, and the only witness to that is `getStats`.
/// This file turns those rows into a per-stream answer an agent (the debug
/// drive's `media.*`) or the `media.log` summary line can act on.
///
/// It is **pure Dart** on purpose — no `flutter_webrtc`, no `mediasoup` — so the
/// attribution and the verdicts are unit-tested against fixtures rather than
/// against a phone. `SfuSession.flowStats` is the only code that turns native
/// stats into the `Map` rows these functions read.
///
/// ## The attribution trap
///
/// A producer's or consumer's `getStats()` can return rows for the **whole peer
/// connection**, not just its own track (`SfuSession._reportOutboundRtp`). On
/// 2026-09-17 a silent microphone looked like healthy speech because the byte
/// count being admired was the camera's. So a row is credited to a track only
/// when its `kind` matches *and* one of `trackIdentifier`, `mid` or `ssrc`
/// matches *and* none of them contradicts. A row with the right kind and no
/// identifier at all is **not** attributed — with two peers' audio on one
/// receive transport, "the audio row" is a coin flip. `candidate-pair` and
/// `transport` rows are never read for a track: their bytes are every track on
/// the connection added together. They are reported per transport, and only
/// there.
///
/// ## The verdicts
///
/// [FlowJudge] compares one sample with the last, per stream, and answers with
/// one of [FlowVerdict]'s six words, exactly as `docs/debug-drive-plan.md`'s
/// verdict table defines them. Two rules carry most of the weight: `silent` is
/// **not** a failure (Opus DTX sends a trickle of comfort-noise packets with no
/// energy in them whenever the room is quiet), and `notMeasured` is **never**
/// folded into `stalled` — a stats call that timed out says nothing about the
/// media, and calling it a stall would send someone chasing a dead node that
/// was fine.
library;

/// One of Gather's stream tags, as the SFU spells them (`SfuTag.wire`). Kept as
/// strings here so this file need not import the session, which imports WebRTC.
const kFlowTags = ['audio', 'video', 'screen'];

/// The WebRTC `kind` behind a tag: screen share is video to the codec.
String kindOfTag(String tag) => tag == 'audio' ? 'audio' : 'video';

// ---- the sample -------------------------------------------------------------

/// What `inbound-rtp` (plus the legacy `track` row on older WebRTC builds) says
/// about one received track. Every field is nullable: a platform that does not
/// report a counter is *not measured*, not zero.
class InboundCounters {
  const InboundCounters({
    this.packetsReceived,
    this.bytesReceived,
    this.packetsLost,
    this.jitter,
    this.totalAudioEnergy,
    this.concealedSamples,
    this.totalSamplesReceived,
    this.framesReceived,
    this.framesDecoded,
    this.framesDropped,
    this.frameWidth,
    this.frameHeight,
    this.framesPerSecond,
    this.freezeCount,
    this.totalFreezesDuration,
  });

  final int? packetsReceived;
  final int? bytesReceived;
  final int? packetsLost;
  final double? jitter;
  final double? totalAudioEnergy;
  final int? concealedSamples;
  final int? totalSamplesReceived;
  final int? framesReceived;
  final int? framesDecoded;
  final int? framesDropped;
  final int? frameWidth;
  final int? frameHeight;
  final double? framesPerSecond;
  final int? freezeCount;
  final double? totalFreezesDuration;

  Map<String, Object?> toJson() => {
        'packetsReceived': packetsReceived,
        'bytesReceived': bytesReceived,
        'packetsLost': packetsLost,
        'jitter': jitter,
        'totalAudioEnergy': totalAudioEnergy,
        'concealedSamples': concealedSamples,
        'totalSamplesReceived': totalSamplesReceived,
        'framesReceived': framesReceived,
        'framesDecoded': framesDecoded,
        'framesDropped': framesDropped,
        'frameWidth': frameWidth,
        'frameHeight': frameHeight,
        'framesPerSecond': framesPerSecond,
        'freezeCount': freezeCount,
        'totalFreezesDuration': totalFreezesDuration,
      };
}

/// What `outbound-rtp` (summed over simulcast layers) and `media-source` say
/// about one sent track.
class OutboundCounters {
  const OutboundCounters({
    this.packetsSent,
    this.bytesSent,
    this.audioLevel,
    this.totalAudioEnergy,
    this.framesEncoded,
    this.frameWidth,
    this.frameHeight,
    this.qualityLimitationReason,
  });

  final int? packetsSent;
  final int? bytesSent;

  /// From `media-source`: the signal off the microphone, before encoding.
  final double? audioLevel;
  final double? totalAudioEnergy;
  final int? framesEncoded;
  final int? frameWidth;
  final int? frameHeight;
  final String? qualityLimitationReason;

  Map<String, Object?> toJson() => {
        'packetsSent': packetsSent,
        'bytesSent': bytesSent,
        'audioLevel': audioLevel,
        'totalAudioEnergy': totalAudioEnergy,
        'framesEncoded': framesEncoded,
        'frameWidth': frameWidth,
        'frameHeight': frameHeight,
        'qualityLimitationReason': qualityLimitationReason,
      };
}

/// One consumer: somebody else's track, as this phone receives it.
class InboundFlow {
  const InboundFlow({
    required this.srcId,
    required this.tag,
    required this.paused,
    this.consumerId,
    this.producerId,
    this.counters,
    this.rowFound = false,
    this.measuredAt,
  });

  final String srcId;

  /// `audio`, `video` or `screen`.
  final String tag;

  /// Whether the consumer is paused (their wire mute).
  final bool paused;
  final String? consumerId;
  final String? producerId;

  /// Null when the stats call failed or timed out — see the sample's errors.
  final InboundCounters? counters;

  /// Whether a row was attributed to this track. `false` with non-null
  /// [counters] means `getStats` answered and carried no RTP for it: WebRTC only
  /// creates an `inbound-rtp` row once the first packet arrives, so this is
  /// evidence of *no packets yet*, and [FlowJudge] reads it as zero.
  final bool rowFound;

  /// When *this* stream's counters were read, if not at the sample's [MediaFlowSample.at].
  ///
  /// A live sample's `at` is taken once every `getStats` in it has answered, and
  /// one slow call (up to its timeout) would otherwise date every other stream's
  /// counters seconds late — the interval [FlowJudge] divides by, and the point
  /// its stall clock starts from, would both be off by that much. So the session
  /// stamps each stream as its own call returns. A local clock rather than the
  /// report's own `timestamp`: that field's unit and epoch differ between
  /// platforms, and the judge only needs the two readings of one stream to be
  /// on the same clock.
  final DateTime? measuredAt;

  bool get measured => counters != null;
  String get key => 'in:$srcId|$tag';

  Map<String, Object?> toJson() => {
        'srcId': srcId,
        'tag': tag,
        'paused': paused,
        'consumerId': consumerId,
        'producerId': producerId,
        'measured': measured,
        'rowFound': rowFound,
        'measuredAt': ?measuredAt?.toUtc().toIso8601String(),
        'counters': counters?.toJson(),
      };
}

/// One producer: our own track, as this phone sends it.
class OutboundFlow {
  const OutboundFlow({
    required this.tag,
    required this.paused,
    this.producerId,
    this.counters,
    this.rowFound = false,
    this.measuredAt,
  });

  final String tag;
  final bool paused;
  final String? producerId;
  final OutboundCounters? counters;

  /// As [InboundFlow.rowFound].
  final bool rowFound;

  /// As [InboundFlow.measuredAt].
  final DateTime? measuredAt;

  bool get measured => counters != null;
  String get key => 'out:$tag';

  Map<String, Object?> toJson() => {
        'tag': tag,
        'paused': paused,
        'producerId': producerId,
        'measured': measured,
        'rowFound': rowFound,
        'measuredAt': ?measuredAt?.toUtc().toIso8601String(),
        'counters': counters?.toJson(),
      };
}

/// One peer connection — a send or receive transport — and whether ICE and DTLS
/// on it are alive. Per transport **only**: these bytes are every track on the
/// connection added together, which is why nothing here names a track.
class TransportFlow {
  const TransportFlow({
    required this.direction,
    this.id,
    this.node,
    this.connectionState,
    this.iceState,
    this.dtlsState,
    this.selectedPairState,
    this.currentRoundTripTime,
    this.bytesReceived,
    this.bytesSent,
  });

  /// `send` or `recv`.
  final String direction;
  final String? id;

  /// The SFU node url the transport was built on.
  final String? node;

  /// mediasoup's own `connectionstatechange` view.
  final String? connectionState;
  final String? iceState;
  final String? dtlsState;
  final String? selectedPairState;

  /// Seconds, as WebRTC reports it.
  final double? currentRoundTripTime;
  final int? bytesReceived;
  final int? bytesSent;

  TransportFlow withIdentity({String? id, String? node, String? connectionState}) => TransportFlow(
        direction: direction,
        id: id ?? this.id,
        node: node ?? this.node,
        connectionState: connectionState ?? this.connectionState,
        iceState: iceState,
        dtlsState: dtlsState,
        selectedPairState: selectedPairState,
        currentRoundTripTime: currentRoundTripTime,
        bytesReceived: bytesReceived,
        bytesSent: bytesSent,
      );

  Map<String, Object?> toJson() => {
        'direction': direction,
        'id': id,
        'node': node,
        'connectionState': connectionState,
        'iceState': iceState,
        'dtlsState': dtlsState,
        'selectedPairState': selectedPairState,
        'currentRoundTripTime': currentRoundTripTime,
        'bytesReceived': bytesReceived,
        'bytesSent': bytesSent,
      };
}

/// A stream the app expects to receive: a peer we are subscribed to (the
/// conversation, `listeningTo`) that has announced a producer for the tag.
///
/// Or one that has announced **nothing at all**: a subscribed peer whose node
/// never sent its `consume-try` — the router could not place it, its node never
/// answered, a stale or dead peer-node cache. Those are exactly the colleagues
/// who are dark, and without an entry they would be absent from every verdict
/// rather than `missing`. Such a peer is expected for `audio` (the one stream
/// every participant is presumed to have until they say otherwise), with [why]
/// naming what is known — `awaiting_addr`, `unreachable`, `consume_denied` or
/// just `not_announced`. A peer that announced an empty map is legitimately
/// publishing nothing and is expected for nothing.
class ExpectedStream {
  const ExpectedStream(this.srcId, this.tag, {this.why});

  final String srcId;
  final String tag;

  /// Set only for a peer that never announced; becomes the `missing` verdict's
  /// detail. Not part of equality: it describes the stream, it is not its name.
  final String? why;

  String get key => 'in:$srcId|$tag';

  Map<String, Object?> toJson() => {'srcId': srcId, 'tag': tag, 'why': ?why};

  @override
  bool operator ==(Object other) => other is ExpectedStream && other.srcId == srcId && other.tag == tag;

  @override
  int get hashCode => Object.hash(srcId, tag);
}

/// Something that could not be read, and where. [scope] is a stream or
/// transport key (`in:bob|audio`, `out:video`, `transport:recv@wss://…`) or
/// `call` for the whole sample.
class FlowError {
  const FlowError(this.scope, this.error);

  final String scope;
  final String error;

  Map<String, Object?> toJson() => {'scope': scope, 'error': error};
}

/// One reading of the call's media, at one moment.
class MediaFlowSample {
  const MediaFlowSample({
    required this.at,
    required this.source,
    this.inbound = const [],
    this.outbound = const [],
    this.transports = const [],
    this.expected = const [],
    this.errors = const [],
  });

  /// A sample with nothing in it and the reason why — never a bare empty one.
  factory MediaFlowSample.empty({required DateTime at, required String source, required String why}) =>
      MediaFlowSample(at: at, source: source, errors: [FlowError('call', why)]);

  final DateTime at;

  /// `live` (read off the SFU) or `scripted` (the harness or a test). Carried so
  /// a scripted reading is never mistaken for the wire.
  final String source;
  final List<InboundFlow> inbound;
  final List<OutboundFlow> outbound;
  final List<TransportFlow> transports;
  final List<ExpectedStream> expected;
  final List<FlowError> errors;

  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'source': source,
        'inbound': [for (final i in inbound) i.toJson()],
        'outbound': [for (final o in outbound) o.toJson()],
        'transports': [for (final t in transports) t.toJson()],
        'expected': [for (final e in expected) e.toJson()],
        'errors': [for (final e in errors) e.toJson()],
      };
}

// ---- attribution -------------------------------------------------------------

/// What identifies one track in a stats report. [kind] is `audio` or `video`;
/// the rest are whatever the mediasoup object knows — the track's id (WebRTC's
/// `trackIdentifier`), the transceiver `mid` (mediasoup's `localId`) and the
/// encodings' SSRCs.
class TrackKeys {
  const TrackKeys({required this.kind, this.trackId, this.mid, this.ssrcs = const {}});

  final String kind;
  final String? trackId;
  final String? mid;
  final Set<int> ssrcs;

  bool get hasIdentity => trackId != null || mid != null || ssrcs.isNotEmpty;
}

/// [parseInboundStats]' answer: the counters, and whether any row was ours.
typedef InboundParse = ({InboundCounters counters, bool rowFound});

/// [parseOutboundStats]' answer.
typedef OutboundParse = ({OutboundCounters counters, bool rowFound});

/// The `inbound-rtp` row for the track [keys] names, out of a report that may
/// hold the whole peer connection. See the file header for the matching rule.
///
/// Two matching rows (a renegotiation can briefly leave both) take the one with
/// more packets. A legacy `track` row the RTP row points at (`trackId`) fills
/// counters older WebRTC builds reported there — and also counts as the
/// `trackIdentifier` match when the RTP row itself lacks one.
InboundParse parseInboundStats(List<Map<String, Object?>> reports, TrackKeys keys) {
  final byId = _byId(reports);
  Map<String, Object?>? best;
  Map<String, Object?>? bestTrack;
  for (final row in reports) {
    if (row['type'] != 'inbound-rtp') continue;
    final legacy = byId[row['trackId']];
    final track = legacy != null && legacy['type'] == 'track' ? legacy : null;
    if (!_matches(row, keys, trackIdentifier: row['trackIdentifier'] ?? track?['trackIdentifier'])) continue;
    if (best == null || (_int(row['packetsReceived']) ?? 0) > (_int(best['packetsReceived']) ?? 0)) {
      best = row;
      bestTrack = track;
    }
  }
  if (best == null) return (counters: const InboundCounters(), rowFound: false);
  Object? read(String field) => best![field] ?? bestTrack?[field];
  return (
    counters: InboundCounters(
      packetsReceived: _int(read('packetsReceived')),
      bytesReceived: _int(read('bytesReceived')),
      packetsLost: _int(read('packetsLost')),
      jitter: _double(read('jitter')),
      totalAudioEnergy: _double(read('totalAudioEnergy')),
      concealedSamples: _int(read('concealedSamples')),
      totalSamplesReceived: _int(read('totalSamplesReceived')),
      framesReceived: _int(read('framesReceived')),
      framesDecoded: _int(read('framesDecoded')),
      framesDropped: _int(read('framesDropped')),
      frameWidth: _int(read('frameWidth')),
      frameHeight: _int(read('frameHeight')),
      framesPerSecond: _double(read('framesPerSecond')),
      freezeCount: _int(read('freezeCount')),
      totalFreezesDuration: _double(read('totalFreezesDuration')),
    ),
    rowFound: true,
  );
}

/// The `outbound-rtp` rows (one per simulcast layer) and the `media-source` row
/// for the track [keys] names.
///
/// `outbound-rtp` carries no `trackIdentifier`; it points at its `media-source`
/// through `mediaSourceId`, and *that* row carries it. So a layer matches by
/// `mid`, by SSRC, or through its media source's track id. Layers are summed
/// (packets, bytes, frames) and the largest frame size wins, with its
/// `qualityLimitationReason`, because that is the layer someone is likeliest to
/// be watching.
OutboundParse parseOutboundStats(List<Map<String, Object?>> reports, TrackKeys keys) {
  final byId = _byId(reports);
  final layers = <Map<String, Object?>>[];
  for (final row in reports) {
    if (row['type'] != 'outbound-rtp') continue;
    final source = byId[row['mediaSourceId']];
    if (_matches(row, keys, trackIdentifier: source?['trackIdentifier'])) layers.add(row);
  }

  // The media source: by track id, or the one a matched layer points at.
  Map<String, Object?>? source;
  final pointedAt = {for (final l in layers) l['mediaSourceId']}..remove(null);
  for (final row in reports) {
    if (row['type'] != 'media-source' || _kindOf(row) != keys.kind) continue;
    final byTrack = keys.trackId != null && row['trackIdentifier'] == keys.trackId;
    final contradicts = keys.trackId != null && row['trackIdentifier'] != null && row['trackIdentifier'] != keys.trackId;
    if (contradicts) continue;
    if (byTrack || pointedAt.contains(row['id'])) {
      source = row;
      break;
    }
  }

  if (layers.isEmpty && source == null) return (counters: const OutboundCounters(), rowFound: false);

  int? sum(String field) {
    int? total;
    for (final l in layers) {
      final v = _int(l[field]);
      if (v != null) total = (total ?? 0) + v;
    }
    return total;
  }

  Map<String, Object?>? widest;
  for (final l in layers) {
    if (widest == null || (_int(l['frameWidth']) ?? -1) > (_int(widest['frameWidth']) ?? -1)) widest = l;
  }
  return (
    counters: OutboundCounters(
      packetsSent: sum('packetsSent'),
      bytesSent: sum('bytesSent'),
      audioLevel: _double(source?['audioLevel']),
      totalAudioEnergy: _double(source?['totalAudioEnergy']),
      framesEncoded: sum('framesEncoded'),
      frameWidth: _int(widest?['frameWidth']),
      frameHeight: _int(widest?['frameHeight']),
      qualityLimitationReason: _str(widest?['qualityLimitationReason']),
    ),
    rowFound: layers.isNotEmpty,
  );
}

/// ICE/DTLS state for a whole peer connection: the `transport` row and its
/// selected `candidate-pair` (by `selectedCandidatePairId`, else the pair
/// flagged `selected`, else a nominated succeeded one). [direction] is copied
/// through; node and ids are the caller's to add ([TransportFlow.withIdentity]).
TransportFlow parseTransportStats(List<Map<String, Object?>> reports, {required String direction}) {
  final byId = _byId(reports);
  Map<String, Object?>? transport;
  for (final row in reports) {
    if (row['type'] == 'transport') {
      transport = row;
      break;
    }
  }
  var pair = byId[transport?['selectedCandidatePairId']];
  if (pair == null) {
    for (final row in reports) {
      if (row['type'] != 'candidate-pair') continue;
      if (row['selected'] == true) {
        pair = row;
        break;
      }
      if (pair == null && row['nominated'] == true && row['state'] == 'succeeded') pair = row;
    }
  }
  return TransportFlow(
    direction: direction,
    iceState: _str(transport?['iceState'] ?? transport?['iceTransportState']),
    dtlsState: _str(transport?['dtlsState']),
    selectedPairState: _str(pair?['state']),
    currentRoundTripTime: _double(pair?['currentRoundTripTime']),
    bytesReceived: _int(transport?['bytesReceived'] ?? pair?['bytesReceived']),
    bytesSent: _int(transport?['bytesSent'] ?? pair?['bytesSent']),
  );
}

/// Whether [row] is the track [keys] names: right kind, at least one identifier
/// in common, and none that disagrees.
bool _matches(Map<String, Object?> row, TrackKeys keys, {Object? trackIdentifier}) {
  if (_kindOf(row) != keys.kind) return false;
  var agree = false;
  if (keys.trackId != null && trackIdentifier != null) {
    if (trackIdentifier != keys.trackId) return false;
    agree = true;
  }
  final mid = row['mid'];
  if (keys.mid != null && mid != null) {
    if ('$mid' != keys.mid) return false;
    agree = true;
  }
  final ssrc = _int(row['ssrc']);
  if (keys.ssrcs.isNotEmpty && ssrc != null) {
    if (!keys.ssrcs.contains(ssrc)) return false;
    agree = true;
  }
  return agree;
}

String? _kindOf(Map<String, Object?> row) => _str(row['kind'] ?? row['mediaType']);

/// A native stats value as a string, whatever type the platform sent. A hard
/// `as String?` here is a `TypeError` the day one platform reports an enum as
/// an int, and that would lose the whole sample rather than one field.
String? _str(Object? v) => v == null ? null : (v is String ? v : '$v');

Map<Object?, Map<String, Object?>> _byId(List<Map<String, Object?>> reports) => {
      for (final r in reports)
        if (r['id'] != null) r['id']: r,
    };

int? _int(Object? v) => switch (v) {
      int() => v,
      double() when v.isFinite => v.round(),
      String() => int.tryParse(v) ?? double.tryParse(v)?.round(),
      _ => null,
    };

double? _double(Object? v) => switch (v) {
      num() => v.toDouble(),
      String() => double.tryParse(v),
      _ => null,
    };

// ---- verdicts -----------------------------------------------------------------

/// The plan's six words for a stream over one interval.
enum FlowVerdict {
  /// Packets rise; video: `framesDecoded` (or `framesEncoded`) rises; audio:
  /// energy rises.
  flowing('flowing'),

  /// Audio packets rise but `totalAudioEnergy` is flat — the peer is sending
  /// silence. Opus DTX makes this normal; **not** a failure on its own.
  silent('silent'),

  /// Unpaused, and counters flat for at least the stall window.
  stalled('stalled'),

  /// The consumer or producer is paused (wire mute); flat counters expected.
  paused('paused'),

  /// Expected — subscribed, and the peer announced a producer for the tag — but
  /// there is no consumer.
  missing('missing'),

  /// `getStats` failed or timed out, or there is not yet enough history to
  /// judge. Never folded into [stalled].
  notMeasured('not_measured');

  const FlowVerdict(this.wire);

  final String wire;
}

/// One stream's verdict for one interval, with the deltas behind it.
class StreamVerdict {
  const StreamVerdict({
    required this.key,
    required this.direction,
    required this.tag,
    required this.verdict,
    this.srcId,
    this.detail,
    this.intervalMs,
    this.bytes,
    this.packets,
    this.packetsLost,
    this.frames,
    this.flatForMs,
  });

  /// `in:<srcId>|<tag>` or `out:<tag>`.
  final String key;

  /// `inbound` or `outbound`.
  final String direction;
  final String? srcId;
  final String tag;
  final FlowVerdict verdict;

  /// Why, in a word, when the verdict alone would not say: `consumer_missing`,
  /// `stats_failed`, `no_baseline`, `counter_reset`, `settling`, `grace`,
  /// `energy_unknown`, `decode_stalled` — or, on a `missing` peer that never
  /// announced, its [ExpectedStream.why] (`awaiting_addr`, `unreachable`,
  /// `consume_denied`, `not_announced`).
  final String? detail;

  /// The interval the deltas cover, when there was a baseline.
  final int? intervalMs;
  final int? bytes;
  final int? packets;
  final int? packetsLost;

  /// Frames decoded (inbound) or encoded (outbound) in the interval.
  final int? frames;

  /// How long counters have been flat, when they are.
  final int? flatForMs;

  Map<String, Object?> toJson() => {
        'key': key,
        'direction': direction,
        'srcId': ?srcId,
        'tag': tag,
        'verdict': verdict.wire,
        'detail': ?detail,
        'intervalMs': ?intervalMs,
        'bytes': ?bytes,
        'packets': ?packets,
        'packetsLost': ?packetsLost,
        'frames': ?frames,
        'flatForMs': ?flatForMs,
      };
}

/// What [FlowJudge] remembers about one stream between samples.
class _Memory {
  _Memory(this.at, this.id, this.values);

  DateTime at;
  String? id;
  _Values values;
  DateTime? flatSince;
  FlowVerdict? last;
}

/// The counters a verdict reads, normalised across directions.
class _Values {
  const _Values({this.packets, this.bytes, this.energy, this.frames, this.lost});

  final int? packets;
  final int? bytes;
  final double? energy;
  final int? frames;
  final int? lost;
}

/// Verdicts over a sequence of samples, one stream at a time.
///
/// Stateful only in what it must remember between two samples — the last
/// counters per stream and how long they have been flat — and free of clocks
/// and I/O: time is the samples' own [MediaFlowSample.at], so a test drives it
/// with hand-built samples and a watch with a fake clock gets the same answers.
///
/// Rules beyond the plan's table, each forced by a case the table leaves open:
///
///  * **A first reading has no verdict to give**: `notMeasured` / `no_baseline`.
///    So does a consumer whose id changed (a republish) or whose counters went
///    *down* (`counter_reset`) — a fresh consumer restarts at zero, and a
///    negative delta judged as "flat" would be a stall nobody had.
///  * **Flat for less than [stallAfter]** keeps the stream's last good verdict
///    (`detail: grace`) — one slow interval is not a fault. With no good verdict
///    yet it is `notMeasured` / `settling`: there is not enough evidence either
///    way, and calling it flowing would be invented.
///  * **Video is judged on frames**: bytes arriving while `framesDecoded` stands
///    still is a frozen picture, so it runs the stall clock (`decode_stalled`).
///    Only when the platform reports no frame counter at all are bytes used.
///  * **Audio with no energy counter** is judged on packets alone and says so
///    (`energy_unknown`), rather than guessing silent or flowing on sound.
///  * **No inbound row** (`rowFound: false`) on a measured consumer reads as
///    zero packets: WebRTC only creates the row on the first packet.
class FlowJudge {
  FlowJudge({this.stallAfter = const Duration(seconds: 2)});

  /// How long counters must stay flat on an unpaused stream before `stalled`.
  final Duration stallAfter;

  final Map<String, _Memory> _memory = {};

  /// The verdict for every expected or present stream in [sample], against the
  /// sample before it. Inbound streams first (expected order, then any extra),
  /// then outbound.
  List<StreamVerdict> judge(MediaFlowSample sample) {
    final out = <StreamVerdict>[];
    final seen = <String>{};
    final inboundByKey = {for (final i in sample.inbound) i.key: i};

    final inboundKeys = <String>[
      for (final e in sample.expected) e.key,
      for (final i in sample.inbound) i.key,
    ];
    for (final key in inboundKeys) {
      if (!seen.add(key)) continue;
      final flow = inboundByKey[key];
      if (flow == null) {
        final e = sample.expected.firstWhere((e) => e.key == key);
        _memory.remove(key);
        out.add(StreamVerdict(
          key: key,
          direction: 'inbound',
          srcId: e.srcId,
          tag: e.tag,
          verdict: FlowVerdict.missing,
          detail: e.why ?? 'consumer_missing',
        ));
        continue;
      }
      final c = flow.counters;
      out.add(_judgeOne(
        key: key,
        direction: 'inbound',
        srcId: flow.srcId,
        tag: flow.tag,
        at: flow.measuredAt ?? sample.at,
        id: flow.consumerId,
        paused: flow.paused,
        values: c == null
            ? null
            : _Values(
                packets: _orZero(c.packetsReceived, flow.rowFound),
                bytes: _orZero(c.bytesReceived, flow.rowFound),
                energy: flow.rowFound ? c.totalAudioEnergy : 0,
                frames: _orZero(c.framesDecoded, flow.rowFound),
                lost: _orZero(c.packetsLost, flow.rowFound),
              ),
      ));
    }

    for (final flow in sample.outbound) {
      if (!seen.add(flow.key)) continue;
      final c = flow.counters;
      out.add(_judgeOne(
        key: flow.key,
        direction: 'outbound',
        tag: flow.tag,
        at: flow.measuredAt ?? sample.at,
        id: flow.producerId,
        paused: flow.paused,
        values: c == null
            ? null
            : _Values(
                packets: _orZero(c.packetsSent, flow.rowFound),
                bytes: _orZero(c.bytesSent, flow.rowFound),
                energy: c.totalAudioEnergy,
                frames: _orZero(c.framesEncoded, flow.rowFound),
              ),
      ));
    }

    // A stream that is neither expected nor present any more is forgotten, so
    // its return starts from a fresh baseline rather than a stale one.
    _memory.removeWhere((key, _) => !seen.contains(key));
    return out;
  }

  static int? _orZero(int? v, bool rowFound) => rowFound ? v : (v ?? 0);

  StreamVerdict _judgeOne({
    required String key,
    required String direction,
    String? srcId,
    required String tag,
    required DateTime at,
    required String? id,
    required bool paused,
    required _Values? values,
  }) {
    StreamVerdict v(FlowVerdict verdict, {String? detail, int? intervalMs, _Values? d, int? flatForMs}) => StreamVerdict(
          key: key,
          direction: direction,
          srcId: srcId,
          tag: tag,
          verdict: verdict,
          detail: detail,
          intervalMs: intervalMs,
          bytes: d?.bytes,
          packets: d?.packets,
          packetsLost: d?.lost,
          frames: d?.frames,
          flatForMs: flatForMs,
        );

    final memory = _memory[key];

    // Paused comes off the consumer/producer object, not off stats, so it holds
    // even when the stats call failed — and a muted peer must not read as a
    // measurement gap. The baseline is kept for when they unmute.
    if (values == null && paused) {
      memory
        ?..flatSince = null
        ..last = FlowVerdict.paused;
      return v(FlowVerdict.paused, detail: 'stats_failed');
    }

    // Not measured: keep the memory, so the next good reading still has a
    // baseline — but never advance the stall clock on no evidence.
    if (values == null) return v(FlowVerdict.notMeasured, detail: 'stats_failed');

    if (memory == null || memory.id != id) {
      _memory[key] = _Memory(at, id, values)..last = paused ? FlowVerdict.paused : null;
      return paused ? v(FlowVerdict.paused) : v(FlowVerdict.notMeasured, detail: 'no_baseline');
    }

    final intervalMs = at.difference(memory.at).inMilliseconds;
    final prev = memory.values;
    final d = _Values(
      packets: _delta(prev.packets, values.packets),
      bytes: _delta(prev.bytes, values.bytes),
      frames: _delta(prev.frames, values.frames),
      // RTP `packetsLost` may legitimately go *down* (a late or duplicate packet
      // un-loses one, RFC 3550), so a negative delta is no reset — it is zero.
      lost: switch (_delta(prev.lost, values.lost)) { final l? when l < 0 => 0, final l => l },
    );
    final energyDelta = (prev.energy != null && values.energy != null) ? values.energy! - prev.energy! : null;
    memory
      ..at = at
      ..values = values;

    final reset = [d.packets, d.bytes, d.frames].any((x) => x != null && x < 0) || (energyDelta != null && energyDelta < 0);

    // A paused stream whose counters went backwards still reads as paused, but
    // carries no deltas: a negative one would be summed into a watch's bitrate.
    if (paused) {
      memory
        ..flatSince = null
        ..last = FlowVerdict.paused;
      return v(FlowVerdict.paused, intervalMs: intervalMs, d: reset ? null : d);
    }

    if (reset) {
      memory
        ..flatSince = null
        ..last = null;
      return v(FlowVerdict.notMeasured, detail: 'counter_reset', intervalMs: intervalMs);
    }

    final rtpMoving = (d.packets ?? d.bytes ?? 0) > 0;
    final isAudio = tag == 'audio';
    final moving = isAudio ? rtpMoving : (d.frames != null ? d.frames! > 0 : rtpMoving);

    if (moving) {
      memory.flatSince = null;
      final FlowVerdict verdict;
      String? detail;
      if (!isAudio) {
        verdict = FlowVerdict.flowing;
      } else if (energyDelta == null) {
        verdict = FlowVerdict.flowing;
        detail = 'energy_unknown';
      } else {
        verdict = energyDelta > 0 ? FlowVerdict.flowing : FlowVerdict.silent;
      }
      memory.last = verdict;
      return v(verdict, detail: detail, intervalMs: intervalMs, d: d);
    }

    if (d.packets == null && d.bytes == null && d.frames == null) {
      // Measured, yet no counter at all on either side: nothing to judge by.
      return v(FlowVerdict.notMeasured, detail: 'no_counters', intervalMs: intervalMs);
    }

    final flatSince = memory.flatSince ??= at.subtract(Duration(milliseconds: intervalMs));
    final flatFor = at.difference(flatSince);
    final detail = (!isAudio && rtpMoving) ? 'decode_stalled' : null;
    if (flatFor >= stallAfter) {
      memory.last = FlowVerdict.stalled;
      return v(FlowVerdict.stalled, detail: detail, intervalMs: intervalMs, d: d, flatForMs: flatFor.inMilliseconds);
    }
    final last = memory.last;
    if (last == FlowVerdict.flowing || last == FlowVerdict.silent) {
      return v(last!, detail: 'grace', intervalMs: intervalMs, d: d, flatForMs: flatFor.inMilliseconds);
    }
    return v(FlowVerdict.notMeasured, detail: detail ?? 'settling', intervalMs: intervalMs, d: d, flatForMs: flatFor.inMilliseconds);
  }

  static int? _delta(int? a, int? b) => (a == null || b == null) ? null : b - a;
}

/// One line for `media.log`: `flow: in:bob|audio=flowing out:audio=silent …`.
/// Compact on purpose — it is written every few seconds for the whole call.
String flowLogLine(List<StreamVerdict> verdicts, {List<FlowError> errors = const []}) {
  final parts = [
    for (final v in verdicts) '${v.key}=${v.verdict.wire}${v.detail == null ? '' : '(${v.detail})'}',
    if (errors.isNotEmpty) 'errors=${errors.length}',
  ];
  return 'flow: ${parts.isEmpty ? 'no streams' : parts.join(' ')}';
}
