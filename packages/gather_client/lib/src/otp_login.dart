/// Email one-time-passcode login against a bether-style backend.
///
/// A third producer of [GatherCredentials], alongside QR pairing and the in-app
/// Gather web login — same output shape, so the whole downstream pipeline
/// (`GatherAuth`, the socket) is untouched. The backend's `/auth/otp-verify`
/// answers the same securetoken-shaped body Firebase does, so the refresh token
/// it hands back refreshes through the ordinary [GatherAuth] path.
///
/// Pure Dart over the [GatherHttp] seam, so it is testable offline.
library;

import 'backend_config.dart';
import 'gather_auth.dart';

class OtpLogin {
  OtpLogin({required BackendConfig config, GatherHttp? http})
      // A named parameter cannot be a private initializing formal.
      // ignore: prefer_initializing_formals
      : _config = config,
        _http = http ?? const IoGatherHttp();

  final BackendConfig _config;
  final GatherHttp _http;

  /// Asks the backend to email a code to [email].
  Future<void> requestCode(String email) async {
    final endpoint = _config.otpRequestEndpoint;
    if (endpoint == null) {
      throw const GatherAuthException('this backend has no OTP login', permanent: true);
    }
    final res = await _http.postForm(Uri.parse(endpoint), {'email': email});
    if (res.status != 200) {
      throw GatherAuthException('could not request a code (${res.status})', permanent: false);
    }
  }

  /// Verifies [code] and returns the session, ready to store and refresh.
  Future<GatherCredentials> verify(String email, String code) async {
    final endpoint = _config.otpVerifyEndpoint;
    if (endpoint == null) {
      throw const GatherAuthException('this backend has no OTP login', permanent: true);
    }
    final res = await _http.postForm(Uri.parse(endpoint), {'email': email, 'code': code});
    if (res.status != 200) {
      // A wrong/expired code is a user error (retry), not a dead backend.
      throw GatherAuthException(_messageOf(res.body) ?? 'that code did not work', permanent: false);
    }
    final refreshToken = res.body['refresh_token'] as String? ?? '';
    if (refreshToken.isEmpty) {
      throw const GatherAuthException('the backend returned no refresh token', permanent: false);
    }
    return GatherCredentials(
      refreshToken: refreshToken,
      idToken: res.body['id_token'] as String?,
      uid: res.body['user_id'] as String?,
    );
  }

  /// The error code our backend returns, e.g. INVALID_CODE / TOO_MANY_ATTEMPTS.
  static String? _messageOf(Map<String, Object?> body) {
    final error = body['error'];
    if (error is Map) {
      final message = error['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    if (error is String && error.isNotEmpty) return error;
    return null;
  }
}
