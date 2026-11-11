/// H1–H4: discovery, the two sign-in strategies, refresh, and the REST shapes
/// the client parses — against a live bether stack, through the client's own
/// [BackendConfig], [OtpLogin] and [GatherAuth].
///
/// These are the contract tests between the repos: a route moved, a field
/// renamed or an error code reworded on either side fails here in seconds.
@Tags(['e2e'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'harness.dart';
import 'suite.dart';

void main() {
  group('bether E2E: discovery, auth, REST', skip: e2eSkip(), () {
    late E2eEnv env;
    late BackendConfig config;

    setUpAll(() async {
      env = e2eEnv!;
      config = await discover(env.base);
    });

    test(
      'H1 descriptor → BackendConfig.fromDescriptor points at the running stack',
      () async {
        final descriptor = await fetchDescriptor(env.base);
        expect(
          descriptor['protocolVersion'],
          'gather-v2',
          reason: 'the client refuses a backend that speaks anything else',
        );
        final strategies = (descriptor['auth'] as Map)['strategies'] as List;
        expect(strategies, containsAll(['otp', 'password']));

        final http = env.base.toString();
        final ws = env.wsBase!;
        expect(config.apiBase, '$http/api/v2');
        expect(config.gameSocket, '$ws/gather-game-v2');
        expect(config.tokenEndpoint, '$http/auth/token');
        expect(
          config.refreshUri(),
          Uri.parse('$http/auth/token'),
          reason: 'no Firebase ?key= on a self-hosted backend',
        );
        expect(config.authStrategy, AuthStrategy.otp);
        expect(config.otpRequestEndpoint, '$http/auth/otp-request');
        expect(config.otpVerifyEndpoint, '$http/auth/otp-verify');

        // The hand-typed profile (backend picker "enter a URL") must agree with the
        // scanned one on everything the client actually dials.
        final typed = BackendConfig.bether(
          name: 'typed',
          httpBase: http,
          wsBase: ws,
        );
        expect(
          [
            typed.apiBase,
            typed.gameSocket,
            typed.tokenEndpoint,
            typed.otpRequestEndpoint,
            typed.otpVerifyEndpoint,
          ],
          [
            config.apiBase,
            config.gameSocket,
            config.tokenEndpoint,
            config.otpRequestEndpoint,
            config.otpVerifyEndpoint,
          ],
        );

        // The advertised URLs are live, not merely well-formed: the REST base has the
        // authenticated routes under it (401, not 404), and the game socket upgrades.
        final unauthenticated = await rawJson(
          'GET',
          Uri.parse('${config.apiBase}/users/me'),
        );
        expect(
          unauthenticated.status,
          401,
          reason: 'apiBase must be where the data API is mounted',
        );
        final socket = await WebSocket.connect(config.gameSocket);
        await socket.close();
      },
    );

    test('H2 OtpLogin with the mailed code → GatherAuth refresh rotates', () async {
      final email = uniqueEmail('h2');
      final login = OtpLogin(config: config);

      await login.requestCode(email);
      final code = await mailboxCode(env, email);

      // A mistyped code is the user's to retry, never "sign in again".
      final wrong =
          code.substring(0, code.length - 1) + (code.endsWith('0') ? '1' : '0');
      await expectLater(
        login.verify(email, wrong),
        throwsA(
          isA<GatherAuthException>()
              .having((e) => e.permanent, 'permanent', isFalse)
              .having((e) => e.message, 'message', 'INVALID_CODE'),
        ),
      );

      final credentials = await login.verify(email, code);
      expect(credentials.isComplete, isTrue);
      expect(credentials.uid, isNotEmpty);
      expect(
        uidFromIdToken(credentials.idToken),
        credentials.uid,
        reason: 'the socket handshake takes authUserId from the token',
      );
      expect(
        expiryOf(credentials.idToken)!.isAfter(DateTime.now().toUtc()),
        isTrue,
      );

      // Codes are single use.
      await expectLater(
        login.verify(email, code),
        throwsA(isA<GatherAuthException>()),
      );

      final rotated = <GatherCredentials>[];
      final auth = GatherAuth(
        credentials: credentials,
        config: config,
        onRotated: (next) async => rotated.add(next),
      );
      if ((env.jwtAccessTtl ?? 3600) > 300) {
        // Comfortably inside its TTL, the held token is used as is — no request.
        expect(await auth.idToken(), credentials.idToken);
        expect(rotated, isEmpty);
      }

      await auth.invalidateIdToken();
      expect(rotated, isNotEmpty);
      final next = auth.credentials;
      expect(
        next.refreshToken,
        isNot(credentials.refreshToken),
        reason: 'bether rotates on refresh',
      );
      expect(next.uid, credentials.uid);
      final me = await auth.apiGet('/users/me') as Map;
      expect((me['userAccount'] as Map)['id'], credentials.uid);

      // The pre-rotation token is spent. The client must read that as permanent —
      // the one answer that sends a person back to sign-in instead of retrying
      // forever — which only works while the backend's code is in the client's set.
      final replay = GatherAuth(
        credentials: GatherCredentials(refreshToken: credentials.refreshToken),
        config: config,
      );
      await expectLater(
        replay.idToken(),
        throwsA(
          isA<GatherAuthException>()
              .having((e) => e.message, 'message', 'INVALID_REFRESH_TOKEN')
              .having((e) => e.permanent, 'permanent', isTrue),
        ),
      );
    });

    // The client has no password-login class (only OtpLogin), so the two calls go
    // through the harness's own HTTP; the session they hand back is then driven by
    // the production GatherAuth like any other.
    test(
      'H3 password register + login (client lacks password login — harness HTTP)',
      () async {
        final email = uniqueEmail('h3');
        final password = 'pw-${randomTag(8)}';
        final credentials = await passwordCredentials(
          config,
          email,
          password,
          register: true,
        );
        expect(credentials.isComplete, isTrue);
        expect(uidFromIdToken(credentials.idToken), credentials.uid);

        final root = authRootOf(config);
        final again = await rawJson(
          'POST',
          Uri.parse('$root/auth/register'),
          json: {'email': email, 'password': password},
        );
        expect(again.status, 409);
        expect((again.body as Map)['error'], {'message': 'EMAIL_IN_USE'});

        final wrong = await rawJson(
          'POST',
          Uri.parse('$root/auth/password'),
          json: {'email': email, 'password': '$password-nope'},
        );
        expect(wrong.status, 400);
        expect((wrong.body as Map)['error'], {
          'message': 'INVALID_CREDENTIALS',
        });

        // A password session refreshes through the same securetoken-shaped path.
        final auth = GatherAuth(credentials: credentials, config: config);
        await auth.invalidateIdToken();
        expect(auth.credentials.refreshToken, isNot(credentials.refreshToken));
        expect(auth.uid, credentials.uid);

        // One identity, two strategies: OTP for the same address is the same account.
        final otp = await otpCredentials(env, config, email);
        expect(otp.uid, credentials.uid);

        // And the seeded pair, for the flows that need a known person.
        final alice = env.seeded('alice');
        if (alice != null) {
          final seeded = await passwordCredentials(
            config,
            alice.email,
            alice.password,
          );
          expect(seeded.uid, alice.userId);
        }
      },
    );

    test(
      'H4 users/me, recent-spaces, spaces/:id parse into the client\'s models',
      () async {
        final user = await signUp(env, config, 'h4');
        final nameA = 'H4 A ${randomTag()}';
        final nameB = 'H4 B ${randomTag()}';
        final spaceA = await user.rest.createSpace(nameA);
        final spaceB = await user.rest.createSpace(nameB);

        // users/me: the identity bridge. `firebaseAuthId` is what Gather's reader
        // joins UserAccount rows on; on bether it must be the JWT subject.
        final me = await user.rest.get('/users/me') as Map;
        final account = me['userAccount'] as Map;
        expect(account['id'], user.userId);
        expect(account['email'], user.email);
        expect(account['firebaseAuthId'], user.userId);

        // recent-spaces → GatherSpace through the production parser and sort.
        final suA = await user.rest.join(spaceA);
        final suB = await user.rest.join(spaceB);
        var spaces = await user.auth.recentSpaces();
        expect(spaces.map((s) => s.id), containsAll([spaceA, spaceB]));
        expect(spaces.first.id, spaceB, reason: 'most recently visited first');
        final a = spaces.firstWhere((s) => s.id == spaceA);
        expect(a.name, nameA);
        expect(a.spaceUserId, suA, reason: 'enterSpace addresses this id');
        expect(
          a.lastVisited,
          isNotNull,
          reason: 'lastVisited must be an ISO string DateTime.tryParse reads',
        );
        expect(spaces.firstWhere((s) => s.id == spaceB).spaceUserId, suB);

        await user.rest.join(spaceA);
        spaces = await user.auth.recentSpaces();
        expect(spaces.first.id, spaceA, reason: 'a fresh visit re-sorts');

        // spaces/:id — the client has no model for it yet; the fields it would read.
        final space = await user.rest.get('/spaces/$spaceA') as Map;
        expect(space['id'], spaceA);
        expect(space['name'], nameA);
        await expectLater(
          user.rest.get('/spaces/00000000-0000-0000-0000-000000000000'),
          throwsA(isA<GatherAuthException>()),
        );
      },
    );
  });
}
