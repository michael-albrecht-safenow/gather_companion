/// `ext.gc.status.*` and `ext.gc.ui.*` through the registry, against a real
/// [AppState] booted on the harness's [FakeCollector]: each write reaches the
/// collector through the AppState method the UI calls, each refusal is the
/// app's own no (no socket, a declined frame, a hand outside a meeting, a party
/// with nowhere to stand), bad args are `invalidParams`, and every outward
/// action is held by the gate on a live boot outside the test space.
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/calendar_store.dart';
import 'package:gather_companion/src/credentials.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/install.dart';
import 'package:gather_companion/src/media/media_log.dart';
import 'package:gather_companion/src/notifications.dart';
import 'package:gather_companion/src/settings.dart';
import 'package:gather_events/gather_events.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drive_test_support.dart';

class _SilentNotifier extends Notifier {
  @override
  Future<void> init() async {}
}

class _Credentials extends GatherCredentialStore {
  @override
  Future<GatherCredentials> load() async => const GatherCredentials(refreshToken: 'r', idToken: 'i', uid: 'uid-1');
  @override
  Future<String?> loadSpaceId() async => 'space-drive-test';
  @override
  Future<void> save(GatherCredentials credentials) async {}
  @override
  Future<void> saveSpaceId(String? spaceId) async {}
  @override
  Future<void> clear() async {}
}

class _Bridge extends BridgeSettingsStore {
  @override
  Future<BridgeSettings> load() async => const BridgeSettings(host: '', port: 7799, token: 't');
  @override
  Future<String?> loadName() async => 'Desk';
  @override
  Future<void> save(BridgeSettings settings) async {}
  @override
  Future<void> saveName(String name) async {}
  @override
  Future<void> clear() async {}
}

class _EmptyCalendarStore extends CalendarStore {
  @override
  Future<List<PlannedMeeting>> load() async => const [];
}

class _SilentFeed extends ActivityFeed {
  _SilentFeed(GatherAuth auth) : super(auth: auth);
  @override
  Future<ActivityFeedPage> fetch(String spaceId) async => ActivityFeedPage.empty;
}

/// Records what reached the wire, and can decline every write.
class _Recording extends FakeCollector {
  _Recording({this.decline = false, this.faceless = false}) : super(participants: 2);

  final bool decline;
  final bool faceless;
  final customs = <({String text, String? emoji, DateTime? clearAt})>[];
  final emotes = <String>[];
  final hands = <bool>[];
  int clears = 0;

  static const _no = (ok: false, detail: 'socket closed');

  @override
  String? get selfId => faceless ? null : super.selfId;

  @override
  ({bool ok, String? detail}) setAvailability(String availability) {
    if (decline) return _no;
    return super.setAvailability(availability);
  }

  @override
  ({bool ok, String? detail}) setCustomStatus({required String text, String? emoji, DateTime? clearAt}) {
    if (decline) return _no;
    customs.add((text: text, emoji: emoji, clearAt: clearAt));
    return (ok: true, detail: null);
  }

  @override
  ({bool ok, String? detail}) clearCustomStatus() {
    if (decline) return _no;
    clears++;
    return (ok: true, detail: null);
  }

  @override
  ({bool ok, String? detail}) broadcastEmote(String emote, {int count = 1}) {
    if (decline) return _no;
    emotes.add(emote);
    return (ok: true, detail: null);
  }

  @override
  ({bool ok, String? detail}) setHandRaised(bool raised) {
    hands.add(raised);
    return super.setHandRaised(raised);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    mediaLogDebugSink = null;
    debugResetDriveLog();
  });

  Future<AppState> booted(_Recording collector) async {
    final app = AppState(
      notifier: _SilentNotifier(),
      credentials: _Credentials(),
      bridge: _Bridge(),
      calendarStore: _EmptyCalendarStore(),
      buildCollector: (auth, spaceId) => collector,
      buildActivityFeed: _SilentFeed.new,
      connectivityNow: () async => const [ConnectivityResult.wifi],
      connectivityChanges: const Stream<List<ConnectivityResult>>.empty(),
    );
    addTearDown(app.dispose);
    await app.boot();
    await pumpEventQueue();
    return app;
  }

  DebugDrive install(AppState app, {String boot = 'harness', String testSpaceId = ''}) => installDebugDrive(
        enabled: true,
        app: app,
        boot: boot,
        register: RecordingRegistrar().call,
        testSpaceId: testSpaceId,
      )!;

  Future<Map<String, Object?>> call(DebugDrive drive, String method, [String args = '{}']) async =>
      resultOf(await drive.invoke('ext.gc.$method', args));

  Map<String, Object?> dataOf(Map<String, Object?> body) => (body['data']! as Map).cast<String, Object?>();

  Future<void> expectInvalid(DebugDrive drive, String method, String args, String mentions) async {
    final e = errorOf(await drive.invoke('ext.gc.$method', args));
    expect(e.code, -32602, reason: '$method $args');
    expect('${e.detail}', contains(mentions), reason: '$method $args');
  }

  group('status', () {
    test('state reads connection, availability, status, hand and boot', () async {
      final unbooted = dataOf(await call(install(AppState(), boot: 'live'), 'status.state'));
      expect(unbooted['boot'], 'live');
      expect(unbooted['connected'], isFalse);
      expect(unbooted['availability'], isNull);
      expect(unbooted['availabilityDetail'], contains('no roster'));
      expect(unbooted['customStatus'], isNull);
      expect(unbooted['handRaised'], isFalse);

      final app = await booted(_Recording());
      final body = dataOf(await call(install(app), 'status.state'));
      expect(body['connected'], isTrue);
      expect(body['boot'], 'harness');
    });

    test('setAvailability goes through AppState to the collector, any case, and says pending', () async {
      final collector = _Recording();
      final drive = install(await booted(collector));
      final body = await call(drive, 'status.setAvailability', '{"availability":"busy"}');
      expect(body['ok'], isTrue);
      expect(collector.availabilitiesSet, ['Busy']);
      final data = dataOf(body);
      expect(data['asked'], 'Busy');
      // The fake sends no roster patch back, so the roster still says otherwise.
      expect(data['pending'], isTrue);
    });

    test('setCustom sends text, emoji and an expiry; clearCustom clears', () async {
      final collector = _Recording();
      final app = await booted(collector);
      final drive = install(app);
      final body =
          await call(drive, 'status.setCustom', '{"text":"  heads down ","emoji":"🎧","clearAfterMinutes":30}');
      expect(body['ok'], isTrue);
      expect(collector.customs.single.text, 'heads down');
      expect(collector.customs.single.emoji, '🎧');
      expect(collector.customs.single.clearAt, isNotNull);
      expect((dataOf(body)['asked']! as Map)['text'], 'heads down');

      await call(drive, 'status.setCustom', '{"text":"lunch"}');
      expect(collector.customs.last.clearAt, isNull, reason: 'no clearAfterMinutes means no expiry');

      expect((await call(drive, 'status.clearCustom'))['ok'], isTrue);
      expect(collector.clears, 1);
    });

    test('emote sends a picker emote, matching without the variation selector', () async {
      final collector = _Recording();
      final app = await booted(collector);
      final drive = install(app);
      final body = await call(drive, 'status.emote', '{"emote":"👍"}');
      expect(body['ok'], isTrue);
      expect(collector.emotes, ['👍️']);
      expect(dataOf(body)['sent'], '👍️');
    });

    test('hand raises inside a meeting and lowers anywhere', () async {
      final collector = _Recording();
      final app = await booted(collector)..debugHuddle = ['Bob'];
      final drive = install(app);
      final up = await call(drive, 'status.hand', '{"raised":true}');
      expect(up['ok'], isTrue);
      expect(dataOf(up)['handRaised'], isTrue);
      expect(app.myHandRaised, isTrue);

      app.debugHuddle = null;
      // Lowering is allowed out of a meeting (the app drops it itself anyway).
      final down = await call(drive, 'status.hand', '{"raised":false}');
      expect(down['ok'], isTrue);
      expect(app.myHandRaised, isFalse);
      expect(collector.hands, contains(true));
    });

    test('a raise outside a meeting is refused, not performed', () async {
      final collector = _Recording();
      final app = await booted(collector);
      final drive = install(app);
      expect(app.inCall, isFalse);
      expect(await call(drive, 'status.hand', '{"raised":true}'), {'ok': false, 'reason': 'not_in_call'});
      expect(app.myHandRaised, isFalse);
      expect(collector.hands, isEmpty);
    });

    test('with no socket every write is refused not_connected and the hand does not move', () async {
      final app = AppState()..debugHuddle = ['Bob'];
      final drive = install(app);
      for (final (method, args) in [
        ('status.setAvailability', '{"availability":"Away"}'),
        ('status.setCustom', '{"text":"x"}'),
        ('status.clearCustom', '{}'),
        ('status.emote', '{"emote":"🔥"}'),
        ('status.hand', '{"raised":true}'),
      ]) {
        expect(await call(drive, method, args), {'ok': false, 'reason': 'not_connected'}, reason: method);
      }
      expect(app.myHandRaised, isFalse);
    });

    test('a declined frame is send_failed carrying the sentence the UI shows', () async {
      final drive = install(await booted(_Recording(decline: true)));
      for (final (method, args) in [
        ('status.setAvailability', '{"availability":"Away"}'),
        ('status.setCustom', '{"text":"x"}'),
        ('status.clearCustom', '{}'),
        ('status.emote', '{"emote":"🔥"}'),
      ]) {
        final body = await call(drive, method, args);
        expect(body['ok'], isFalse, reason: method);
        expect(body['reason'], 'send_failed', reason: method);
        expect(body['error'], contains('socket closed'), reason: method);
      }
    });

    test('bad args are invalidParams naming the field', () async {
      final drive = install(AppState());
      await expectInvalid(drive, 'status.setAvailability', '{}', 'availability');
      await expectInvalid(drive, 'status.setAvailability', '{"availability":"Focused"}', 'Active, Busy, Away');
      await expectInvalid(drive, 'status.setCustom', '{}', 'text');
      await expectInvalid(drive, 'status.setCustom', '{"text":"x","emoji":3}', 'emoji');
      await expectInvalid(drive, 'status.setCustom', '{"text":"x","clearAfterMinutes":0}', 'clearAfterMinutes');
      await expectInvalid(drive, 'status.emote', '{"emote":"🦄"}', 'emote');
      await expectInvalid(drive, 'status.hand', '{}', 'raised');
      await expectInvalid(drive, 'status.hand', '{"raised":"yes"}', 'raised');
    });
  });

  group('ui', () {
    test('gameboy sets mode and theme through AppState, persisting both', () async {
      final app = AppState();
      final drive = install(app);
      await call(drive, 'ui.sfx', '{"on":false}');
      final body = dataOf(await call(drive, 'ui.gameboy', '{"on":true,"theme":"SafeNow"}'));
      expect(body['gameboyMode'], isTrue);
      expect(body['gameboyTheme'], 'safenow');
      expect(app.gameboyMode, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isNotEmpty);

      final off = dataOf(await call(drive, 'ui.gameboy', '{"on":false}'));
      expect(off['gameboyMode'], isFalse);
      expect(off['gameboyTheme'], 'safenow', reason: 'theme untouched when not asked');
    });

    test('sfx flips sound effects', () async {
      final app = AppState();
      final drive = install(app);
      expect(dataOf(await call(drive, 'ui.state'))['soundEffects'], isTrue);
      expect(dataOf(await call(drive, 'ui.sfx', '{"on":false}'))['soundEffects'], isFalse);
      expect(app.soundEffects, isFalse);
    });

    test('party starts and stops through setPartyMode', () async {
      final app = await booted(_Recording());
      final drive = install(app);
      final on = await call(drive, 'ui.party', '{"on":true}');
      expect(on['ok'], isTrue, reason: '$on');
      expect((dataOf(on)['party']! as Map)['active'], isTrue);
      expect(app.partyMode, isTrue);
      final off = await call(drive, 'ui.party', '{"on":false}');
      expect((dataOf(off)['party']! as Map)['active'], isFalse);
    });

    test('party refuses with no socket, and when PartyMode will not start', () async {
      expect(await call(install(AppState()), 'ui.party', '{"on":true}'), {'ok': false, 'reason': 'not_connected'});

      final app = await booted(_Recording(faceless: true));
      final body = await call(install(app), 'ui.party', '{"on":true}');
      expect(body['ok'], isFalse);
      expect(body['reason'], 'party_refused');
      expect(body['error'], isA<String>());
      expect((body['party']! as Map)['active'], isFalse);
      expect(app.partyMode, isFalse);
    });

    test('bad args are invalidParams', () async {
      final drive = install(AppState());
      await expectInvalid(drive, 'ui.gameboy', '{}', 'on');
      await expectInvalid(drive, 'ui.gameboy', '{"on":1}', 'on');
      await expectInvalid(drive, 'ui.gameboy', '{"theme":"neon"}', 'purple, safenow');
      await expectInvalid(drive, 'ui.sfx', '{}', 'on');
      await expectInvalid(drive, 'ui.party', '{"on":"true"}', 'on');
    });
  });

  group('the outward gate on a live boot', () {
    const outward = [
      ('status.setAvailability', '{"availability":"Away"}'),
      ('status.setCustom', '{"text":"x"}'),
      ('status.clearCustom', '{}'),
      ('status.emote', '{"emote":"🔥"}'),
      ('status.hand', '{"raised":false}'),
      ('ui.party', '{"on":false}'),
    ];

    test('holds every outward action outside the test space, before it reaches the app', () async {
      final collector = _Recording();
      final drive = install(await booted(collector), boot: 'live');
      for (final (method, args) in outward) {
        final body = await call(drive, method, args);
        expect(body['ok'], isFalse, reason: method);
        expect(body['reason'], 'outward_outside_test_space', reason: method);
      }
      expect(collector.availabilitiesSet, isEmpty);
      expect(collector.customs, isEmpty);
      expect(collector.clears, 0);
      expect(collector.emotes, isEmpty);
      expect(collector.hands, isEmpty);
    });

    test('lets them through with confirm:true', () async {
      final collector = _Recording();
      final drive = install(await booted(collector), boot: 'live');
      final body = await call(drive, 'status.setAvailability', '{"availability":"Away","confirm":true}');
      expect(body['ok'], isTrue);
      expect(collector.availabilitiesSet, ['Away']);
    });

    test('lets them through in the test space', () async {
      final app = AppState()
        ..debugApplySnapshot(PresenceSnapshot(
          self: const SelfState(spaceId: 'test-space'),
          players: const [],
          health: const CollectorHealth(),
          at: DateTime(2026, 11, 11),
        ));
      final drive = install(app, boot: 'live', testSpaceId: 'test-space');
      // Past the gate, the app's own no: there is no socket in this state.
      expect(await call(drive, 'status.emote', '{"emote":"🔥"}'), {'ok': false, 'reason': 'not_connected'});
    });

    test('the local switches and readouts are not gated', () async {
      final drive = install(AppState(), boot: 'live');
      for (final (method, args) in [
        ('status.state', '{}'),
        ('ui.state', '{}'),
        ('ui.sfx', '{"on":false}'),
        ('ui.gameboy', '{"theme":"purple"}'),
      ]) {
        expect((await call(drive, method, args))['ok'], isTrue, reason: method);
      }
    });
  });
}
