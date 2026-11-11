/// On-device end-to-end: add a bether backend, log in with a one-time code, reach
/// the office — against a *real* running backend, not a fake.
///
/// Drives the actual screens and the real [AppState] (real descriptor fetch, real
/// `/auth/otp-request` + `/auth/otp-verify`, real token, real game socket). The one
/// thing it reaches around is the human who would read the email: the E2E backend's
/// `/__e2e/mailbox/:email` hook hands back the code that was "sent", which the test
/// types in exactly as a person would.
///
/// Expects the E2E stack reachable at 127.0.0.1:13000 (the Docker overlay or the
/// native runner). Run with:
///   flutter test integration_test/otp_login_e2e_test.dart -d SIMULATOR_ID
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/notifications.dart';
import 'package:gather_companion/ui/backend_picker_screen.dart';
import 'package:gather_companion/ui/home_shell.dart';
import 'package:gather_companion/ui/otp_login_screen.dart';
import 'package:gather_companion/ui/pair_screen.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:integration_test/integration_test.dart';

const _backendHost = '127.0.0.1:13000';
const _backendUrl = 'http://$_backendHost';

/// A notifier that does nothing, so the login's permission request never pops an OS
/// dialog mid-test. Everything else about the flow stays real.
class _SilentNotifier extends Notifier {
  @override
  Future<void> init() async {}
  @override
  Future<void> requestPermission() async {}
}

/// The same routing main.dart uses, minimal enough to drive in a test.
class _Router extends StatelessWidget {
  const _Router(this.state);
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: buildGatherTheme(),
      debugShowCheckedModeBanner: false,
      home: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          if (!state.isLoaded) return const SizedBox.expand();
          if (state.isConfigured) return HomeShell(state: state, onUnpair: state.unpair);
          if (!state.hasActiveBackend) return BackendPickerScreen(state: state);
          return switch (state.backend.authStrategy) {
            AuthStrategy.otp => OtpLoginScreen(state: state),
            AuthStrategy.firebase => PairScreen(state: state),
          };
        },
      ),
    );
  }
}

/// The last OTP the backend "emailed", via its E2E mailbox hook.
Future<String> fetchMailboxCode(String email) async {
  final client = HttpClient();
  try {
    final req = await client
        .getUrl(Uri.parse('$_backendUrl/__e2e/mailbox/${Uri.encodeComponent(email)}'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw StateError('mailbox returned ${res.statusCode}: $body');
    }
    return (jsonDecode(body) as Map)['code'] as String;
  } finally {
    client.close(force: true);
  }
}

Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('add a bether backend, log in by OTP, reach the office', (tester) async {
    // A fresh email each run, so the code read from the mailbox is unambiguously
    // this run's. (Seconds-since-epoch is enough resolution for a manual E2E.)
    final email = 'device-e2e-${DateTime.now().millisecondsSinceEpoch}@example.com';

    final state = AppState(notifier: _SilentNotifier());
    await state.boot();
    await tester.pumpWidget(_Router(state));
    await tester.pumpAndSettle();

    // --- picker: add the backend ----------------------------------------------
    expect(find.text('Choose a backend'), findsOneWidget);
    // Added through the method rather than the field so a descriptor-fetch failure
    // surfaces its reason here (the picker UI is already covered by its own test and
    // the render screenshot). The full http URL: a bare host would default to https.
    final added = await state.addBackendFromUrl(_backendUrl);
    debugPrint('E2E add error: ${added.error}');
    expect(added.error, isNull, reason: 'descriptor fetch from $_backendUrl failed');
    await state.activateBackend(added.profile!);

    // The backend is active → the OTP login screen.
    await pumpUntil(tester, () => state.hasActiveBackend);
    await tester.pumpAndSettle();
    expect(find.textContaining('Sign in to'), findsOneWidget);
    expect(state.backend.authStrategy, AuthStrategy.otp);

    // --- OTP: email → request a code ------------------------------------------
    await tester.enterText(find.byType(TextField).first, email);
    await tester.tap(find.text('Send me a code'));
    // Advances to the code step once the request returns.
    await pumpUntil(tester, () => find.text('Sign in').evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    // --- read the "emailed" code and enter it ---------------------------------
    final code = await fetchMailboxCode(email);
    await tester.enterText(find.byType(TextField).first, code);
    await tester.tap(find.text('Sign in'));

    // --- logged in: the session is complete and the office is up --------------
    await pumpUntil(tester, () => state.isConfigured, timeout: const Duration(seconds: 30));
    expect(state.isConfigured, isTrue, reason: 'a real securetoken session came back');
    expect(state.activeProfile!.config.authStrategy, AuthStrategy.otp);
  });
}
