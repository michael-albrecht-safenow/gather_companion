/// A [SfuSignalling] with no socket behind it.
///
/// `packages/gather_client` already tests the real one against a real
/// `HttpServer` doing a real upgrade — that is where the framing risk lives and
/// that is where it is pinned. This is a different job: it stands in for the
/// transport so [SfuSession]'s *conversation* can be tested, including the two
/// things a real socket cannot be made to do on cue — refuse to place somebody,
/// and drop and come back.
library;

import 'dart:async';

import 'package:gather_client/gather_client.dart';

/// One scripted socket.
class FakeSignalling implements SfuSignalling {
  FakeSignalling(this.url);

  @override
  final String url;

  /// Every `sendWithResponse`, in order.
  final List<({String method, Map<String, Object?> args})> asked = [];

  /// Every fire-and-forget `emit`, in order.
  final List<({String method, Map<String, Object?> args})> said = [];

  /// Both of the above, in the order they actually went out — which is what
  /// matters for anything about *sequence*, like allowing somebody before
  /// asking for them.
  final List<({String method, Map<String, Object?> args})> sent = [];

  /// Scripted answers, by method name.
  final Map<String, Map<String, Object?> Function(Map<String, Object?> args)>
      _answers = {};

  /// Methods to fail rather than answer.
  final Set<String> failing = {};

  /// Methods to fail with a *specific* server message, rather than the generic
  /// `refused`. The stale-token heal keys on the reason the server sends
  /// (`TokenVerificationFailed`), so a test for it has to be able to put that
  /// exact string on the wire.
  final Map<String, String> failingWith = {};

  bool started = false;
  bool disposed = false;
  bool _connected = false;

  final _notifications = StreamController<SfuNotification>.broadcast();
  final _statuses = StreamController<SfuStatus>.broadcast();

  @override
  Stream<SfuNotification> get notifications => _notifications.stream;

  @override
  Stream<SfuStatus> get statuses => _statuses.stream;

  @override
  bool get connected => _connected;

  @override
  int unknownEvents = 0;

  @override
  final Set<String> unknownEventNames = {};

  /// Answer [method] with whatever [reply] returns.
  void answer(
    String method,
    Map<String, Object?> Function(Map<String, Object?> args) reply,
  ) =>
      _answers[method] = reply;

  /// Say something unprompted, as the server does.
  void push(String name, Map<String, Object?> data) {
    if (!_notifications.isClosed) _notifications.add(SfuNotification(name, data));
  }

  /// The socket dropped. Nothing sent while down goes anywhere, exactly as the
  /// real one silently discards an `emit` with no connection under it.
  void drop() {
    _connected = false;
    if (!_statuses.isClosed) {
      _statuses.add(const SfuStatus(healthy: false, detail: 'closed'));
    }
  }

  /// And came back — a *new* session on the far side, holding nothing.
  void comeBack() {
    _connected = true;
    if (!_statuses.isClosed) {
      _statuses.add(const SfuStatus(healthy: true, detail: 'connected'));
    }
  }

  /// The calls made since the last time this was called. Handy for asserting
  /// what a recovery did without counting past the setup.
  List<({String method, Map<String, Object?> args})> drain() {
    final out = List.of(sent);
    sent.clear();
    asked.clear();
    said.clear();
    return out;
  }

  bool has(String method) => sent.any((frame) => frame.method == method);

  Map<String, Object?>? argsFor(String method) {
    for (final frame in sent) {
      if (frame.method == method) return frame.args;
    }
    return null;
  }

  @override
  Future<void> start({Duration timeout = const Duration(seconds: 10)}) async {
    started = true;
    _connected = true;
    if (!_statuses.isClosed) {
      _statuses.add(const SfuStatus(healthy: true, detail: 'connected'));
    }
  }

  @override
  Future<void> stop() async => _connected = false;

  @override
  Future<void> dispose() async {
    disposed = true;
    _connected = false;
    await _notifications.close();
    await _statuses.close();
  }

  @override
  Future<Map<String, Object?>> sendWithResponse(
    String method, [
    Map<String, Object?> args = const {},
    Duration timeout = const Duration(seconds: 15),
  ]) async {
    if (!_connected) throw SfuException('not connected to $url');
    final frame = (method: method, args: args);
    asked.add(frame);
    sent.add(frame);
    if (failing.contains(method)) throw SfuException('$method refused');
    final message = failingWith[method];
    if (message != null) throw SfuException(message);
    return _answers[method]?.call(args) ?? const {};
  }

  @override
  void emit(String method, [Map<String, Object?> args = const {}]) {
    if (!_connected) return;
    final frame = (method: method, args: args);
    said.add(frame);
    sent.add(frame);
  }
}
