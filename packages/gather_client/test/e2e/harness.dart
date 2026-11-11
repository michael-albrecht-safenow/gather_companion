/// The thin layer between the E2E suite (and `bin/e2e_bot.dart`) and a running
/// bether stack.
///
/// Everything a scenario asserts on goes through the client's own production
/// code — [BackendConfig.fromDescriptor], [OtpLogin], [GatherAuth],
/// [DirectCollector], [IoGatherHttp]. What lives here is only what that code
/// genuinely does not have:
///
/// - **The test hooks** (`/__e2e/mailbox`, `/__e2e/pushes`). They are the test's
///   eyes — a person reading their mail, a phone receiving a push — and no client
///   will ever call them.
/// - **Password login.** The descriptor advertises `password` and the backend
///   serves it, but the client has no password-login class yet (only [OtpLogin]).
///   [passwordSignIn] speaks `/auth/register` + `/auth/password` itself so H3 can
///   pin the wire shape now; when the app grows its own, H3 should switch to it.
/// - **REST writes.** [GatherAuth] only knows `GET`. [BetherRest] adds the POSTs a
///   scenario needs (create/join a space, meetings, push registration) on top of
///   the production [IoGatherHttp.postJson] and a token from [GatherAuth.idToken],
///   so the bearer still comes from the real refresh path.
///
/// Pure `dart:io`, no `package:test`: the bot imports this too.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:gather_client/gather_client.dart';

/// Why every E2E test is skipped on a plain `dart test`.
const e2eSkipReason =
    'no bether E2E stack: run `scripts/e2e.sh up && scripts/e2e.sh seed` in '
    'bether-backend, then `set -a; . <bether-backend>/e2e/.env.generated; set +a`';

/// What `scripts/e2e.sh` wrote to `e2e/.env.generated`.
class E2eEnv {
  E2eEnv._(this._vars)
    : base = Uri.parse(
        _vars['BETHER_E2E_URL']!.replaceFirst(RegExp(r'/+$'), ''),
      );

  /// The suite's view of the stack, or null when no stack is configured.
  static E2eEnv? load([Map<String, String>? environment]) {
    final vars = environment ?? Platform.environment;
    final url = vars['BETHER_E2E_URL'];
    if (url == null || url.isEmpty) return null;
    return E2eEnv._(vars);
  }

  final Map<String, String> _vars;

  /// The backend root: the descriptor and the `/__e2e/*` hooks live here.
  final Uri base;

  String? get wsBase => _vars['BETHER_E2E_WS'];
  String get runId => _vars['BETHER_E2E_RUN_ID'] ?? 'adhoc';
  String get mode => _vars['BETHER_E2E_MODE'] ?? '?';

  /// The access-token TTL the stack was started with (`E2E_JWT_ACCESS_TTL`).
  int? get jwtAccessTtl =>
      int.tryParse(_vars['BETHER_E2E_JWT_ACCESS_TTL'] ?? '');

  /// A shell command that bounces the game gateway (H10). Deliberately *not* in
  /// `.env.generated`: a restart disconnects every socket on the stack, so it is
  /// opted into per run rather than fired into a parallel suite by default.
  String? get restartGatewayCommand {
    final cmd = _vars['BETHER_E2E_RESTART_CMD'];
    return cmd == null || cmd.trim().isEmpty ? null : cmd;
  }

  /// Seeded accounts, for the flows that need a known, pre-existing person.
  SeededUser? seeded(String name) {
    final p = 'BETHER_E2E_${name.toUpperCase()}';
    final email = _vars['${p}_EMAIL'];
    final password = _vars['${p}_PASSWORD'];
    if (email == null || password == null) return null;
    return SeededUser(
      email: email,
      password: password,
      userId: _vars['${p}_USER_ID'],
      spaceUserId: _vars['${p}_SPACE_USER_ID'],
    );
  }

  String? get seededSpaceId => _vars['BETHER_E2E_SPACE_ID'];

  Uri hook(String path, [Map<String, String>? query]) =>
      base.replace(path: '${base.path}$path', queryParameters: query);
}

class SeededUser {
  const SeededUser({
    required this.email,
    required this.password,
    this.userId,
    this.spaceUserId,
  });

  final String email;
  final String password;
  final String? userId;
  final String? spaceUserId;
}

final _random = Random.secure();

/// A short random tag, so two runs (or two tests) never share an account.
String randomTag([int bytes = 4]) => List.generate(
  bytes,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// `e2e-<random>-<tag>@e2e.bether.test` — unique per call, readable in logs.
String uniqueEmail(String tag) =>
    'e2e-${randomTag()}-${tag.toLowerCase()}@e2e.bether.test';

/// Polls [probe] until it yields a non-null value or [timeout] passes.
///
/// The suite's only way of waiting: never a fixed sleep, always a condition with
/// a deadline, so a fast stack finishes fast and a broken one fails with a reason.
Future<T> until<T extends Object>(
  FutureOr<T?> Function() probe, {
  required String reason,
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 50),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final value = await probe();
    if (value != null) return value;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'timed out after ${timeout.inMilliseconds}ms waiting for $reason',
      );
    }
    await Future<void>.delayed(interval);
  }
}

// ---- plain HTTP for the hooks and the descriptor --------------------------------

const _httpTimeout = Duration(seconds: 10);

/// One JSON request with no client semantics — for the hooks, the descriptor, and
/// the password endpoints the client does not implement.
Future<({int status, Object? body})> rawJson(
  String method,
  Uri uri, {
  Object? json,
}) async {
  final client = HttpClient()..connectionTimeout = _httpTimeout;
  try {
    final request = await client.openUrl(method, uri);
    if (json != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(json));
    }
    final response = await request.close().timeout(_httpTimeout);
    final text = await response.transform(utf8.decoder).join();
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      body = text;
    }
    return (status: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

/// `GET /.well-known/gather-backend.json`, as the backend picker fetches it.
Future<Map<String, Object?>> fetchDescriptor(Uri base) async {
  final res = await rawJson(
    'GET',
    base.replace(path: '${base.path}/.well-known/gather-backend.json'),
  );
  if (res.status != 200 || res.body is! Map) {
    throw StateError('descriptor: HTTP ${res.status} ${res.body}');
  }
  return (res.body as Map).cast<String, Object?>();
}

/// The profile the app would build from scanning this backend's URL.
Future<BackendConfig> discover(Uri base) async =>
    BackendConfig.fromDescriptor(await fetchDescriptor(base));

/// The backend root, derived from the token endpoint exactly as
/// [BackendConfig.fromDescriptor] derives the OTP endpoints.
String authRootOf(BackendConfig config) =>
    config.tokenEndpoint.replaceFirst(RegExp(r'/auth/token/?$'), '');

// ---- the test hooks ---------------------------------------------------------------

/// The last code mailed to [email], read the way a person reads their inbox.
///
/// [previous] is the code that was there before a new request, if any: the mailbox
/// keeps the last code per address, so a re-login waits for a *different* one.
Future<String> mailboxCode(
  E2eEnv env,
  String email, {
  String? previous,
  Duration timeout = const Duration(seconds: 10),
}) => until(
  () async {
    final code = await peekMailbox(env, email);
    return code != null && code != previous ? code : null;
  },
  reason: 'an OTP code for $email in /__e2e/mailbox',
  timeout: timeout,
);

Future<String?> peekMailbox(E2eEnv env, String email) async {
  final res = await rawJson(
    'GET',
    env.hook('/__e2e/mailbox/${Uri.encodeComponent(email)}'),
  );
  if (res.status == 404) return null;
  if (res.status != 200)
    throw StateError('mailbox: HTTP ${res.status} ${res.body}');
  final code = (res.body as Map)['code'];
  return code is String ? code : null;
}

/// What the in-memory FCM sink captured for one device token.
Future<List<Map<String, Object?>>> pushesFor(
  E2eEnv env,
  String fcmToken,
) async {
  final res = await rawJson(
    'GET',
    env.hook('/__e2e/pushes', {'token': fcmToken}),
  );
  if (res.status != 200 || res.body is! Map) {
    throw StateError('pushes: HTTP ${res.status} ${res.body}');
  }
  final list = (res.body as Map)['pushes'];
  return [
    if (list is List)
      for (final p in list)
        if (p is Map) p.cast<String, Object?>(),
  ];
}

/// Waits for a push of [kind] (`wave`, `meeting invite`, …) to [fcmToken].
///
/// Tests never clear the sink — `DELETE /__e2e/pushes` is global and the suite
/// runs files in parallel — so isolation is a unique device token per test.
Future<Map<String, Object?>> awaitPush(
  E2eEnv env,
  String fcmToken,
  String kind, {
  Duration timeout = const Duration(seconds: 10),
}) => until(
  () async {
    for (final push in await pushesFor(env, fcmToken)) {
      final data = push['data'];
      if (data is Map && data['kind'] == kind) return push;
    }
    return null;
  },
  reason: 'a "$kind" push for $fcmToken in /__e2e/pushes',
  timeout: timeout,
);

// ---- signing in ---------------------------------------------------------------------

/// The production OTP flow: request, read the mail, verify. Returns the session
/// the app would store.
Future<GatherCredentials> otpCredentials(
  E2eEnv env,
  BackendConfig config,
  String email,
) async {
  final login = OtpLogin(config: config);
  final previous = await peekMailbox(env, email);
  await login.requestCode(email);
  final code = await mailboxCode(env, email, previous: previous);
  return login.verify(email, code);
}

/// Password sign-in, which the client cannot do yet — see the library comment.
///
/// [register] creates the account first (`POST /auth/register`, 201) and then logs
/// in through `POST /auth/password` anyway, so both routes are exercised. Both
/// answer the securetoken-shaped body [OtpLogin.verify] parses.
Future<GatherCredentials> passwordCredentials(
  BackendConfig config,
  String email,
  String password, {
  bool register = false,
}) async {
  final root = authRootOf(config);
  if (register) {
    final res = await rawJson(
      'POST',
      Uri.parse('$root/auth/register'),
      json: {'email': email, 'password': password},
    );
    if (res.status != 201)
      throw StateError('register $email: HTTP ${res.status} ${res.body}');
  }
  final res = await rawJson(
    'POST',
    Uri.parse('$root/auth/password'),
    json: {'email': email, 'password': password},
  );
  if (res.status != 200 || res.body is! Map) {
    throw StateError('password login $email: HTTP ${res.status} ${res.body}');
  }
  final body = (res.body as Map).cast<String, Object?>();
  return GatherCredentials(
    refreshToken: body['refresh_token'] as String? ?? '',
    idToken: body['id_token'] as String?,
    uid: body['user_id'] as String?,
  );
}

/// One signed-in person: their session and a REST handle on it.
class E2eUser {
  E2eUser({
    required this.email,
    required GatherCredentials credentials,
    required this.config,
    void Function(String)? log,
  }) : _credentials = credentials,
       _log = log;

  final String email;
  final BackendConfig config;
  final GatherCredentials _credentials;
  final void Function(String)? _log;

  /// The session, exactly as the app holds one — refreshes at the advertised
  /// token endpoint and counts each rotation.
  late final GatherAuth auth = GatherAuth(
    credentials: _credentials,
    config: config,
    log: _log,
    onRotated: (_) async => rotations++,
  );

  /// How many times [auth] has rotated the refresh token.
  int rotations = 0;

  late final BetherRest rest = BetherRest(auth, config);

  /// Our user id — the JWT subject, and the socket's `authUserId`.
  String get userId => auth.uid!;

  /// A collector exactly as the app builds one, pointed at the advertised socket.
  DirectCollector collector({String? spaceId, void Function(String)? log}) =>
      DirectCollector(
        auth: auth,
        spaceId: spaceId,
        socketUrl: config.gameSocket,
        log: log,
      );
}

/// A brand-new account, signed up through the production OTP flow.
Future<E2eUser> signUp(
  E2eEnv env,
  BackendConfig config,
  String tag, {
  void Function(String)? log,
}) async {
  final email = uniqueEmail(tag);
  return E2eUser(
    email: email,
    credentials: await otpCredentials(env, config, email),
    config: config,
    log: log,
  );
}

// ---- REST ---------------------------------------------------------------------------

/// The REST calls a scenario needs, authenticated by [GatherAuth].
///
/// Reads go through [GatherAuth.apiGet] — the client's own path. Writes go through
/// [IoGatherHttp.postJson], which answers bytes because Gather's REST answers
/// msgpack; bether answers JSON there, so the bytes are decoded as UTF-8 JSON.
class BetherRest {
  BetherRest(this._auth, this._config);

  final GatherAuth _auth;
  final BackendConfig _config;
  final _http = const IoGatherHttp();

  Future<Object?> get(String path) => _auth.apiGet(path);

  Future<({int status, Object? body})> post(String path, Object? body) async {
    final res = await _http.postJson(
      Uri.parse('${_config.apiBase}$path'),
      await _auth.idToken(),
      body,
    );
    Object? decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.body));
    } on FormatException {
      decoded = utf8.decode(res.body, allowMalformed: true);
    }
    return (status: res.status, body: decoded);
  }

  Future<Map<String, Object?>> _expect(
    String path,
    Object? body,
    int status,
  ) async {
    final res = await post(path, body);
    if (res.status != status || res.body is! Map) {
      throw StateError(
        'POST $path: HTTP ${res.status} (want $status) ${res.body}',
      );
    }
    return (res.body as Map).cast<String, Object?>();
  }

  /// `POST /spaces` — the caller owns it and is already a member. Returns its id.
  Future<String> createSpace(String name) async =>
      (await _expect('/spaces', {'name': name}, 201))['id']! as String;

  /// `POST /spaces/:id/join` — returns our `spaceUserId` there.
  Future<String> join(String spaceId, {String? name}) async =>
      (await _expect('/spaces/$spaceId/join', {
            'name': ?name,
          }, 200))['spaceUserId']!
          as String;

  /// `POST /spaces/:id/meetings` — returns the meeting id.
  Future<String> createMeeting(String spaceId) async =>
      (await _expect(
            '/spaces/$spaceId/meetings',
            <String, Object?>{},
            201,
          ))['id']!
          as String;

  /// `POST /meetings/:id/invite`.
  Future<Map<String, Object?>> invite(String meetingId, String spaceUserId) =>
      _expect('/meetings/$meetingId/invite', {'spaceUserId': spaceUserId}, 201);

  /// `POST {apiBase}/push/register` — where a device registers against bether.
  ///
  /// Under `apiBase`, which is where the backend mounts it. The app's own
  /// registration (`lib/src/push.dart`) still posts to the bridge-era root path;
  /// that is a known client bug tracked separately, so this does not imitate it.
  Future<void> registerPush(String fcmToken, {String platform = 'ios'}) async {
    final body = await _expect('/push/register', {
      'fcmToken': fcmToken,
      'platform': platform,
      'installId': 'e2e-${randomTag()}',
    }, 200);
    if (body['ok'] != true) throw StateError('push/register: $body');
  }
}

// ---- the game socket ------------------------------------------------------------------

/// Polls a collector's live reader until its roster satisfies [test].
///
/// Polled rather than read off [DirectCollector.rosters] because that stream is
/// broadcast and unbuffered: a roster that landed before the listen would be
/// missed, and the wait would hang on a condition that is already true.
Future<Roster> rosterWhere(
  DirectCollector collector,
  bool Function(Roster roster) test, {
  required String reason,
  Duration timeout = const Duration(seconds: 10),
}) => until(
  () {
    final roster = collector.reader.roster();
    return test(roster) ? roster : null;
  },
  reason: reason,
  timeout: timeout,
);

/// The row for [spaceUserId], if the roster has one.
RosterRow? rowOf(Roster roster, String? spaceUserId) {
  if (spaceUserId == null) return null;
  for (final row in roster.rows) {
    if (row.id == spaceUserId) return row;
  }
  return null;
}

/// Waits until [collector] holds state, knows who it is, and sees itself placed.
Future<Roster> connected(
  DirectCollector collector, {
  Duration timeout = const Duration(seconds: 10),
}) => rosterWhere(
  collector,
  (r) => r.selfId != null && rowOf(r, r.selfId)?.x != null && collector.healthy,
  reason: 'the collector to hold state and see itself',
  timeout: timeout,
);

/// Waits until [observer] sees [spaceUserId] — present, and optionally at ([x],[y]).
Future<RosterRow> sees(
  DirectCollector observer,
  String spaceUserId, {
  num? x,
  num? y,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final roster = await rosterWhere(
    observer,
    (r) {
      final row = rowOf(r, spaceUserId);
      if (row == null || row.connected == false) return false;
      if (x != null && row.x != x) return false;
      if (y != null && row.y != y) return false;
      return true;
    },
    reason: 'to see $spaceUserId${x != null ? ' at ($x, $y)' : ''}',
    timeout: timeout,
  );
  return rowOf(roster, spaceUserId)!;
}
