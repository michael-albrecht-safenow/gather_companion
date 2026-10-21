/// Holding a Gather credential on the phone.
///
/// The bridge adopts the desktop client's Firebase session by reading a refresh
/// token out of its IndexedDB (`bridge/lib/gather-auth.js`). The phone cannot do
/// that — it has no access to the Mac's disk — so it is *handed* the refresh token
/// once, at pairing, and from then on mints its own ID tokens exactly as the bridge
/// does.
///
/// ## What can go wrong, and which half is ours
///
/// ID tokens last about an hour. Refreshing them is routine and invisible, and
/// [GatherAuth.idToken] does it a couple of minutes before expiry so a request
/// never races the deadline. That is the "mint a new one if possible" case, and it
/// is the overwhelmingly common one.
///
/// A *refresh* token does not expire on a clock. It dies when the account's
/// password changes, when the user signs out everywhere, or when Google revokes it
/// — and nothing the app can do will bring it back. Google answers those with a
/// specific set of error codes, which [GatherAuthException.permanent] separates
/// from "your wifi is down". Permanent means: tell the person to pair again, so the
/// bridge can adopt a fresh session from the desktop client and hand it over.
/// Anything else means: retry later, and say nothing.
///
/// ## Trust
///
/// This is the user's own Gather identity, in full — not a LAN-scoped token like
/// the bridge's. It must be stored in the platform keychain rather than in
/// preferences, and it is never sent anywhere except Google's token endpoint and
/// Gather's own hosts.
library;

import 'dart:convert';
import 'dart:io';

/// Firebase web API key, from the prod bundle. Public by design for web apps.
const gatherFirebaseKey = 'AIzaSyDPwTbXLMPbIkg6UKr49VrHWwkrOdRh__E';

/// REST base. The `/api/v2` prefix is not part of the host constant in Gather's
/// own bundle: `/api/v2/users/me` answers 403, while `/users/me` answers 404.
const gatherApiBase = 'https://api.v2.gather.town/api/v2';

/// What Gather's REST API speaks. Measured 2026-08-13: the activity feed answers
/// `content-type: application/x.gather.msgpack`, so REST bodies decode with the
/// same [msgpackDecode] the game socket uses.
const gatherMsgpackContentType = 'application/x.gather.msgpack';

const _tokenEndpoint = 'https://securetoken.googleapis.com/v1/token';

/// Refresh this long before expiry, so a request never races the deadline.
const _refreshMargin = Duration(minutes: 2);

const _timeout = Duration(seconds: 15);

/// Google's names for "this refresh token is never going to work again".
///
/// Everything outside this set — a 500, a timeout, a dropped connection — is
/// transient and must not send the user back to the pairing screen.
const _permanentFailures = {
  'TOKEN_EXPIRED',
  'USER_DISABLED',
  'USER_NOT_FOUND',
  'INVALID_REFRESH_TOKEN',
  'INVALID_GRANT_TYPE',
  'MISSING_REFRESH_TOKEN',
  'CREDENTIAL_MISMATCH',
};

class GatherAuthException implements Exception {
  const GatherAuthException(this.message, {required this.permanent});

  final String message;

  /// True when re-pairing is the only fix. False when it is worth trying again.
  final bool permanent;

  @override
  String toString() => 'GatherAuthException($message, permanent: $permanent)';
}

/// What we hold on behalf of the user. The refresh token is the credential; the
/// rest is cache.
class GatherCredentials {
  const GatherCredentials({required this.refreshToken, this.idToken, this.uid});

  final String refreshToken;
  final String? idToken;
  final String? uid;

  bool get isComplete => refreshToken.trim().isNotEmpty;

  GatherCredentials copyWith({String? refreshToken, String? idToken, String? uid}) =>
      GatherCredentials(
        refreshToken: refreshToken ?? this.refreshToken,
        idToken: idToken ?? this.idToken,
        uid: uid ?? this.uid,
      );

  Map<String, Object?> toJson() => {
        'refreshToken': refreshToken,
        'idToken': idToken,
        'uid': uid,
      };

  static GatherCredentials fromJson(Map<String, Object?> json) => GatherCredentials(
        refreshToken: json['refreshToken'] as String? ?? '',
        idToken: json['idToken'] as String?,
        uid: json['uid'] as String?,
      );

  static const empty = GatherCredentials(refreshToken: '');
}

/// One space this account has been in.
class GatherSpace {
  const GatherSpace({required this.id, this.name, this.lastVisited, this.spaceUserId});

  final String id;
  final String? name;
  final DateTime? lastVisited;

  /// Our own SpaceUser id for this space — the identity the protocol reader
  /// otherwise has to derive from a `Connection` row.
  final String? spaceUserId;
}

/// The seam that keeps tests off the network.
///
/// Production is [IoGatherHttp]. A suite that reached Google would be slow, flaky,
/// and would burn the developer's real session.
abstract class GatherHttp {
  Future<({int status, Map<String, Object?> body})> postForm(
    Uri uri,
    Map<String, String> fields,
  );

  Future<({int status, Object? body})> getJson(Uri uri, String bearer);

  /// Like [getJson], but hands back the bytes.
  ///
  /// Gather's REST API answers `application/x.gather.msgpack` — the same encoding
  /// as the game socket, not JSON. [getJson] runs the body through `utf8.decode`
  /// and `jsonDecode`, which mangles it beyond recovery, so a msgpack route needs
  /// its own method rather than a reinterpretation of that one.
  Future<({int status, List<int> body})> getBytes(Uri uri, String bearer);

  /// POSTs JSON and hands back the response as bytes.
  ///
  /// The asymmetry is Gather's, measured 2026-08-13 against
  /// `/chat/activity-feed/toggle-read-status`: the request is
  /// `application/json`, and the response comes back as msgpack. So this takes a
  /// map and returns bytes rather than being symmetric in either direction.
  Future<({int status, List<int> body})> postJson(
    Uri uri,
    String bearer,
    Object? body,
  );
}

class IoGatherHttp implements GatherHttp {
  const IoGatherHttp();

  @override
  Future<({int status, Map<String, Object?> body})> postForm(
    Uri uri,
    Map<String, String> fields,
  ) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(fields.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&'));
      final response = await request.close().timeout(_timeout);
      final text = await response.transform(utf8.decoder).join();
      Map<String, Object?> body;
      try {
        body = (jsonDecode(text) as Map).cast<String, Object?>();
      } catch (_) {
        body = const {};
      }
      return (status: response.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<({int status, Object? body})> getJson(Uri uri, String bearer) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      final response = await request.close().timeout(_timeout);
      final text = await response.transform(utf8.decoder).join();
      Object? body;
      try {
        body = jsonDecode(text);
      } catch (_) {
        body = null;
      }
      return (status: response.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<({int status, List<int> body})> getBytes(Uri uri, String bearer) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      request.headers.set(HttpHeaders.acceptHeader, gatherMsgpackContentType);
      final response = await request.close().timeout(_timeout);
      return (status: response.statusCode, body: await _drain(response));
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<({int status, List<int> body})> postJson(
    Uri uri,
    String bearer,
    Object? body,
  ) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, gatherMsgpackContentType);
      request.write(jsonEncode(body));
      final response = await request.close().timeout(_timeout);
      return (status: response.statusCode, body: await _drain(response));
    } finally {
      client.close(force: true);
    }
  }

  /// Concatenates the response chunks. `expand` rather than `BytesBuilder` keeps
  /// this readable; these bodies are tens of kilobytes, not megabytes.
  static Future<List<int>> _drain(HttpClientResponse response) async {
    final chunks = await response.toList();
    return chunks.expand((chunk) => chunk).toList(growable: false);
  }
}

class GatherAuth {
  GatherAuth({
    required GatherCredentials credentials,
    GatherHttp? http,
    Future<void> Function(GatherCredentials)? onRotated,
    void Function(String)? log,
    DateTime Function()? now,
        // Assigned the long way round because a named parameter cannot be a private
        // initializing formal.
        // ignore: prefer_initializing_formals
  })  : _credentials = credentials,
        _http = http ?? const IoGatherHttp(),
        // ignore: prefer_initializing_formals
        _onRotated = onRotated,
        _log = log ?? _noop,
        _now = now ?? DateTime.now;

  static void _noop(String _) {}

  GatherCredentials _credentials;
  final GatherHttp _http;
  final Future<void> Function(GatherCredentials)? _onRotated;
  final void Function(String) _log;
  final DateTime Function() _now;

  /// In flight refresh, so several callers waking at once make one request.
  Future<String>? _refreshing;

  GatherCredentials get credentials => _credentials;

  /// The Firebase uid, which the ID token carries — no API call needed.
  String? get uid => _credentials.uid ?? uidFromIdToken(_credentials.idToken);

  /// A currently-valid ID token, refreshing when it is close to expiry.
  ///
  /// For a long-lived connection this is the path that actually matters: a
  /// collector that only worked for the first hour would look fine in testing and
  /// fail overnight.
  Future<String> idToken() {
    final held = _credentials.idToken;
    if (held != null && held.isNotEmpty) {
      final expiry = expiryOf(held);
      if (expiry != null && expiry.difference(_now()) > _refreshMargin) {
        return Future.value(held);
      }
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  /// Drop the cached ID token and mint a fresh one, bypassing the expiry margin.
  ///
  /// [idToken] hands back the held token until it is within [_refreshMargin] of
  /// expiry, which is the right call for the common case. But Gather's SFU can
  /// refuse a token that is *not* clock-expired — after a long iOS suspend the
  /// media plane rejects the held token with `TokenVerificationFailed`, and
  /// re-presenting the same cached one on every reconnect loops forever (#84).
  /// When no refresh is in flight this clears the cache so the next [idToken]
  /// re-mints; when one is already running it simply joins it rather than
  /// clearing, because that refresh is already minting a fresh token — wiping
  /// the cache a second time would throw away the token it just assigned (a
  /// racing invalidation landing in the window where [_refresh] has set
  /// `_credentials` but is still awaiting `_onRotated` persistence), leaving an
  /// empty cache that forces a needless extra refresh on the next read. Errors
  /// surface on the next [idToken] (which re-attempts, or throws permanent →
  /// re-pair), not here, so a fire-and-forget caller on a reconnect path cannot
  /// crash on a dropped packet.
  Future<void> invalidateIdToken() {
    final refresh = _refreshing ??= () {
      _credentials = _credentials.copyWith(idToken: '');
      return _refresh().whenComplete(() => _refreshing = null);
    }();
    return refresh.then((_) {}, onError: (_) {});
  }

  Future<String> _refresh() async {
    if (!_credentials.isComplete) {
      throw const GatherAuthException('no Gather session — pair again', permanent: true);
    }

    final ({int status, Map<String, Object?> body}) response;
    try {
      response = await _http.postForm(
        Uri.parse('$_tokenEndpoint?key=$gatherFirebaseKey'),
        {'grant_type': 'refresh_token', 'refresh_token': _credentials.refreshToken},
      );
    } on Object catch (error) {
      // Never permanent: a phone loses its network constantly, and sending someone
      // to the pairing screen over a dropped packet would be its own bug.
      throw GatherAuthException('could not reach Google: $error', permanent: false);
    }

    if (response.status != 200) {
      final reason = _reasonOf(response.body);
      throw GatherAuthException(
        reason ?? 'the token endpoint answered ${response.status}',
        // A 4xx naming one of Google's revocation codes is final. A 5xx, or a 4xx
        // we do not recognise, is not — better to retry than to make someone
        // re-pair over a wording change at Google.
        permanent: reason != null && _permanentFailures.contains(reason),
      );
    }

    final idToken = response.body['id_token'];
    if (idToken is! String || idToken.isEmpty) {
      throw const GatherAuthException(
        'the token endpoint returned no id token',
        permanent: false,
      );
    }

    // Google may hand back a rotated refresh token; keep whichever is current.
    final rotated = response.body['refresh_token'];
    final next = GatherCredentials(
      refreshToken: rotated is String && rotated.isNotEmpty
          ? rotated
          : _credentials.refreshToken,
      idToken: idToken,
      uid: response.body['user_id'] as String? ?? _credentials.uid ?? uidFromIdToken(idToken),
    );
    _credentials = next;
    _log('gather auth: refreshed the id token');
    await _onRotated?.call(next);
    return idToken;
  }

  /// One authenticated GET against Gather's REST API.
  Future<Object?> apiGet(String path) async {
    final token = await idToken();
    final response = await _http.getJson(Uri.parse('$gatherApiBase$path'), token);
    if (response.status == 401 || response.status == 403) {
      throw GatherAuthException(
        'Gather refused the token (${response.status})',
        permanent: false,
      );
    }
    if (response.status != 200) {
      throw GatherAuthException(
        'GET $path returned ${response.status}',
        permanent: false,
      );
    }
    return response.body;
  }

  /// The spaces this account has been in recently, most recent first.
  ///
  /// Answers a map keyed by space id, not a list. This is how the phone learns
  /// which space to watch without being able to read the desktop client's
  /// IndexedDB, and re-reading it is how it follows the user between spaces.
  Future<List<GatherSpace>> recentSpaces() async {
    final body = await apiGet('/users/me/recent-spaces');
    if (body is! Map) return const [];

    final out = <GatherSpace>[];
    for (final row in body.values) {
      if (row is! Map) continue;
      final id = row['id'];
      if (id is! String) continue;
      out.add(GatherSpace(
        id: id,
        name: row['name'] as String?,
        lastVisited: DateTime.tryParse(row['lastVisited'] as String? ?? ''),
        spaceUserId: row['spaceUserId'] as String?,
      ));
    }
    // `lastVisited` is an ISO string; rows without one sort last.
    out.sort((a, b) {
      final at = a.lastVisited, bt = b.lastVisited;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return out;
  }
}

/// Firebase puts the uid in the ID token.
String? uidFromIdToken(String? idToken) {
  final claims = _claimsOf(idToken);
  final userId = claims?['user_id'] ?? claims?['sub'];
  return userId is String ? userId : null;
}

/// When an ID token stops being accepted, or null if it cannot be read.
DateTime? expiryOf(String? idToken) {
  final exp = _claimsOf(idToken)?['exp'];
  if (exp is! num) return null;
  return DateTime.fromMillisecondsSinceEpoch((exp * 1000).toInt(), isUtc: true);
}

Map<String, Object?>? _claimsOf(String? idToken) {
  if (idToken == null) return null;
  final parts = idToken.split('.');
  if (parts.length < 2) return null;
  try {
    // base64url without padding, which is what JWTs use and what `base64Url`
    // refuses to decode unless it is padded back up.
    final payload = parts[1];
    final padded = payload.padRight((payload.length + 3) & ~3, '=');
    return (jsonDecode(utf8.decode(base64Url.decode(padded))) as Map).cast<String, Object?>();
  } catch (_) {
    return null;
  }
}

String? _reasonOf(Map<String, Object?> body) {
  final error = body['error'];
  if (error is Map) {
    final message = error['message'];
    // Google sends `TOKEN_EXPIRED` bare, and sometimes with a trailing explanation
    // after a colon.
    if (message is String) return message.split(':').first.trim();
  }
  return null;
}
