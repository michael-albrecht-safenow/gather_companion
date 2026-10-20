/// A read-only window onto the user's Google Calendar.
///
/// This is the other half of the Plans tab's answer to "Gather has no calendar."
/// [PlannedMeeting] is a plan this phone owns; a [GoogleEvent] is one it only
/// *reads* — the same events Gather's desktop Calendar Panel shows, pulled from the
/// source Gather itself reads rather than from Gather, which carries none on the
/// wire. Connect a Google account here and the Plans tab shows what the desktop
/// shows, without a Gather calendar API that does not exist.
///
/// Deliberately not a native sign-in plugin. `google_sign_in`'s iOS half still
/// ships only a CocoaPods podspec, and adding it drags this SPM-only project back
/// onto pods — the same trap the `flutter_webrtc`/`device_calendar` notes guard
/// against (see [[ios-device-build-signing]] and the pubspec pins). So the whole
/// flow is kept pod-free: the OAuth round trip runs through
/// `ASWebAuthenticationSession` — an iOS *system* framework, no pod — reached by a
/// hand-written [GoogleAuthFlow] method channel, and every HTTP call is plain
/// `dart:io`. The only new dependency is `crypto`, which is pure Dart.
///
/// Read-only by scope: the one OAuth scope requested is `calendar.readonly`, so a
/// leaked token can see meetings and change nothing. Writing back into Google — the
/// bridge that would make a plan made here surface in Gather — stays the deferred
/// device-calendar mirror's job.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One event read off Google Calendar. Read-only: no id the app writes, no reminder
/// it schedules — the card it renders can show a place and a time and nothing it can
/// save, because this phone does not own it. Mapped from the Calendar v3 `events`
/// resource, keeping only the four fields a Plans card shows.
class GoogleEvent {
  const GoogleEvent({
    required this.id,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    this.location,
    this.allDay = false,
  });

  final String id;
  final String title;

  /// Start and end in the phone's local time. An all-day event arrives as a bare
  /// date with no zone; it is parsed at local midnight and flagged [allDay] so the
  /// card shows a day rather than a misleading 00:00–00:00.
  final DateTime startsAt;
  final DateTime endsAt;

  /// The event's free-text location, when set — a room name, an address, a video
  /// link. Shown as-is; Google has no notion of a Gather room to resolve it to.
  final String? location;

  final bool allDay;

  /// Built from one item of a Calendar v3 `events.list` response, or null when the
  /// item is not a thing we can show — cancelled, or missing the start a card needs.
  /// The caller drops a null rather than surfacing a half-event, the same stance
  /// [PlannedMeeting.fromJson]'s store takes.
  static GoogleEvent? fromJson(Map<String, Object?> json) {
    if (json['status'] == 'cancelled') return null;
    final start = _readTime(json['start']);
    final end = _readTime(json['end']);
    if (start == null) return null;
    final title = (json['summary'] as String?)?.trim();
    return GoogleEvent(
      id: json['id'] as String? ?? '',
      title: title == null || title.isEmpty ? '(no title)' : title,
      startsAt: start.at,
      // A missing or unreadable end is treated as a half-hour block so the card has
      // a range to draw; Google almost always sends one.
      endsAt: end?.at ?? start.at.add(const Duration(minutes: 30)),
      location: (json['location'] as String?)?.trim(),
      allDay: start.allDay,
    );
  }

  bool get isPast => endsAt.isBefore(DateTime.now());
}

/// Thrown by [GoogleCalendar.fetchEventsFor] when a colleague's calendar cannot be
/// read at all — offline, access refused, or every fallback failed. Kept distinct from
/// a calendar that read cleanly and is simply empty, so the person sheet can say "could
/// not load" instead of claiming the colleague has nothing planned.
class CalendarUnavailable implements Exception {
  const CalendarUnavailable();
}

/// A parsed `start`/`end` block: the instant plus whether it was a date-only
/// (all-day) value, which the two carry together because the flag is lost once the
/// `DateTime` is built.
class _EventTime {
  const _EventTime(this.at, {required this.allDay});
  final DateTime at;
  final bool allDay;
}

_EventTime? _readTime(Object? node) {
  if (node is! Map) return null;
  final dateTime = node['dateTime'] as String?;
  if (dateTime != null) {
    final parsed = DateTime.tryParse(dateTime);
    return parsed == null ? null : _EventTime(parsed.toLocal(), allDay: false);
  }
  // All-day events carry `date` (YYYY-MM-DD) with no zone. Parsed at local midnight
  // so the card sits on the right day regardless of where the phone is.
  final date = node['date'] as String?;
  if (date != null) {
    final parsed = DateTime.tryParse(date);
    return parsed == null
        ? null
        : _EventTime(DateTime(parsed.year, parsed.month, parsed.day), allDay: true);
  }
  return null;
}

/// How the OAuth consent round trip is actually run. The seam exists for the same
/// reason [CalendarMirror] does: the real implementation is iOS-only native code, so
/// a test — or any non-iOS build — hands in a fake and never opens a browser.
abstract class GoogleAuthFlow {
  /// Opens [url] in a system web session and resolves with the redirect back to
  /// [callbackScheme] once the user signs in, or throws [GoogleAuthCancelled] if they
  /// dismiss it. The redirect URL carries the `code` the caller exchanges for tokens.
  Future<Uri> authorize({required Uri url, required String callbackScheme});
}

/// Thrown when the user dismisses the consent sheet. Distinct from a network or
/// token failure so the caller can stay silent on a deliberate cancel rather than
/// showing an error for a choice.
class GoogleAuthCancelled implements Exception {
  const GoogleAuthCancelled();
}

/// The real flow: a method channel onto `ASWebAuthenticationSession`, wired in
/// `AppDelegate.swift`. Nothing here but the channel call — the system framework on
/// the far side owns the browser, the cookie jar and the redirect capture.
class ChannelGoogleAuthFlow implements GoogleAuthFlow {
  const ChannelGoogleAuthFlow();

  static const _channel = MethodChannel('gather/oauth');

  @override
  Future<Uri> authorize({required Uri url, required String callbackScheme}) async {
    try {
      final redirect = await _channel.invokeMethod<String>('authenticate', {
        'url': url.toString(),
        'callbackScheme': callbackScheme,
      });
      if (redirect == null) throw const GoogleAuthCancelled();
      return Uri.parse(redirect);
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') throw const GoogleAuthCancelled();
      rethrow;
    }
  }
}

/// Static configuration for the Google OAuth client. Supplied by `main.dart` so the
/// client id lives in one place and the service stays a pure, testable object.
///
/// [clientId] is the iOS OAuth client id from the Google Cloud console
/// (`NNN-xxx.apps.googleusercontent.com`). [reversedClientId] is its dotted reverse
/// (`com.googleusercontent.apps.NNN-xxx`), which is both the redirect URI's scheme
/// and the callback scheme `ASWebAuthenticationSession` watches for.
class GoogleOAuthConfig {
  const GoogleOAuthConfig({required this.clientId, required this.reversedClientId});

  final String clientId;
  final String reversedClientId;

  /// Whether a real client id has been filled in. A placeholder build compiles and
  /// runs — the Plans tab simply never offers to connect — so the native OAuth
  /// client can be registered after the code lands.
  bool get isConfigured =>
      clientId.isNotEmpty && !clientId.startsWith('REPLACE_WITH');

  Uri get redirectUri => Uri.parse('$reversedClientId:/oauth2redirect');
}

/// Reads a Google account's upcoming events, and owns the tokens that let it.
///
/// The refresh token is the durable credential — minted once at sign-in, kept in the
/// keychain, and spent for a short-lived access token whenever events are read. So
/// "connected" means "a refresh token is stored": [connect] obtains one, [disconnect]
/// forgets it, and [fetchUpcoming] trades it for access on demand.
class GoogleCalendar {
  GoogleCalendar({
    required this.config,
    GoogleAuthFlow flow = const ChannelGoogleAuthFlow(),
    FlutterSecureStorage? storage,
    // Test seam: production reads the wall clock and opens real sockets; a suite
    // injects both so token-expiry and HTTP can be driven without either.
    DateTime Function()? now,
    HttpClient Function()? httpClient,
  })  :
        // ignore: prefer_initializing_formals
        _flow = flow,
        _storage = storage ?? const FlutterSecureStorage(),
        _now = now ?? DateTime.now,
        _newClient = httpClient ?? HttpClient.new;

  final GoogleOAuthConfig config;
  final GoogleAuthFlow _flow;
  final FlutterSecureStorage _storage;
  final DateTime Function() _now;
  final HttpClient Function() _newClient;

  static const _scope = 'https://www.googleapis.com/auth/calendar.readonly';
  static const _authEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const _tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const _eventsEndpoint =
      'https://www.googleapis.com/calendar/v3/calendars/primary/events';
  static const _calendarListEndpoint =
      'https://www.googleapis.com/calendar/v3/users/me/calendarList';
  static const _calendarsBase =
      'https://www.googleapis.com/calendar/v3/calendars';
  static const _freeBusyEndpoint =
      'https://www.googleapis.com/calendar/v3/freeBusy';
  static const _refreshKey = 'google_calendar_refresh_token';

  /// A cached access token and when it stops being valid, held only in memory —
  /// the keychain keeps the refresh token, this is the short-lived thing spent
  /// against it. Null until the first [fetchUpcoming] of a session.
  String? _accessToken;
  DateTime? _accessExpiry;

  /// Whether an account is connected (a refresh token is stored). Read once at
  /// startup to decide whether the Plans tab shows events or an offer to connect.
  Future<bool> get isConnected async =>
      (await _storage.read(key: _refreshKey)) != null;

  /// Runs the consent flow and stores the refresh token it yields. Returns null on
  /// success or a sentence for the user; a deliberate cancel is success-shaped
  /// (null) so dismissing the sheet shows nothing.
  ///
  /// PKCE throughout: a random verifier is minted, its SHA-256 challenge sent with
  /// the authorization request, and the verifier itself sent with the code exchange —
  /// so the `code` intercepted at the redirect is worthless without this process's
  /// secret, and the public client needs no client secret at all.
  Future<String?> connect() async {
    if (!config.isConfigured) return 'Google Calendar is not set up in this build.';
    final verifier = _randomVerifier();
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

    final authUrl = Uri.parse(_authEndpoint).replace(queryParameters: {
      'client_id': config.clientId,
      'redirect_uri': config.redirectUri.toString(),
      'response_type': 'code',
      'scope': _scope,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      // Forces a refresh token on every consent, not just the first — without it a
      // re-connect after a disconnect gets only an access token and goes silent.
      'access_type': 'offline',
      'prompt': 'consent',
    });

    final Uri redirect;
    try {
      redirect = await _flow.authorize(
        url: authUrl,
        callbackScheme: config.reversedClientId,
      );
    } on GoogleAuthCancelled {
      return null;
    } on Object {
      return 'Could not open Google sign-in.';
    }

    final error = redirect.queryParameters['error'];
    if (error != null) return 'Google declined the sign-in ($error).';
    final code = redirect.queryParameters['code'];
    if (code == null) return 'Google sign-in came back without a code.';

    try {
      final token = await _post(_tokenEndpoint, {
        'client_id': config.clientId,
        'code': code,
        'code_verifier': verifier,
        'grant_type': 'authorization_code',
        'redirect_uri': config.redirectUri.toString(),
      });
      final refresh = token['refresh_token'] as String?;
      if (refresh == null) return 'Google did not return a refresh token.';
      await _storage.write(key: _refreshKey, value: refresh);
      _cacheAccess(token);
      return null;
    } on Object {
      return 'Could not finish connecting to Google.';
    }
  }

  /// Forgets the stored account. The token on Google's side is left valid — revoking
  /// it is the user's to do in their Google account — but this phone keeps nothing.
  Future<void> disconnect() async {
    await _storage.delete(key: _refreshKey);
    _accessToken = null;
    _accessExpiry = null;
  }

  /// The next [window] of events, soonest first, or an empty list when no account is
  /// connected or the read fails. Best-effort by contract, like the mirror: a plan
  /// tab that cannot reach Google shows the local plans and no error, not a blank
  /// screen with a stack trace.
  Future<List<GoogleEvent>> fetchUpcoming({
    Duration window = const Duration(days: 30),
  }) async {
    final token = await _accessTokenOrNull();
    if (token == null) return const [];

    final now = _now();
    final query = {
      'timeMin': now.toUtc().toIso8601String(),
      'timeMax': now.add(window).toUtc().toIso8601String(),
      // Expands recurring events into their instances and sorts them, so the tab
      // shows "the 10am standup on Tuesday" rather than one opaque recurrence rule.
      'singleEvents': 'true',
      'orderBy': 'startTime',
      'maxResults': '250',
    };

    try {
      return await _listAllEvents(_eventsEndpoint, token, query);
    } on Object {
      return const [];
    }
  }

  /// Every page of an `events.list` query, following `nextPageToken` with the original
  /// bounds and accumulating each page's items — a single page caps at 250, and a busy
  /// window runs past that, so reading only the first page silently drops the tail.
  /// Throws on any HTTP failure; the caller decides whether that is an empty list, a
  /// free/busy fallback, or a surfaced error.
  Future<List<GoogleEvent>> _listAllEvents(
    String endpoint,
    String token,
    Map<String, String> query,
  ) async {
    final out = <GoogleEvent>[];
    String? pageToken;
    // A guard against a server that never stops handing back a next-page token.
    for (var page = 0; page < 50; page++) {
      final url = Uri.parse(endpoint).replace(queryParameters: {
        ...query,
        'pageToken': ?pageToken,
      });
      final body = await _get(url, token);
      final items = body['items'];
      if (items is List) {
        for (final item in items) {
          if (item is Map<String, Object?>) {
            final event = GoogleEvent.fromJson(item);
            if (event != null) out.add(event);
          }
        }
      }
      final next = body['nextPageToken'];
      if (next is! String || next.isEmpty) break;
      pageToken = next;
    }
    return out;
  }

  /// A lowercased **display name → calendar id** map of every calendar this account
  /// can see besides its own primary — the colleagues who have shared a calendar with
  /// this Google account, the same set the desktop reads. Empty when disconnected or
  /// the read fails. The caller matches a person's name into it to find their
  /// calendar id; there is no email on the Gather wire to key on instead.
  ///
  /// Keyed on `summaryOverride ?? summary`: the override is the name this account gave
  /// the shared calendar, which is the one most likely to match how the person shows
  /// up in the office, and it falls back to the calendar's own summary (often their
  /// email) when none was set.
  Future<Map<String, String>> fetchCalendarIndex() async {
    final token = await _accessTokenOrNull();
    if (token == null) return const {};

    final out = <String, String>{};
    try {
      String? pageToken;
      // Paged like the event reads: a colleague whose calendar falls on a later page
      // would otherwise be invisible, and the Dial's calendar button never appear.
      for (var page = 0; page < 50; page++) {
        final url = Uri.parse(_calendarListEndpoint).replace(queryParameters: {
          'minAccessRole': 'freeBusyReader',
          'showHidden': 'true',
          'pageToken': ?pageToken,
        });
        final body = await _get(url, token);
        final items = body['items'];
        if (items is List) {
          for (final item in items) {
            if (item is! Map) continue;
            if (item['primary'] == true) continue;
            final id = (item['id'] as String?)?.trim();
            final name =
                ((item['summaryOverride'] as String?) ?? (item['summary'] as String?))
                    ?.trim();
            if (id == null || id.isEmpty || name == null || name.isEmpty) continue;
            out.putIfAbsent(name.toLowerCase(), () => id);
          }
        }
        final next = body['nextPageToken'];
        if (next is! String || next.isEmpty) break;
        pageToken = next;
      }
      return out;
    } on Object {
      return const {};
    }
  }

  /// The next [window] of events on [calendarId], soonest first — one colleague's
  /// calendar, read through the same access this account already holds. Empty on any
  /// failure, the best-effort contract [fetchUpcoming] keeps.
  ///
  /// Falls back to free/busy when the events themselves are not readable: a calendar
  /// shared as free/busy only answers `events.list` with 403, so a refusal is retried
  /// as a [_freeBusy] query, which every sharing level permits. Those come back as
  /// title-less "Busy" blocks — enough to show when the person is occupied and when
  /// they free up, without leaking a detail they did not share.
  /// Throws [CalendarUnavailable] when the calendar cannot be read at all — no token,
  /// or both the events read and the free/busy fallback failed — which the caller must
  /// tell apart from a calendar that read cleanly and is simply empty.
  Future<List<GoogleEvent>> fetchEventsFor(
    String calendarId, {
    Duration window = const Duration(days: 7),
    // How far back to reach. Default now, so the read is strictly upcoming. The
    // meeting-time path asks for its overtime grace here so an invite whose end has
    // just passed still comes back on a refresh instead of being dropped by `timeMin`
    // (callers that only want upcoming events already filter `isPast`).
    Duration lookback = Duration.zero,
  }) async {
    final token = await _accessTokenOrNull();
    if (token == null) throw const CalendarUnavailable();

    final now = _now();
    final timeMin = now.subtract(lookback).toUtc().toIso8601String();
    final timeMax = now.add(window).toUtc().toIso8601String();
    final endpoint = '$_calendarsBase/${Uri.encodeComponent(calendarId)}/events';
    final query = {
      'timeMin': timeMin,
      'timeMax': timeMax,
      'singleEvents': 'true',
      'orderBy': 'startTime',
      'maxResults': '250',
    };

    try {
      return await _listAllEvents(endpoint, token, query);
    } on Object {
      // Most often a 403 from a free/busy-only share. Fall back rather than show a
      // person as having an empty calendar when they are in fact just private; if the
      // fallback fails too, _freeBusy throws CalendarUnavailable and it propagates.
      return _freeBusy(calendarId, token, timeMin: timeMin, timeMax: timeMax);
    }
  }

  /// The busy blocks on [calendarId] as title-less events, for a calendar shared
  /// free/busy only. A well-formed answer with no blocks is an empty list; a failed
  /// request throws [CalendarUnavailable] so the caller does not read "offline" as
  /// "nothing planned".
  Future<List<GoogleEvent>> _freeBusy(
    String calendarId,
    String token, {
    required String timeMin,
    required String timeMax,
  }) async {
    final Map<String, Object?> body;
    try {
      body = await _postJson(_freeBusyEndpoint, token, {
        'timeMin': timeMin,
        'timeMax': timeMax,
        'items': [
          {'id': calendarId},
        ],
      });
    } on Object {
      throw const CalendarUnavailable();
    }
    final calendars = body['calendars'];
    if (calendars is! Map) return const [];
    final entry = calendars[calendarId];
    final busy = entry is Map ? entry['busy'] : null;
    if (busy is! List) return const [];
    final out = <GoogleEvent>[];
    for (var i = 0; i < busy.length; i++) {
      final block = busy[i];
      if (block is! Map) continue;
      final start = DateTime.tryParse(block['start'] as String? ?? '');
      final end = DateTime.tryParse(block['end'] as String? ?? '');
      if (start == null || end == null) continue;
      out.add(GoogleEvent(
        id: 'busy-$i',
        title: 'Busy',
        startsAt: start.toLocal(),
        endsAt: end.toLocal(),
      ));
    }
    return out;
  }

  /// A valid access token, refreshing it if the cached one has expired or there is
  /// none, or null when no account is connected (or the refresh itself fails — a
  /// revoked grant reads as disconnected rather than throwing).
  Future<String?> _accessTokenOrNull() async {
    final cached = _accessToken;
    final expiry = _accessExpiry;
    if (cached != null && expiry != null && _now().isBefore(expiry)) return cached;

    final refresh = await _storage.read(key: _refreshKey);
    if (refresh == null) return null;

    try {
      final token = await _post(_tokenEndpoint, {
        'client_id': config.clientId,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
      });
      _cacheAccess(token);
      return _accessToken;
    } on Object {
      return null;
    }
  }

  /// Caches an access token from a token response, expiring it a minute early so a
  /// read never races the clock and lands with a just-dead token.
  void _cacheAccess(Map<String, Object?> token) {
    final access = token['access_token'] as String?;
    if (access == null) return;
    final seconds = (token['expires_in'] as num?)?.toInt() ?? 3600;
    _accessToken = access;
    _accessExpiry = _now().add(Duration(seconds: seconds - 60));
  }

  Future<Map<String, Object?>> _post(String url, Map<String, String> form) async {
    final client = _newClient();
    try {
      final request = await client.postUrl(Uri.parse(url));
      final encoded = form.entries
          .map((e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
          .join('&');
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      request.write(encoded);
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('token endpoint ${response.statusCode}: $text');
      }
      return jsonDecode(text) as Map<String, Object?>;
    } finally {
      client.close();
    }
  }

  /// A bearer-authorized JSON POST — the free/busy query's shape, distinct from the
  /// form-encoded [_post] the token endpoint wants.
  Future<Map<String, Object?>> _postJson(
    String url,
    String bearer,
    Map<String, Object?> body,
  ) async {
    final client = _newClient();
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.add(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      request.write(jsonEncode(body));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('freebusy endpoint ${response.statusCode}: $text');
      }
      return jsonDecode(text) as Map<String, Object?>;
    } finally {
      client.close();
    }
  }

  Future<Map<String, Object?>> _get(Uri url, String bearer) async {
    final client = _newClient();
    try {
      final request = await client.getUrl(url);
      request.headers.add(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('calendar endpoint ${response.statusCode}: $text');
      }
      return jsonDecode(text) as Map<String, Object?>;
    } finally {
      client.close();
    }
  }

  /// A high-entropy PKCE code verifier: 64 URL-safe characters from a cryptographic
  /// RNG, within the RFC 7636 43–128 range.
  static String _randomVerifier() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < 64; i++) chars.codeUnitAt(rng.nextInt(chars.length)),
    ]);
  }
}
