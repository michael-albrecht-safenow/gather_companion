/// The registry: what reaches the VM, what an action is handed, and how its
/// answer is put on the wire.
///
/// The install rule is the one worth the most here. `registerExtension` throws
/// on a duplicate and cannot take a registration back, so a set that registered
/// as it went and then collided would leave half a feature on the channel — and
/// an agent asking for the missing half gets "unknown method", which reads as a
/// broken connection rather than a naming mistake in this build.
///
/// The rest pins the three-way answer: ok, refused (a successful RPC with
/// `ok:false`), and error (an RPC error, reported through `FlutterError`). An
/// agent decides whether to debug the app or the drive on that difference.
library;

import 'dart:developer';

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/debug_drive/debug_drive.dart';
import 'package:gather_companion/src/debug_drive/drive_result.dart';

import 'drive_test_support.dart';

DebugDrive _drive(RecordingRegistrar registrar, {String boot = 'harness', bool inTestSpace = false, String? spaceId}) =>
    DebugDrive(
      boot: () => boot,
      spaceId: () => spaceId,
      inTestSpace: () => inTestSpace,
      register: registrar.call,
    );

DriveAction _echo(String name, {bool outward = false}) =>
    DriveAction(name, (args) async => DriveResult.ok(args), outward: outward);

void main() {
  group('names', () {
    test('a method is ext.gc. plus at least two lowerCamelCase segments', () {
      expect(DebugDrive.isValidMethod('ext.gc.state.dump'), isTrue);
      expect(DebugDrive.isValidMethod('ext.gc.presence.map.people'), isTrue);
      expect(DebugDrive.isValidMethod('ext.gc.call.setMic'), isTrue);
      expect(DebugDrive.isValidMethod('ext.gc.a1.b2'), isTrue);

      expect(DebugDrive.isValidMethod('ext.gc.state'), isFalse, reason: 'no action');
      expect(DebugDrive.isValidMethod('ext.flutter.state.dump'), isFalse);
      expect(DebugDrive.isValidMethod('ext.gc.State.dump'), isFalse, reason: 'UpperCamel');
      expect(DebugDrive.isValidMethod('ext.gc.state.set_mic'), isFalse, reason: 'snake_case');
      expect(DebugDrive.isValidMethod('ext.gc.state.set-mic'), isFalse);
      expect(DebugDrive.isValidMethod('ext.gc.state..dump'), isFalse, reason: 'empty segment');
      expect(DebugDrive.isValidMethod('ext.gc.state.1dump'), isFalse, reason: 'leading digit');
      expect(DebugDrive.isValidMethod('ext.gc.state.dump.'), isFalse);
    });
  });

  group('install', () {
    test('registers every action under its full name, in one pass', () {
      final reg = RecordingRegistrar();
      final drive = _drive(reg)
        ..install([
          DriveFeature('state', [_echo('dump')]),
          DriveFeature('presence', [_echo('roster'), _echo('map.people')]),
        ]);

      expect(reg.methods, ['ext.gc.state.dump', 'ext.gc.presence.roster', 'ext.gc.presence.map.people']);
      expect(drive.actions.map((a) => a.name), [
        'ext.gc.presence.map.people',
        'ext.gc.presence.roster',
        'ext.gc.state.dump',
      ], reason: 'listed sorted');
    });

    test('an invalid name anywhere in the set registers nothing, and every problem is named', () {
      final reg = RecordingRegistrar();
      final drive = _drive(reg);
      expect(
        () => drive.install([
          DriveFeature('state', [_echo('dump')]),
          DriveFeature('call', [_echo('set_mic'), _echo('Leave')]),
          DriveFeature('Bad', [_echo('x')]),
        ]),
        throwsA(isA<ArgumentError>()
            .having((e) => '${e.message}', 'message', contains('ext.gc.call.set_mic'))
            .having((e) => '${e.message}', 'message', contains('ext.gc.call.Leave'))
            .having((e) => '${e.message}', 'message', contains('feature "Bad"'))),
      );
      expect(reg.methods, isEmpty, reason: 'the valid state.dump must not slip through');
      expect(drive.actions, isEmpty);
    });

    test('a duplicate within one install registers nothing', () {
      final reg = RecordingRegistrar();
      final drive = _drive(reg);
      expect(
        () => drive.install([
          DriveFeature('state', [_echo('dump')]),
          DriveFeature('state', [_echo('dump')]),
        ]),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('listed twice'))),
      );
      expect(reg.methods, isEmpty);
    });

    test('a name already registered by an earlier install registers nothing new', () {
      final reg = RecordingRegistrar();
      final drive = _drive(reg)..install([DriveFeature('state', [_echo('dump')])]);
      expect(
        () => drive.install([
          DriveFeature('log', [_echo('tail')]),
          DriveFeature('state', [_echo('dump')]),
        ]),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('already registered'))),
      );
      expect(reg.methods, ['ext.gc.state.dump'], reason: 'log.tail was valid but must not be half-installed');
      expect(drive.actions.map((a) => a.name), ['ext.gc.state.dump']);
    });

    test('the default registrar is the real dart:developer one', () {
      // This test deliberately registers one method for real on this isolate: a
      // drive built without a registrar must reach the VM, not be a silent
      // no-op. `drive.actions` alone could not tell — install fills it whatever
      // registrar it is given — so the proof is that the VM now refuses the same
      // name, which registerExtension does for a duplicate.
      final drive = DebugDrive(boot: () => 'harness', spaceId: () => null, inTestSpace: () => false);
      drive.install([DriveFeature('registryTest', [_echo('probe')])]);
      expect(drive.actions.single.name, 'ext.gc.registryTest.probe');
      expect(
        () => registerExtension(
          'ext.gc.registryTest.probe',
          (_, _) async => ServiceExtensionResponse.result('{}'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('args', () {
    late DebugDrive drive;
    setUp(() => drive = _drive(RecordingRegistrar())..install([DriveFeature('test', [_echo('echo')])]));

    test('a missing args param is the empty object', () async {
      expect(resultOf(await drive.invoke('ext.gc.test.echo')), {'ok': true, 'data': <String, Object?>{}});
    });

    test('a JSON object string is decoded and handed over', () async {
      final body = resultOf(await drive.invoke('ext.gc.test.echo', '{"x":1,"nested":{"y":[true,null]}}'));
      expect(body['data'], {
        'x': 1,
        'nested': {
          'y': [true, null],
        },
      });
    });

    test('other params are ignored', () async {
      final body = resultOf(await drive.handle('ext.gc.test.echo', {'args': '{"a":1}', 'isolateId': 'isolates/1', 'x': 'y'}));
      expect(body['data'], {'a': 1});
    });

    for (final (label, raw) in [
      ('invalid JSON', '{nope'),
      ('an array', '[1,2]'),
      ('a bare string', '"hello"'),
      ('a number', '42'),
      ('null', 'null'),
      ('Dart toString text, the mistake an MCP client makes with a raw object', '{x: 1}'),
    ]) {
      test('$label is invalidParams, not a guess', () async {
        final err = errorOf(await drive.invoke('ext.gc.test.echo', raw));
        expect(err.code, ServiceExtensionResponse.invalidParams);
        expect(err.detail['error'], contains('"args"'));
      });
    }

    test('an unknown method is invalidParams that points at drive.list', () async {
      final err = errorOf(await drive.invoke('ext.gc.test.nope'));
      expect(err.code, ServiceExtensionResponse.invalidParams);
      expect(err.detail['error'], contains('drive.list'));
    });
  });

  group('results', () {
    test('ok wraps data; refused is a successful RPC with ok:false and its context', () async {
      final drive = _drive(RecordingRegistrar())
        ..install([
          DriveFeature('test', [
            DriveAction('yes', (_) async => const DriveResult.ok({'n': 3})),
            DriveAction('no', (_) async => const DriveResult.refused('no_call', {'detail': 'not in a call', 'ok': true, 'reason': 'x'})),
          ]),
        ]);

      expect(resultOf(await drive.invoke('ext.gc.test.yes')), {
        'ok': true,
        'data': {'n': 3},
      });
      expect(resultOf(await drive.invoke('ext.gc.test.no')), {
        'ok': false,
        'reason': 'no_call',
        'detail': 'not in a call',
      }, reason: 'extra may not override the envelope');
    });

    test('a handler that throws is an extension error with error and type, and is reported', () async {
      final reported = captureFlutterErrors();
      final drive = _drive(RecordingRegistrar())
        ..install([
          DriveFeature('test', [DriveAction('boom', (_) async => throw StateError('kaput'))]),
        ]);

      final err = errorOf(await drive.invoke('ext.gc.test.boom'));
      expect(err.code, inInclusiveRange(ServiceExtensionResponse.extensionErrorMin, ServiceExtensionResponse.extensionErrorMax));
      expect(err.detail, {'error': 'Bad state: kaput', 'type': 'StateError'});
      expect(reported, hasLength(1));
      expect(reported.single.exception, isA<StateError>());
      expect(reported.single.library, 'debug drive');
      expect('${reported.single.context}', contains('ext.gc.test.boom'));
    });

    test('a synchronous throw is caught the same way', () async {
      final reported = captureFlutterErrors();
      final drive = _drive(RecordingRegistrar())
        ..install([
          DriveFeature('test', [
            DriveAction('sync', (_) {
              throw ArgumentError('sync');
            }),
          ]),
        ]);
      final err = errorOf(await drive.invoke('ext.gc.test.sync'));
      expect(err.detail['type'], 'ArgumentError');
      expect(reported, hasLength(1));
    });

    test('data that cannot be encoded is a drive error, reported, not an unhandled throw', () async {
      final reported = captureFlutterErrors();
      final drive = _drive(RecordingRegistrar())
        ..install([
          DriveFeature('test', [DriveAction('opaque', (_) async => DriveResult.ok(Object()))]),
        ]);
      final err = errorOf(await drive.invoke('ext.gc.test.opaque'));
      expect(err.code, ServiceExtensionResponse.extensionError);
      expect(err.detail['type'], contains('JsonUnsupportedObjectError'));
      expect(reported, hasLength(1));
    });

    test('DriveInvalidParams from a handler is invalidParams and is not reported as an app failure', () async {
      final reported = captureFlutterErrors();
      final drive = _drive(RecordingRegistrar())
        ..install([
          DriveFeature('test', [DriveAction('need', (args) async => DriveResult.ok(args.requireString('id')))]),
        ]);
      final err = errorOf(await drive.invoke('ext.gc.test.need', '{}'));
      expect(err.code, ServiceExtensionResponse.invalidParams);
      expect(err.detail['error'], '"id" is required');
      expect(reported, isEmpty);
    });

    test('the handler the VM gets is the same door invoke uses', () async {
      final reg = RecordingRegistrar();
      _drive(reg).install([DriveFeature('test', [_echo('echo')])]);
      final response = await reg.handlers['ext.gc.test.echo']!('ext.gc.test.echo', {'args': '{"v":2}'});
      expect(resultOf(response)['data'], {'v': 2});
    });
  });

  group('typed args', () {
    test('optionalInt accepts whole numbers, bounds them, and names the field on a bad one', () {
      expect(<String, Object?>{}.optionalInt('n'), isNull);
      expect(<String, Object?>{'n': 4}.optionalInt('n'), 4);
      expect(<String, Object?>{'n': 4.0}.optionalInt('n'), 4);
      expect(() => <String, Object?>{'n': 4.5}.optionalInt('n'), throwsA(isA<DriveInvalidParams>()));
      expect(() => <String, Object?>{'n': '4'}.optionalInt('n'), throwsA(isA<DriveInvalidParams>()));
      expect(() => <String, Object?>{'n': -1}.optionalInt('n', min: 0), throwsA(isA<DriveInvalidParams>()));
      expect(() => <String, Object?>{'n': 9}.optionalInt('n', max: 8), throwsA(isA<DriveInvalidParams>()));
    });

    test('requireString refuses absent, empty and non-string values', () {
      expect(<String, Object?>{'id': 'a'}.requireString('id'), 'a');
      expect(() => <String, Object?>{}.requireString('id'), throwsA(isA<DriveInvalidParams>()));
      expect(() => <String, Object?>{'id': ''}.requireString('id'), throwsA(isA<DriveInvalidParams>()));
      expect(() => <String, Object?>{'id': 3}.requireString('id'), throwsA(isA<DriveInvalidParams>()));
    });
  });

  group('the outward gate', () {
    // Every combination: refused exactly when the action is outward, on the live
    // wire, outside the test space, and not confirmed with a real `true`.
    for (final outward in [false, true]) {
      for (final boot in ['live', 'harness']) {
        for (final inTestSpace in [false, true]) {
          for (final (confirmLabel, args) in [
            ('no confirm', null),
            ('confirm:true', '{"confirm":true}'),
            ('confirm:"true" (a string is not consent)', '{"confirm":"true"}'),
            ('confirm:false', '{"confirm":false}'),
          ]) {
            final confirmed = args == '{"confirm":true}';
            final refused = outward && boot == 'live' && !inTestSpace && !confirmed;
            test('${outward ? 'outward' : 'inward'}, $boot, ${inTestSpace ? 'test space' : 'other space'}, '
                '$confirmLabel → ${refused ? 'refused' : 'runs'}', () async {
              var ran = false;
              final drive = _drive(RecordingRegistrar(), boot: boot, inTestSpace: inTestSpace, spaceId: 'space-real')
                ..install([
                  DriveFeature('test', [
                    DriveAction('wave', (_) async {
                      ran = true;
                      return const DriveResult.ok('waved');
                    }, outward: outward),
                  ]),
                ]);
              final body = resultOf(await drive.invoke('ext.gc.test.wave', args));
              if (refused) {
                expect(body, {'ok': false, 'reason': 'outward_outside_test_space', 'spaceId': 'space-real'});
                expect(ran, isFalse, reason: 'a refused outward action must not run at all');
              } else {
                expect(body, {'ok': true, 'data': 'waved'});
                expect(ran, isTrue);
              }
            });
          }
        }
      }
    }

    test('the gate reads boot and space per call, not once at install', () async {
      var boot = 'harness';
      var inSpace = false;
      final drive = DebugDrive(
        boot: () => boot,
        spaceId: () => 's',
        inTestSpace: () => inSpace,
        register: RecordingRegistrar().call,
      )..install([DriveFeature('test', [_echo('wave', outward: true)])]);

      expect(resultOf(await drive.invoke('ext.gc.test.wave'))['ok'], isTrue);
      boot = 'live';
      expect(resultOf(await drive.invoke('ext.gc.test.wave'))['ok'], isFalse);
      inSpace = true;
      expect(resultOf(await drive.invoke('ext.gc.test.wave'))['ok'], isTrue);
    });
  });
}
