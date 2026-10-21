/// [GatherAuth] token handling — the cache, and the forced refresh #84 added.
///
/// The network is faked with [FakeGatherHttp] so these run offline and never
/// touch the developer's real Google session.
library;

import 'dart:async';

import 'package:gather_client/gather_client.dart';
import 'package:test/test.dart';

import 'fake_gather.dart' show FakeGatherHttp, fakeJwt;

void main() {
  group('idToken caching', () {
    test('hands back a held, unexpired token without a network call', () async {
      final http = FakeGatherHttp();
      final auth = GatherAuth(
        credentials: GatherCredentials(refreshToken: 'r', idToken: fakeJwt()),
        http: http,
      );

      expect(await auth.idToken(), isNotEmpty);
      expect(http.refreshes, 0, reason: 'a valid cached token needs no refresh');
    });

    test('refreshes a token that is close to expiry', () async {
      final http = FakeGatherHttp(idToken: fakeJwt(uid: 'fresh'));
      final auth = GatherAuth(
        // Already past the two-minute margin.
        credentials: GatherCredentials(
          refreshToken: 'r',
          idToken: fakeJwt(validFor: const Duration(seconds: 30)),
        ),
        http: http,
      );

      await auth.idToken();
      expect(http.refreshes, 1);
    });
  });

  group('invalidateIdToken (#84)', () {
    test('forces the next idToken to mint fresh even when the held one is valid',
        () async {
      final fresh = fakeJwt(uid: 'fresh');
      final http = FakeGatherHttp(idToken: fresh);
      final held = fakeJwt(uid: 'stale');
      final auth = GatherAuth(
        credentials: GatherCredentials(refreshToken: 'r', idToken: held),
        http: http,
      );

      // The held token is nowhere near expiry, so idToken() would normally reuse
      // it — the SFU's "bad auth" verdict is the only thing that knows it is dead.
      expect(await auth.idToken(), held);
      expect(http.refreshes, 0);

      await auth.invalidateIdToken();
      expect(http.refreshes, 1, reason: 'the cache was dropped and re-minted');
      expect(await auth.idToken(), fresh,
          reason: 'the next read gets the freshly minted token, not the dead one');
    });

    test('coalesces concurrent callers into a single refresh', () async {
      final http = FakeGatherHttp(idToken: fakeJwt(uid: 'fresh'));
      final auth = GatherAuth(
        credentials: GatherCredentials(refreshToken: 'r', idToken: fakeJwt()),
        http: http,
      );

      await Future.wait([auth.invalidateIdToken(), auth.idToken()]);
      expect(http.refreshes, 1, reason: 'the in-flight refresh is shared');
    });

    test('a second invalidation during onRotated keeps the fresh token',
        () async {
      // Regression: production's onRotated awaits credential persistence, so
      // there is a real window where _refresh has already assigned the fresh
      // token but has not yet returned. A second invalidation landing in that
      // window must join the in-flight refresh — not wipe the just-minted token
      // and leave an empty cache that forces a needless extra refresh.
      final fresh = fakeJwt(uid: 'fresh');
      final http = FakeGatherHttp(idToken: fresh);
      final gate = Completer<void>();
      final auth = GatherAuth(
        credentials: GatherCredentials(refreshToken: 'r', idToken: fakeJwt()),
        http: http,
        onRotated: (_) => gate.future, // pause inside the rotation callback
      );

      final first = auth.invalidateIdToken();
      // While the first refresh is parked in onRotated, invalidate again.
      final second = auth.invalidateIdToken();
      gate.complete();
      await Future.wait([first, second]);

      expect(http.refreshes, 1, reason: 'both invalidations share one refresh');
      expect(await auth.idToken(), fresh,
          reason: 'the fresh token survived the racing invalidation');
      expect(http.refreshes, 1,
          reason: 'the next read reuses the cache; no extra refresh');
    });

    test('swallows a permanent failure rather than throwing to the caller',
        () async {
      // The invalidation runs fire-and-forget off a reconnect path; it must not
      // crash there. A dead refresh token surfaces on the next idToken() instead.
      final http = FakeGatherHttp(status: 400, errorCode: 'TOKEN_EXPIRED');
      final auth = GatherAuth(
        credentials: GatherCredentials(refreshToken: 'r', idToken: fakeJwt()),
        http: http,
      );

      await expectLater(auth.invalidateIdToken(), completes);
      await expectLater(
        auth.idToken(),
        throwsA(isA<GatherAuthException>()
            .having((e) => e.permanent, 'permanent', isTrue)),
      );
    });
  });
}
