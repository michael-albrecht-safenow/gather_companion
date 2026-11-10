/// The on-device list of backends, the active selection, and the per-profile
/// credential. The invariants that matter: a fresh install points nowhere
/// (decision §3), each profile's session is isolated from the others, and removing
/// a backend takes its selection and session with it.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/backend_profiles.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  BackendProfileStore store() => BackendProfileStore(storage: const FlutterSecureStorage());

  BackendProfile office(String host) => BackendProfile.fromConfig(
        BackendConfig.bether(name: 'Office', httpBase: 'https://$host', wsBase: 'wss://$host'),
      );

  test('a fresh install has no backends and points at none', () async {
    expect(await store().profiles(), isEmpty);
    expect(await store().activeId(), isNull);
    expect(await store().active(), isNull);
  });

  test('an added backend comes back, and can be made active', () async {
    final p = office('office.example.com');
    await store().addProfile(p);
    await store().setActive(p.id);

    expect((await store().profiles()).single.name, 'Office');
    expect((await store().active())!.id, p.id);
    expect((await store().active())!.config.gameSocket, 'wss://office.example.com/gather-game-v2');
  });

  test('re-adding the same host updates its row rather than duplicating it', () async {
    await store().addProfile(office('office.example.com'));
    // Same host, so the same id — an update, not a second row.
    final renamed = BackendProfile(
      id: office('office.example.com').id,
      config: BackendConfig.bether(
        name: 'HQ',
        httpBase: 'https://office.example.com',
        wsBase: 'wss://office.example.com',
      ),
    );
    await store().addProfile(renamed);

    final list = await store().profiles();
    expect(list.length, 1);
    expect(list.single.name, 'HQ');
  });

  test('credentials are isolated per profile', () async {
    final a = office('a.example.com');
    final b = office('b.example.com');
    await store().addProfile(a);
    await store().addProfile(b);
    await store().saveCredentials(a.id, const GatherCredentials(refreshToken: 'tok-a'));
    await store().saveCredentials(b.id, const GatherCredentials(refreshToken: 'tok-b'));

    expect((await store().loadCredentials(a.id)).refreshToken, 'tok-a');
    expect((await store().loadCredentials(b.id)).refreshToken, 'tok-b');
  });

  test('removing a backend clears its credential and active selection', () async {
    final p = office('office.example.com');
    await store().addProfile(p);
    await store().setActive(p.id);
    await store().saveCredentials(p.id, const GatherCredentials(refreshToken: 'tok'));

    await store().removeProfile(p.id);

    expect(await store().profiles(), isEmpty);
    expect(await store().activeId(), isNull, reason: 'the active pointer must not dangle');
    expect((await store().loadCredentials(p.id)).isComplete, isFalse);
  });

  test('the built-in Gather profile resolves when selected but is never stored', () async {
    await store().setActive(gatherProfileId);

    expect(await store().profiles(), isEmpty, reason: 'Gather is pickable, not a stored row');
    final active = await store().active();
    expect(active!.id, gatherProfileId);
    expect(active.config.authStrategy, AuthStrategy.firebase);
    expect(active.config.firebaseKey, isNotNull);
  });

  test('an active id pointing at a removed/unknown backend resolves to null', () async {
    await store().setActive('ghost.example.com');
    expect(await store().active(), isNull);
  });
}
