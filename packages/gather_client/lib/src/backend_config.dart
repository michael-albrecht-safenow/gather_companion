/// Which backend this client talks to.
///
/// The app was born speaking only to Gather, with the hosts baked in as
/// top-level `const`s. To become a *general* client for any Gather-protocol
/// backend — Gather's cloud, a self-hosted `bether` server, or anyone else's —
/// those hosts move here, into one record chosen at runtime.
///
/// [BackendConfig.gather] is the original constants, so the default behaviour is
/// unchanged; [BackendConfig.bether] / [BackendConfig.fromDescriptor] build a
/// profile for a self-hosted server. See
/// `bether-backend/docs/multi-backend-client.md`.
library;

import 'gather_auth.dart' show gatherApiBase, gatherFirebaseKey;
import 'sfu_signalling.dart' show gatherSfuRouter;

/// How a backend hands out sessions.
enum AuthStrategy {
  /// Gather: a Firebase refresh token (from pairing / in-app web login),
  /// refreshed at `securetoken.googleapis.com`.
  firebase,

  /// bether: email one-time-passcode, refreshed at the backend's own endpoint.
  otp,
}

class BackendConfig {
  const BackendConfig({
    required this.name,
    required this.apiBase,
    required this.gameSocket,
    required this.sfuRouter,
    required this.tokenEndpoint,
    required this.authStrategy,
    this.firebaseKey,
    this.otpRequestEndpoint,
    this.otpVerifyEndpoint,
  });

  /// Shown in the backend picker.
  final String name;

  /// REST base, including the `/api/v2` suffix (matches [gatherApiBase]).
  final String apiBase;

  /// The game WebSocket, e.g. `wss://host/gather-game-v2`.
  final String gameSocket;

  /// The SFU router host (M5).
  final String sfuRouter;

  /// The securetoken-shaped refresh endpoint.
  final String tokenEndpoint;

  final AuthStrategy authStrategy;

  /// The `?key=` query the Firebase token endpoint wants; null for non-Firebase.
  final String? firebaseKey;

  /// OTP endpoints (only for [AuthStrategy.otp]).
  final String? otpRequestEndpoint;
  final String? otpVerifyEndpoint;

  /// The original Gather cloud — the default, so nothing changes unless asked.
  static const BackendConfig gather = BackendConfig(
    name: 'Gather',
    apiBase: gatherApiBase,
    gameSocket: 'wss://game-router.v2.gather.town/gather-game-v2',
    sfuRouter: gatherSfuRouter,
    tokenEndpoint: 'https://securetoken.googleapis.com/v1/token',
    authStrategy: AuthStrategy.firebase,
    firebaseKey: gatherFirebaseKey,
  );

  /// A self-hosted bether backend reachable at [httpBase]/[wsBase]
  /// (e.g. `https://office.example.com` and `wss://office.example.com`).
  factory BackendConfig.bether({
    required String name,
    required String httpBase,
    required String wsBase,
    String gamePath = '/gather-game-v2',
  }) =>
      BackendConfig(
        name: name,
        apiBase: '$httpBase/api/v2',
        gameSocket: '$wsBase$gamePath',
        sfuRouter: wsBase,
        tokenEndpoint: '$httpBase/auth/token',
        authStrategy: AuthStrategy.otp,
        otpRequestEndpoint: '$httpBase/auth/otp-request',
        otpVerifyEndpoint: '$httpBase/auth/otp-verify',
      );

  /// Builds a profile from a backend's `/.well-known/gather-backend.json`
  /// descriptor (see `bether-backend/src/descriptor.ts`).
  factory BackendConfig.fromDescriptor(Map<String, Object?> json) {
    final auth = json['auth'];
    final authMap = auth is Map ? auth.cast<String, Object?>() : const <String, Object?>{};
    final strategies = authMap['strategies'];
    final hasOtp = strategies is List && strategies.contains('otp');
    final tokenEndpoint = authMap['tokenEndpoint'] as String? ?? '';
    // The backend root is the token endpoint without its `/auth/token` suffix.
    final root = tokenEndpoint.replaceFirst(RegExp(r'/auth/token/?$'), '');
    final assets = json['assets'];
    final assetMap = assets is Map ? assets.cast<String, Object?>() : const <String, Object?>{};

    return BackendConfig(
      name: json['name'] as String? ?? 'Backend',
      apiBase: json['apiBase'] as String? ?? '',
      gameSocket: json['gameSocket'] as String? ?? '',
      sfuRouter: json['sfuRouter'] as String? ?? (assetMap['spriteHost'] as String? ?? ''),
      tokenEndpoint: tokenEndpoint,
      authStrategy: hasOtp ? AuthStrategy.otp : AuthStrategy.firebase,
      otpRequestEndpoint: hasOtp && root.isNotEmpty ? '$root/auth/otp-request' : null,
      otpVerifyEndpoint: hasOtp && root.isNotEmpty ? '$root/auth/otp-verify' : null,
    );
  }

  /// The refresh URL, with the Firebase `?key=` appended when there is one.
  Uri refreshUri() => firebaseKey != null && firebaseKey!.isNotEmpty
      ? Uri.parse('$tokenEndpoint?key=$firebaseKey')
      : Uri.parse(tokenEndpoint);

  @override
  String toString() => 'BackendConfig($name, $apiBase, $authStrategy)';
}
