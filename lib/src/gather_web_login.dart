/// In-app Gather login that needs no Mac bridge.
///
/// The desktop bridge exists only to read a Firebase refresh token out of the
/// Gather web app's IndexedDB on the computer. This does the same read on the
/// phone: a `WKWebView` (wired in `AppDelegate.swift`) loads Gather's real login
/// page, the user signs in against Gather's own origin — Google, email or SSO, all
/// of it Gather's problem, nothing of ours to register — and the native side reads
/// the `firebase:authUser:…:[DEFAULT]` record the web app persisted in *that
/// webview's* own same-origin IndexedDB, handing back the `refreshToken` and `uid`.
///
/// The result is the exact `GatherCredentials` shape pairing produces, so the whole
/// downstream pipeline (`_attach`, `GatherAuth`, the socket) is untouched. This is
/// the standalone, reviewer-testable path: a demo account logs in on-device with no
/// computer anywhere.
library;

import 'package:flutter/services.dart';
import 'package:gather_client/gather_client.dart';

/// Thrown by nothing — a user dismiss is a null return, not an error — but kept as
/// the seam's documented cancel contract mirrors `GoogleAuthCancelled`.
abstract class GatherWebLogin {
  /// Presents the embedded Gather login and resolves with the harvested session,
  /// or null if the user closes it without finishing.
  Future<GatherCredentials?> signIn();
}

/// The real flow: a method channel onto the `WKWebView` in `AppDelegate.swift`.
/// Nothing here but the channel call and the mapping onto [GatherCredentials] — the
/// native side owns the webview, the login and the IndexedDB read.
class ChannelGatherWebLogin implements GatherWebLogin {
  const ChannelGatherWebLogin();

  static const _channel = MethodChannel('gather/web_login');

  @override
  Future<GatherCredentials?> signIn() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('signIn');
      if (result == null) return null;
      final refreshToken = result['refreshToken'] as String? ?? '';
      if (refreshToken.isEmpty) return null;
      return GatherCredentials(
        refreshToken: refreshToken,
        uid: result['uid'] as String?,
      );
    } on PlatformException catch (e) {
      // A deliberate dismiss is silence, not an error — same contract the OAuth
      // channel uses for `cancelled`.
      if (e.code == 'cancelled') return null;
      rethrow;
    }
  }
}
