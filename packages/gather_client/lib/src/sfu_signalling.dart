/// Talking to Gather's media plane.
///
/// The game socket carries presence. Media is a **separate protocol on separate
/// sockets**: Socket.IO rather than msgpack, at
/// `wss://router.v2.gather.town` for SFU assignment and at a per-node
/// `wss://sfu-v2.<region>.prod.aws.gather.town/ip-<addr>` for the media itself.
/// Captured off the desktop client 2026-08-13 with `tool/probe-sfu.mjs`; the
/// message tables are in `docs/gather-api.md`.
///
/// This class is the transport and nothing more. It knows how to authenticate,
/// how to ask a question and match the answer, and how to hand on the things the
/// server says unprompted. It does not know what a producer is. That keeps the
/// reverse-engineered half — the half most likely to be wrong — in a package
/// `dart test` can exercise in seconds with no device and no camera.
///
/// ## Three things that are not guesses
///
/// **Auth is the Socket.IO CONNECT packet.** `{spaceId, token}`, where `token` is
/// the same Firebase ID token the game socket uses. Not a header, not a query
/// parameter, and there is no separate "video token" to fetch — which is why
/// [GatherAuth] is enough to get in.
///
/// **The correlation key is the Socket.IO ack id.** Gather's `sendWithResponse`
/// is not a bespoke mechanism layered on a socket; it is `emit(name, args, cb)`.
/// So [sendWithResponse] is a thin wrapper over `emitWithAck` rather than the
/// hand-rolled pending-completer map the game socket would have needed — and
/// specifically **not** `emitWithAckAsync`, for the reason spelled out at the call
/// itself: half of Gather's methods answer with an empty array, which that method
/// cannot survive.
///
/// **Most calls carry a sequence number, but not all.** The envelope is
/// `{wsSequenceNumber, zodData}` — except for [_bareMethods], which send their
/// arguments unwrapped. Wrapping an exempt call, or failing to wrap a normal one,
/// is the kind of mistake Gather answers with silence rather than an error.
///
/// ## Reconnection is ours, not the library's
///
/// `reconnection` is disabled deliberately, mirroring the desktop client. An ID
/// token lives about an hour, so a socket that silently reconnected would
/// eventually re-present a dead credential and fail in a way that looks like a
/// network fault. Every connection here mints a fresh token first.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'gather_auth.dart';

/// The assignment service. Answers "which node carries this person's media?".
const gatherSfuRouter = 'wss://router.v2.gather.town';

/// Socket.IO's own path. Gather does not customise it.
const _socketIoPath = '/socket.io/';

/// Splits a Gather SFU address into what `socket_io_client` actually wants.
///
/// **The address the router hands out is not a URL you can connect to.** It
/// arrives as `wss://sfu-v2.<region>….prod.aws.gather.town:443/ip-10-206-194-73`,
/// and both halves after the host are traps:
///
///  * **The `/ip-…` segment is a path prefix, not a namespace.** Handed to
///    `socket_io_client` whole, it is read as the Socket.IO *namespace* and the
///    request goes to `/socket.io/` at the root — which the node answers with a
///    plain HTTP response, so the upgrade never happens. The desktop client
///    connects to `/ip-10-206-194-73/socket.io/`, measured; the prefix belongs in
///    the `path` option.
///  * **`wss://` with an explicit `:443` yields port 0.** `socket_io_client`
///    fills in a default port for `http`/`https` and does not recognise `ws`/`wss`,
///    so the explicit port survives into a URI it then mangles — the failure
///    reads `Connection to 'https://…:0/socket.io/…' was not upgraded to
///    websocket`. Handing it `https://` and letting it supply 443 is what the
///    library expects.
///
/// The router's own address has neither problem, which is exactly why this went
/// unnoticed until the first node connection: `wss://router.v2.gather.town` has no
/// port and no path, so it survived being passed through raw.
({String origin, String path}) splitSfuAddress(String address) {
  final uri = Uri.parse(address);
  final scheme = switch (uri.scheme) {
    'wss' => 'https',
    'ws' => 'http',
    final other => other,
  };

  // Only a non-default port is worth keeping. 443 on wss is what the router
  // states and what the client drops.
  final port = uri.hasPort && uri.port != 443 && uri.port != 80 && uri.port != 0
      ? ':${uri.port}'
      : '';

  final prefix = uri.path.replaceAll(RegExp(r'/+$'), '');
  return (
    origin: '$scheme://${uri.host}$port',
    path: prefix.isEmpty ? _socketIoPath : '$prefix$_socketIoPath',
  );
}

/// Calls whose arguments are sent bare, with no `{wsSequenceNumber, zodData}`.
///
/// Measured, not assumed: `get-addr` and `unsubscribe` went out as plain
/// `{srcId, srcStreamId}` while everything else on the same socket was wrapped.
/// `addrs` and `reassign` are on the bundle's exemption list too.
const _bareMethods = {'get-addr', 'unsubscribe', 'reassign', 'addrs'};

/// Everything the server is known to say unprompted, on either socket.
///
/// The measured set from `docs/gather-api.md` — `consume-try`, `consume-close`,
/// `producer-paused`/`-resumed`, `set-max-spatial-layer`, `server-info` — plus
/// the router's `addrs`, `cordon-sfu` and `reassign`, and the four the bundle
/// declares but no capture has caught yet (`consume-connected`,
/// `consume-not-allowed`, `disable-video`, `move-off`).
///
/// This list exists to be *wrong* eventually. Anything outside it lands in
/// [SfuSignalling.unknownEvents], which is how a protocol change announces itself
/// as a number going up rather than as a feature quietly not working.
const _knownEvents = {
  'addrs',
  'cordon-sfu',
  'reassign',
  'consume-try',
  'consume-close',
  'consume-connected',
  'consume-not-allowed',
  'producer-paused',
  'producer-resumed',
  'set-max-spatial-layer',
  'server-info',
  'double-connected',
  'disable-video',
  'move-off',
};

const _defaultTimeout = Duration(seconds: 15);

/// How long [SfuSignalling.start] waits for the handshake before giving up.
///
/// Shorter than [_defaultTimeout] on purpose: this one is in front of a person
/// who has just tapped *unmute*, and ten seconds of a dead button is long past
/// the point where they tap it again.
const _connectTimeout = Duration(seconds: 10);
const _maxBackoff = Duration(seconds: 30);

/// Something the server said without being asked.
///
/// `consume-try` is the important one — it carries a peer's entire
/// `producerIdMap`, so it is a full-state announcement rather than a delta and
/// callers should reconcile against it rather than treat it as an event.
class SfuNotification {
  const SfuNotification(this.name, this.data);

  final String name;
  final Map<String, Object?> data;

  @override
  String toString() => 'SfuNotification($name, $data)';
}

/// Whether the socket is usable, and what to say if not.
///
/// Mirrors `CollectorStatus` deliberately: the app already knows how to render
/// one of these, and the honesty rule is the same — report unhealthy while
/// connected-but-not-joined rather than implying media is flowing.
class SfuStatus {
  const SfuStatus({required this.healthy, this.detail, this.needsPairing = false});

  final bool healthy;
  final String? detail;

  /// The credential is dead and only re-pairing will fix it.
  final bool needsPairing;

  @override
  String toString() => 'SfuStatus($healthy, $detail)';
}

class SfuException implements Exception {
  const SfuException(this.message);
  final String message;

  @override
  String toString() => 'SfuException($message)';
}

/// One Socket.IO connection to a router or an SFU node.
///
/// A call spans several of these — one router plus one per media node, since
/// peers can be spread across nodes — so this is deliberately per-socket and
/// holds no opinion about how many exist.
class SfuSignalling {
  SfuSignalling({
    required GatherAuth auth,
    required String url,
    required String spaceId,
    String? sessionId,
    io.Socket Function(String uri, Map<String, dynamic> options)? connect,
    void Function(String)? log,
    // A named parameter cannot be a private initializing formal — `this._url`
    // would make the argument label private too — so these are assigned the long
    // way round, same as `DirectCollector`.
  })  :
        // ignore: prefer_initializing_formals
        _auth = auth,
        // ignore: prefer_initializing_formals
        _url = url,
        // ignore: prefer_initializing_formals
        _spaceId = spaceId,
        // ignore: prefer_initializing_formals
        _sessionId = sessionId,
        _connect = connect ?? _defaultConnect,
        _log = log ?? _noop;

  static void _noop(String _) {}

  static io.Socket _defaultConnect(String uri, Map<String, dynamic> options) =>
      io.io(uri, options);

  final GatherAuth _auth;
  final String _url;
  final String _spaceId;

  /// Overridable so tests can point at a fake Socket.IO server.
  final io.Socket Function(String uri, Map<String, dynamic> options) _connect;
  final void Function(String) _log;

  /// A per-connection nonce the SFU URL carries as `?sessionId=`.
  ///
  /// Client-generated: it appears nowhere in any inbound frame, and two captured
  /// connections produced two unrelated UUIDs. Minted here when not supplied.
  final String? _sessionId;

  io.Socket? _socket;
  Timer? _retryTimer;
  Duration _backoff = const Duration(seconds: 1);
  bool _stopped = false;
  bool _connected = false;
  int _sequence = 0;

  /// Completed the moment the socket is usable — see [start].
  Completer<void>? _ready;

  /// Frames the server sent that this client does not recognise.
  ///
  /// Counted rather than dropped, for the same reason `GameProtocolReader.stats()`
  /// counts unknown frames: a protocol change should show up as a number going up,
  /// not as a feature quietly not working. The names it is counted against are
  /// [_knownEvents].
  ///
  /// Only ordinary server events reach it. Socket.IO's own `connect` and
  /// `disconnect` go out through `emitReserved`, which does not run the `onAny`
  /// listeners, so the lifecycle cannot inflate this.
  int unknownEvents = 0;

  /// The names behind [unknownEvents], for a log line worth reading.
  final Set<String> unknownEventNames = {};

  final _notifications = StreamController<SfuNotification>.broadcast();
  final _statuses = StreamController<SfuStatus>.broadcast();

  /// Server-pushed messages, published immediately rather than coalesced.
  Stream<SfuNotification> get notifications => _notifications.stream;
  Stream<SfuStatus> get statuses => _statuses.stream;

  bool get connected => _connected;
  String get url => _url;

  /// Opens the socket, authenticates, and **waits until it is actually usable**.
  ///
  /// The waiting is the whole point, and its absence was a real bug: `_open()`
  /// ends at `socket.connect()`, which only *starts* the handshake, so a `start()`
  /// that awaited `_open()` alone resolved a full round trip before the socket
  /// could carry anything. The caller then did the natural thing — asked its first
  /// question — and got `not connected`, followed a moment later by the connection
  /// succeeding. Every first call failed and every retry worked, which is exactly
  /// the shape of bug that gets misread as the server being flaky.
  ///
  /// Throws [SfuException] on timeout rather than resolving, because a caller that
  /// cannot tell "connected" from "gave up" will publish into a void.
  /// Transient failures keep retrying underneath; a rejected credential does not,
  /// and surfaces here.
  Future<void> start({Duration timeout = _connectTimeout}) async {
    _stopped = false;
    if (_connected) return;

    // A second caller joins the first attempt rather than starting another.
    // Overwriting `_ready` would strand whoever was already waiting on a
    // completer nothing completes any more — they would sit there until their
    // own timeout while the connection they wanted succeeded around them.
    final inFlight = _ready;
    if (inFlight != null && !inFlight.isCompleted) {
      return inFlight.future.timeout(
        timeout,
        onTimeout: () => throw SfuException('$_url did not answer in '
            '${timeout.inSeconds}s'),
      );
    }

    // Recreated per attempt, and never left completed-with-error without a
    // listener: `start()` awaits it on the same turn it is made.
    final ready = _ready = Completer<void>();
    await _open();
    if (_stopped) return;

    return ready.future.timeout(
      timeout,
      onTimeout: () => throw SfuException('$_url did not answer in '
          '${timeout.inSeconds}s'),
    );
  }

  Future<void> stop() async {
    _stopped = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _settleReady(SfuException('$_url was closed while connecting'));
    _teardown();
  }

  Future<void> dispose() async {
    await stop();
    await _notifications.close();
    await _statuses.close();
  }

  /// Asks a question and waits for the ack that answers it.
  ///
  /// [args] is the `zodData` payload; the envelope is added here unless [method]
  /// is exempt. The reply is the ack's first argument, which for every measured
  /// call is either a map (`consume` → `{id, producerId, …}`) or an empty list
  /// (`consume-resume` → `[]`).
  Future<Map<String, Object?>> sendWithResponse(
    String method, [
    Map<String, Object?> args = const {},
    Duration timeout = _defaultTimeout,
  ]) async {
    final socket = _socket;
    if (socket == null || !_connected) {
      throw SfuException('not connected to $_url');
    }

    // NOT `emitWithAckAsync`, and this is not a style choice.
    //
    // `Socket.onack` dispatches with `Function.apply(ack, args)`, so an ack whose
    // payload is `[]` calls the callback with **zero** arguments — and
    // `emitWithAckAsync`'s internal callback requires one. It throws, the
    // completer is never completed, and the call hangs until it times out.
    //
    // That is not an edge case here. Measured against Gather, six of the twelve
    // client calls answer with an empty array: `consume-request`,
    // `consume-created`, `consume-pause`, `consume-resume`, `consume-set-spatial`
    // and `set-player-conversation-metadata`. Half the protocol would hang.
    //
    // A callback whose parameters are all optional survives every arity the
    // library can produce: none, one value, or one list when the ack carried
    // several.
    final completer = Completer<Map<String, Object?>>();
    final envelope = _envelope(method, args);
    // Traced rather than summarised, because this socket's failure mode is
    // silence: when an ack never arrives the only evidence of *why* is the
    // payload we sent, and by the time the timeout fires it is gone. Logging it
    // at the moment of sending is what turns "producing audio timed out" into a
    // diffable request.
    _log('sfu: -> $method ${jsonEncode(envelope)}');
    try {
      socket.emitWithAck(
        method,
        envelope,
        ack: ([Object? first, Object? second]) {
          if (completer.isCompleted) return;
          final reply = _asMap(first);
          _log('sfu: <- $method ack ${jsonEncode(reply)}');
          // A refusal is an ack too: `[{"error":"no such consumer",
          // "clientShouldRecover":true}]`, captured 2026-09-17. Handing that
          // back as a reply makes the caller fail one step later on a missing
          // `id`, with the server's own reason already thrown away.
          final error = reply['error'];
          if (error is String && error.isNotEmpty) {
            completer.completeError(SfuException('$method refused: $error'));
            return;
          }
          completer.complete(reply);
        },
      );
    } on Object catch (error) {
      throw SfuException('$method failed: $error');
    }

    return completer.future.timeout(
      timeout,
      // Distinguished from a refusal on purpose: Gather's failure mode is silence,
      // so a caller that cannot tell "no" from "nothing" will hang a call forever.
      onTimeout: () =>
          throw SfuException('$method timed out after ${timeout.inSeconds}s'),
    );
  }

  /// Says something without expecting an answer — `consume-allow`, `produce-close`.
  void emit(String method, [Map<String, Object?> args = const {}]) {
    final socket = _socket;
    // Logged even when it goes nowhere, because "we never sent it" and "we sent
    // it into a closed socket" are different bugs that look identical
    // afterwards.
    if (socket == null || !_connected) {
      _log('sfu: -x $method dropped, not connected');
      return;
    }
    final envelope = _envelope(method, args);
    // The fire-and-forget half of the protocol is not the unimportant half:
    // `consume-allow` is what permits anybody to hear us at all, and
    // `produce-pause` is mute. Tracing only `sendWithResponse` left those
    // invisible, and an absent `consume-allow` then read as proof it was never
    // sent when nothing had ever been looked at (2026-09-17).
    _log('sfu: -> $method ${jsonEncode(envelope)}');
    socket.emit(method, envelope);
  }

  /// `{wsSequenceNumber, zodData}`, or the bare payload for an exempt method.
  Object _envelope(String method, Map<String, Object?> args) {
    if (_bareMethods.contains(method)) return args;
    return {'wsSequenceNumber': ++_sequence, 'zodData': args};
  }

  Future<void> _open() async {
    if (_stopped) return;
    _teardown();

    final String token;
    try {
      token = await _auth.idToken();
    } on GatherAuthException catch (error) {
      _setStatus(false, 'Gather sign-in failed: ${error.message}',
          needsPairing: error.permanent);
      // A revoked credential will not fix itself, so stop the caller waiting out
      // the full timeout for an answer that is never coming. A transient one
      // keeps retrying and `start()` waits, which is the right shape for a
      // signal that dropped in a lift.
      if (error.permanent) {
        _settleReady(SfuException('Gather sign-in failed: ${error.message}'));
      } else {
        _scheduleRetry();
      }
      return;
    }
    if (_stopped) return;

    final address = splitSfuAddress(_url);

    final builder = io.OptionBuilder()
        .setPath(address.path)
        // Websocket only. Gather never polls, and allowing the polling fallback
        // would send the credential over a series of HTTP requests instead.
        .setTransports(['websocket'])
        .disableAutoConnect()
        .disableReconnection()
        .setAuth({'spaceId': _spaceId, 'token': token});

    // Only the media nodes carry one. The router's connection in the capture is
    // a bare `/socket.io/?EIO=4&transport=websocket` — no `sessionId` — and
    // sending one there would be inventing traffic Gather does not send.
    if (address.path != _socketIoPath) {
      builder.setQuery({'sessionId': _sessionId ?? _newSessionId()});
    }
    final options = builder.build();

    final io.Socket socket;
    try {
      socket = _connect(address.origin, options);
    } on Object catch (error) {
      _setStatus(false, 'could not build the SFU socket: $error');
      _scheduleRetry();
      return;
    }
    _socket = socket;

    socket.onConnect((_) {
      if (_socket != socket) return;
      _connected = true;
      _backoff = const Duration(seconds: 1);
      _setStatus(true, 'connected');
      _log('sfu: connected to $_url');
      _settleReady();
    });

    socket.onConnectError((Object? error) {
      if (_socket != socket) return;
      // A rejected credential arrives here rather than as a close code.
      _setStatus(false, 'SFU refused the connection: $error');
      _connected = false;
      // A `bad auth / TokenVerificationFailed` refusal means the held ID token is
      // stale to the media plane — after a long suspend the SFU rejects a token
      // that is not yet clock-expired, so [GatherAuth.idToken] would hand the
      // *same* token to every retry and loop forever (#84). Force a fresh mint so
      // the scheduled retry below presents a new credential. Fire-and-forget: the
      // refresh completes before the backoff timer fires, and errors surface on
      // the next `_open` → `idToken`.
      if (_isBadAuth(error)) {
        _log('sfu: $_url refused bad-auth — invalidating token before retry (#84)');
        unawaited(_auth.invalidateIdToken());
      }
      // Tell the caller now instead of leaving them to the timeout. A refusal is
      // an *answer* — the server is up and said no — and ten silent seconds
      // before the same news is ten seconds of a button doing nothing. The
      // background retry continues regardless, because the "no" may be about a
      // token that is about to be refreshed rather than about us.
      _settleReady(SfuException('$_url refused the connection: $error'));
      _scheduleRetry();
    });

    socket.onDisconnect((_) {
      if (_socket != socket) return;
      _connected = false;
      _setStatus(false, 'SFU socket closed');
      _scheduleRetry();
    });

    // Everything the server says unprompted. Registering one catch-all rather
    // than a handler per message means a new server-side event shows up in
    // `unknownEvents` instead of vanishing.
    socket.onAny((String event, Object? data) {
      if (_socket != socket) return;
      if (!_knownEvents.contains(event)) {
        unknownEvents++;
        if (unknownEventNames.add(event)) {
          _log('sfu: $_url said "$event", which this client does not know');
        }
      }
      if (_notifications.isClosed) return;
      _notifications.add(SfuNotification(event, _asMap(data)));
    });

    socket.connect();
    _setStatus(false, 'connecting');
  }

  /// Whether a connect refusal is about a stale credential rather than the
  /// network. The server answers `{message: bad auth, data: {reason:
  /// TokenVerificationFailed}}`; `socket_io_client` hands it here as the error,
  /// whose string form carries both. Keyed on either string because only the
  /// reason is stable across Gather's error shapes — same test as
  /// `LiveCall._isStaleAuth`.
  bool _isBadAuth(Object? error) {
    final text = '$error';
    return text.contains('TokenVerificationFailed') || text.contains('bad auth');
  }

  /// Wakes whoever is inside [start].
  ///
  /// Completing a future with an error that nobody is listening to is reported as
  /// an unhandled exception, so this only ever completes the completer `start()`
  /// is already awaiting, and only once. `stop()` settles it too — otherwise
  /// closing a socket mid-connect leaves the caller waiting for a handshake that
  /// has been abandoned.
  void _settleReady([Object? error]) {
    final ready = _ready;
    if (ready == null || ready.isCompleted) return;
    if (error == null) {
      ready.complete();
    } else {
      ready.completeError(error);
    }
  }

  void _teardown() {
    final socket = _socket;
    _socket = null;
    _connected = false;
    if (socket == null) return;
    try {
      socket
        ..clearListeners()
        ..dispose();
    } on Object {
      /* already gone */
    }
  }

  void _scheduleRetry() {
    if (_stopped || _retryTimer != null) return;
    final wait = _backoff;
    final next = _backoff * 2;
    _backoff = next > _maxBackoff ? _maxBackoff : next;
    _retryTimer = Timer(wait, () {
      _retryTimer = null;
      unawaited(_open());
    });
  }

  void _setStatus(bool healthy, String? detail, {bool needsPairing = false}) {
    if (_statuses.isClosed) return;
    _statuses.add(
      SfuStatus(healthy: healthy, detail: detail, needsPairing: needsPairing),
    );
  }
}

/// Server payloads arrive as `[{…}]` or `{…}` depending on the emitter.
Map<String, Object?> _asMap(Object? data) {
  if (data is Map) return data.cast<String, Object?>();
  if (data is List && data.isNotEmpty && data.first is Map) {
    return (data.first as Map).cast<String, Object?>();
  }
  return const {};
}

final _random = Random();

/// A v4-shaped id, for the SFU URL's `sessionId`.
///
/// The same shape and reasoning as `direct_collector.dart`'s `_txnId`: it only
/// has to be unique per connection, so `Random` avoids a dependency.
String _newSessionId() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}
