/// `ext.gc.status.*`: being a person in the room — availability, the line under
/// your name, an emote, a raised hand — driven through the same [AppState]
/// methods the status sheet, the control bar and the handheld's menu call.
///
/// ## Every action is outward
///
/// All five write our own `SpaceUser` row (or, for an emote, broadcast to
/// everyone in range), which is the row the desktop client and every colleague
/// read. Setting yourself Busy from the drive *is* setting yourself Busy. So each
/// one is `outward: true`: on `boot: "live"` outside `DRIVE_TEST_SPACE` the
/// registry refuses it with `outward_outside_test_space` unless the args carry
/// `"confirm": true`, which an agent sends only after the user said yes.
///
/// ## What a write answers
///
/// The readout after it ran — `availability`, `customStatus`, `handRaised` — and,
/// where the app is not optimistic, what was *asked*. Availability and the custom
/// status are read back off the roster (`AppState.myAvailability`,
/// `customStatus`), not echoed, so straight after `setAvailability {Busy}` the
/// readout may still say `Active`: `pending: true` says the patch has not landed
/// yet rather than letting an agent read "it did not take". Poll `status.state`.
/// The hand is local-first (the button moves on the press), so it answers its
/// new value at once.
///
/// ## Refusals
///
///  * `not_connected` — no game socket attached (`AppState.collectorAttached`).
///    Checked before acting, because `setHandRaised` would otherwise flip the
///    button and silently send nothing.
///  * `send_failed {error}` — the collector declined the frame; `error` is the
///    sentence the UI would have shown in its snackbar.
///  * `not_in_call` — `hand {raised:true}` outside a meeting. The raise button
///    exists only in a call, and the app lowers a hand left up outside one on
///    the next roster, so a raise there would be undone before anyone saw it.
///
/// `setCustom` without `clearAfterMinutes` expires after the status sheet's own
/// [statusClearAfter] (8 h), never "no expiry": the sheet always sends one, so a
/// status that stands forever on a colleague-visible row is nothing a tap could
/// leave behind — and a forgotten drive run should not either. Blank `text` is
/// `invalidParams` rather than a silent clear.
///
/// An emote is one of the picker's eight ([gbEmotes], the same list the control
/// bar offers) — anything else is `invalidParams`, since no control could send
/// it. A trailing U+FE0F is ignored when matching, because `👍️` carries one and
/// a caller typing 👍 should not have to know. Like the picker, the emote goes
/// through `sendEmoteLocalFirst`, so it appears on our own tile at once. (Waves
/// are not here: a wave targets a person and lives with presence.)
library;

import 'package:gather_client/gather_client.dart' show settableAvailabilities;

import '../../ui/status_sheet.dart' show statusClearAfter;
import '../app_state.dart';
import '../gameboy_controls.dart' show gbEmotes;
import 'debug_drive.dart';
import 'drive_result.dart';

/// `ext.gc.status.{state, setAvailability, setCustom, clearCustom, emote, hand}`.
DriveFeature statusFeature({
  required AppState Function() app,
  required String Function() boot,
  DateTime Function()? now,
}) {
  final clock = now ?? DateTime.now;

  Map<String, Object?> readout() {
    final state = app();
    final status = state.customStatus;
    return {
      'boot': boot(),
      'connected': state.collectorAttached,
      'availability': state.myAvailability,
      if (state.myAvailability == null) 'availabilityDetail': 'no roster yet — Gather has not said',
      'customStatus': status == null
          ? null
          : {
              'text': status.text,
              'emoji': status.emoji,
              'type': status.type,
              'clearAt': status.clearAt?.toUtc().toIso8601String(),
            },
      'handRaised': state.myHandRaised,
      'inCall': state.inCall,
    };
  }

  /// Runs one of AppState's sentence-or-null writes, refusing up front when
  /// there is no socket to write to.
  Future<DriveResult> write(
    Future<String?> Function(AppState state) send,
    Map<String, Object?> Function()? asked,
  ) async {
    final state = app();
    if (!state.collectorAttached) return const DriveResult.refused('not_connected');
    final error = await send(state);
    if (error != null) return DriveResult.refused('send_failed', {'error': error});
    return DriveResult.ok({...readout(), ...?asked?.call()});
  }

  return DriveFeature('status', [
    DriveAction('state', (args) async => DriveResult.ok(readout())),
    DriveAction(
      'setAvailability',
      (args) async {
        final availability = _requireAvailability(args);
        return write(
          (s) => s.setAvailability(availability),
          () => {'asked': availability, 'pending': app().myAvailability != availability},
        );
      },
      outward: true,
    ),
    DriveAction(
      'setCustom',
      (args) async {
        final text = args.requireString('text').trim();
        // AppState turns a blank line into a clear; answering that as a set
        // would report `asked: ""` for something that was never asked.
        if (text.isEmpty) throw const DriveInvalidParams('"text" is blank — use status.clearCustom to clear');
        final emoji = _optionalString(args, 'emoji');
        final minutes = args.optionalInt('clearAfterMinutes', min: 1, max: 60 * 24 * 7) ?? statusClearAfter.inMinutes;
        final clearAt = clock().toUtc().add(Duration(minutes: minutes));
        return write(
          (s) => s.setCustomStatus(text: text, emoji: emoji, clearAt: clearAt),
          () => {
            'asked': {'text': text, 'emoji': emoji, 'clearAt': clearAt.toIso8601String()},
            'pending': app().customStatus?.text != text,
          },
        );
      },
      outward: true,
    ),
    DriveAction(
      'clearCustom',
      (args) async => write((s) => s.clearCustomStatus(), () => {'pending': app().customStatus != null}),
      outward: true,
    ),
    DriveAction(
      'emote',
      (args) async {
        final emote = _requireEmote(args);
        return write((s) => s.sendEmoteLocalFirst(emote), () => {'sent': emote});
      },
      outward: true,
    ),
    DriveAction(
      'hand',
      (args) async {
        final raised = _requireBool(args, 'raised');
        final state = app();
        if (!state.collectorAttached) return const DriveResult.refused('not_connected');
        if (raised && !state.inCall) return const DriveResult.refused('not_in_call');
        await state.setHandRaised(raised);
        return DriveResult.ok(readout());
      },
      outward: true,
    ),
  ]);
}

String _requireAvailability(Map<String, Object?> args) {
  final raw = args.requireString('availability');
  for (final a in settableAvailabilities) {
    if (a.toLowerCase() == raw.toLowerCase()) return a;
  }
  throw DriveInvalidParams('"availability" must be one of ${settableAvailabilities.join(', ')}');
}

String _requireEmote(Map<String, Object?> args) {
  final raw = args.requireString('emote');
  String bare(String s) => s.replaceAll('\u{FE0F}', '');
  for (final e in gbEmotes) {
    if (bare(e) == bare(raw)) return e;
  }
  throw DriveInvalidParams('"emote" must be one of ${gbEmotes.join(' ')}');
}

String? _optionalString(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  throw DriveInvalidParams('"$key" must be a non-empty string');
}

bool _requireBool(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value is bool) return value;
  throw DriveInvalidParams(value == null ? '"$key" is required' : '"$key" must be a boolean');
}
