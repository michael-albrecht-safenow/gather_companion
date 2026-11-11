/// The debug drive's registry: a JSON API into the running app's business
/// logic, over the VM service channel `flutter run` already opens.
///
/// An agent checking this app used to have two options — tap the simulator by
/// coordinate and read pixels, or have a person tap a phone and read `media.log`
/// afterwards. Neither can answer "is the call wired right" honestly. Every
/// action here is a `dart:developer` service extension named
/// `ext.gc.<feature>.<action>` that calls one existing public method, or reads
/// one, and answers in JSON. See `docs/debug-drive-plan.md` for the whole design
/// and `AGENTS.md` beside this file for the rules.
///
/// Three properties this file exists to hold:
///
///  * **All or nothing.** [install] validates every name of a set before it
///    registers any. `registerExtension` throws on a duplicate, so registering
///    as it goes would leave half a feature on the channel when the second half
///    collided — and a half-registered feature looks exactly like a feature this
///    build does not have. An agent would conclude the wrong thing and nothing
///    would say why.
///  * **One wire shape.** Every action takes a single `args` param holding a
///    JSON object string, because service-extension params arrive as
///    `Map<String,String>` and anything nested would otherwise come through as
///    Dart `toString()` text. Missing means `{}`; anything that is not a JSON
///    object is `invalidParams`. Results go through [DriveResult], so ok,
///    refused and broken stay three different things.
///  * **Outward actions are gated.** A wave, a warp or a status change is seen by
///    everyone in the space. On the live wire such an action is refused with
///    `outward_outside_test_space` unless the space is the one compiled in as
///    `DRIVE_TEST_SPACE`, or the caller passes `{"confirm":true}` — which an
///    agent may only do after the user said yes in that session. The harness is
///    never gated: nobody is in a scripted room.
///
/// Nothing here may be reachable from a release build. The only entry is
/// `installDebugDrive`, called behind a compile-time `if (kDebugMode)`, which is
/// what lets the AOT compiler drop these names and bodies;
/// `tool/release_artifact_check.sh` greps the release binaries to prove it.
library;

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'drive_result.dart';

/// The test space's id, compiled in with `--dart-define=DRIVE_TEST_SPACE=<id>`.
/// Empty in a build without it, which means *no* space is the test space and
/// every outward action on the live wire needs `confirm`.
const String kDriveTestSpace = String.fromEnvironment('DRIVE_TEST_SPACE');

/// Every method name starts with this. `ext.` is the VM service's own rule for
/// extensions; `gc` keeps ours apart from `ext.flutter.*` and any plugin's.
const String kDrivePrefix = 'ext.gc.';

/// One segment of a method name: lowerCamelCase, starting with a letter.
final RegExp _segment = RegExp(r'^[a-z][a-zA-Z0-9]*$');

/// Whether [segment] is a valid name segment (also used for op kinds).
bool isDriveSegment(String segment) => _segment.hasMatch(segment);

/// An action's body. [args] is the decoded `args` object, `{}` when none was
/// sent. Throw [DriveInvalidParams] for unreadable input; return
/// [DriveResult.refused] for an expected no; let anything else throw.
typedef DriveHandler = Future<DriveResult> Function(Map<String, Object?> args);

/// How a method reaches the VM. `dart:developer`'s `registerExtension` in the
/// app; a map in a test, so the handlers can be called in-process.
typedef DriveRegistrar = void Function(
  String method,
  developer.ServiceExtensionHandler handler,
);

/// One action a feature contributes. [name] is what follows the feature in the
/// method name — `dump` in `ext.gc.state.dump`, or `map.people` in
/// `ext.gc.presence.map.people`.
class DriveAction {
  const DriveAction(this.name, this.handler, {this.outward = false});

  final String name;
  final DriveHandler handler;

  /// Whether this action does something other people in the space can see.
  /// Listed in `drive.list` and enforced by the test-space gate.
  final bool outward;
}

/// A named group of actions: the `state` in `ext.gc.state.dump`.
class DriveFeature {
  const DriveFeature(this.name, this.actions);

  final String name;
  final List<DriveAction> actions;
}

/// The registry. One per isolate in the app; as many as a test likes.
class DebugDrive {
  DebugDrive({
    required this._boot,
    required this._spaceId,
    required this._inTestSpace,
    DriveRegistrar? register,
  }) : _register = register ?? developer.registerExtension;

  final String Function() _boot;
  final String? Function() _spaceId;
  final bool Function() _inTestSpace;
  final DriveRegistrar _register;

  /// Full method name → action, in registration order.
  final Map<String, DriveAction> _actions = {};

  /// `"harness"` or `"live"`, read per call so a rebind is seen at once.
  String get boot => _boot();

  /// Every registered action, sorted by name — what `drive.list` reports.
  List<({String name, bool outward})> get actions {
    final names = _actions.keys.toList()..sort();
    return [for (final name in names) (name: name, outward: _actions[name]!.outward)];
  }

  /// Whether [method] is a well-formed drive method name:
  /// `ext.gc.` followed by at least two lowerCamelCase segments.
  static bool isValidMethod(String method) {
    if (!method.startsWith(kDrivePrefix)) return false;
    final segments = method.substring(kDrivePrefix.length).split('.');
    return segments.length >= 2 && segments.every(isDriveSegment);
  }

  /// Registers every action of [features], or none of them.
  ///
  /// Throws [ArgumentError] naming *every* problem — invalid names, duplicates
  /// within this set, names already registered — before anything reaches the
  /// VM. One problem at a time would turn a rename into a loop of runs.
  void install(List<DriveFeature> features) {
    final problems = <String>[];
    final pending = <String, DriveAction>{};
    for (final feature in features) {
      if (!isDriveSegment(feature.name)) {
        problems.add('feature "${feature.name}" is not a lowerCamelCase segment');
        continue;
      }
      for (final action in feature.actions) {
        final method = '$kDrivePrefix${feature.name}.${action.name}';
        if (!isValidMethod(method)) {
          problems.add('"$method" is not ext.gc.<feature>.<action> in lowerCamelCase segments');
        } else if (_actions.containsKey(method)) {
          problems.add('"$method" is already registered');
        } else if (pending.containsKey(method)) {
          problems.add('"$method" is listed twice');
        } else {
          pending[method] = action;
        }
      }
    }
    if (problems.isNotEmpty) {
      throw ArgumentError('debug drive: nothing registered — ${problems.join('; ')}');
    }
    for (final MapEntry(key: method, value: action) in pending.entries) {
      _register(method, handle);
      // Only after the VM took it, so this map never claims a method the
      // channel does not actually carry.
      _actions[method] = action;
    }
  }

  /// Calls [method] the way the VM would, with [args] as the `args` param's
  /// JSON text (omitted when null). The in-process door tests and an
  /// `integration_test` use instead of a VM service connection.
  Future<developer.ServiceExtensionResponse> invoke(String method, [String? args]) =>
      handle(method, {'args': ?args});

  /// The service-extension handler every drive method is registered with.
  Future<developer.ServiceExtensionResponse> handle(
    String method,
    Map<String, String> parameters,
  ) async {
    final action = _actions[method];
    if (action == null) {
      return _invalid('no drive action "$method" — ask ext.gc.drive.list');
    }

    final Map<String, Object?> args;
    try {
      args = parseArgs(parameters['args']);
    } on DriveInvalidParams catch (e) {
      return _invalid(e.message);
    }

    try {
      final gated = _gate(action, args);
      final result = gated ?? await action.handler(args);
      // Encoded inside the try: data a handler cannot serialise is a drive
      // bug, and must be reported as one rather than escape as an unhandled
      // error the VM turns into an opaque "Server error".
      return developer.ServiceExtensionResponse.result(jsonEncode(result.toJson()));
    } on DriveInvalidParams catch (e) {
      return _invalid(e.message);
    } catch (error, stack) {
      reportDriveError(error, stack, 'while handling $method');
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        jsonEncode({'error': '$error', 'type': '${error.runtimeType}'}),
      );
    }
  }

  /// The test-space gate. Null means go ahead.
  DriveResult? _gate(DriveAction action, Map<String, Object?> args) {
    if (!action.outward) return null;
    if (boot != 'live') return null;
    if (_inTestSpace()) return null;
    if (args['confirm'] == true) return null;
    return DriveResult.refused('outward_outside_test_space', {'spaceId': _spaceId()});
  }

  /// Decodes the `args` param: absent is `{}`, a JSON object is itself, and
  /// anything else — invalid JSON, an array, a bare string — is refused rather
  /// than guessed at.
  static Map<String, Object?> parseArgs(String? raw) {
    if (raw == null) return <String, Object?>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw DriveInvalidParams('"args" is not valid JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw const DriveInvalidParams('"args" must be a JSON object, as a string');
    }
    return decoded.cast<String, Object?>();
  }

  static developer.ServiceExtensionResponse _invalid(String message) =>
      developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.invalidParams,
        jsonEncode({'error': message}),
      );
}

/// Reports a drive failure where a developer will see it: the console under
/// `flutter run`, and a failing test under `flutter test`. Used for handler
/// throws and for op failures nobody polled.
void reportDriveError(Object error, StackTrace stack, String context) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'debug drive',
      context: ErrorDescription(context),
    ),
  );
}
