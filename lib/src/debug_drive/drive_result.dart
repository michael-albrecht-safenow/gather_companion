/// What a drive action answers, and the two ways it can say no.
///
/// There are three outcomes and they must stay three, because the caller is an
/// agent that acts on the difference:
///
///  * **ok** — the action did what it says. `{"ok":true,"data":…}`.
///  * **refused** — the *app* said no for a reason it would give a person: no
///    call to mute, not in a space, a room that is locked, an outward action
///    outside the test space. A successful RPC carrying
///    `{"ok":false,"reason":…}`, because nothing is broken; the agent should read
///    the reason and change what it asks for, not retry.
///  * **error** — the *drive* broke, or was asked something malformed. An RPC
///    error, so it cannot be mistaken for an answer. Bad input is
///    [DriveInvalidParams] (`invalidParams`, −32602); anything a handler throws
///    is an extension error with `{"error","type"}` and is also reported through
///    `FlutterError.reportError`, so it reaches the console and the test runner
///    rather than vanishing into a JSON field nobody reads.
///
/// Folding a refusal into an error would make "the app declined" look like "the
/// drive is broken" and an agent would start debugging the wrong layer; folding
/// an error into a refusal would let a crash read as a polite no.
library;

/// The answer to one drive action, before it is put on the wire.
sealed class DriveResult {
  const DriveResult();

  /// The action did what it says; [data] is its readout (JSON-encodable).
  const factory DriveResult.ok([Object? data]) = DriveOk;

  /// The app declined, for [reason] — a stable snake_case word an agent can
  /// switch on — with any context in [extra] (never `ok` or `reason`, which
  /// are this envelope's own keys and win over anything passed here).
  const factory DriveResult.refused(String reason, [Map<String, Object?> extra]) =
      DriveRefused;

  /// The JSON object this result is sent as.
  Map<String, Object?> toJson();
}

final class DriveOk extends DriveResult {
  const DriveOk([this.data]);

  final Object? data;

  @override
  Map<String, Object?> toJson() => {'ok': true, 'data': data};
}

final class DriveRefused extends DriveResult {
  const DriveRefused(this.reason, [this.extra = const {}]);

  final String reason;
  final Map<String, Object?> extra;

  @override
  Map<String, Object?> toJson() => {...extra, 'ok': false, 'reason': reason};
}

/// The caller sent something the action cannot read: a missing field, the wrong
/// type, an op id that is not one. Answered as `invalidParams`, and *not*
/// reported as an app failure — the app did nothing wrong.
class DriveInvalidParams implements Exception {
  const DriveInvalidParams(this.message);

  final String message;

  @override
  String toString() => 'DriveInvalidParams: $message';
}

/// Typed reads over an action's `args` object, throwing [DriveInvalidParams]
/// with the field's name rather than letting a cast fail as a `TypeError` —
/// which would be reported as the drive breaking when it was the caller's typo.
extension DriveArgs on Map<String, Object?> {
  /// [key] as a string, required.
  String requireString(String key) {
    final value = this[key];
    if (value is String && value.isNotEmpty) return value;
    throw DriveInvalidParams(
      value == null ? '"$key" is required' : '"$key" must be a non-empty string',
    );
  }

  /// [key] as an integer, or null when absent. JSON has one number type, so a
  /// whole double (`5.0`) is accepted; a fraction is not.
  int? optionalInt(String key, {int? min, int? max}) {
    final value = this[key];
    if (value == null) return null;
    final int n;
    if (value is int) {
      n = value;
    } else if (value is double && value == value.truncateToDouble() && value.isFinite) {
      n = value.toInt();
    } else {
      throw DriveInvalidParams('"$key" must be an integer');
    }
    if (min != null && n < min) throw DriveInvalidParams('"$key" must be >= $min');
    if (max != null && n > max) throw DriveInvalidParams('"$key" must be <= $max');
    return n;
  }
}
