/// `ext.gc.ui.*`: the switches the app owns — Gameboy mode and its skin, sound
/// effects, party mode — flipped through the same [AppState] setters the
/// Settings screen's tiles call.
///
/// ## Two of three are local; party is outward
///
/// `gameboy` and `sfx` are look-and-sound preferences on this phone. They are
/// persisted (`UiPreferences`) exactly as a tap would persist them, and the
/// power-on jingle plays on an off→on flip with sounds on, as it does from the
/// tile — but nobody in the space sees any of it, so neither is outward.
///
/// `party {on}` teleports our avatar around the map every few hundred
/// milliseconds; everyone in the space watches it hop. It is `outward: true`,
/// gated by the registry on `boot: "live"` outside `DRIVE_TEST_SPACE` unless
/// `"confirm": true`. Turning it **off** is gated too: the gate is per action,
/// and an agent stopping a party it should not have started is still acting
/// on the space.
///
/// ## Answers
///
/// Every action answers the same readout: `gameboyMode`, `gameboyTheme` (its
/// persisted id — `purple`, `safenow`), `soundEffects`, and `party` (active,
/// hops, safeTiles, and `detail` — why it is not hopping, when it is not).
/// `gameboy` needs at least one of `on` / `theme`; both is one call, theme
/// first, so the boot jingle (if any) plays on the skin asked for.
///
/// ## Refusals
///
///  * `party`: `not_connected` with no game socket; `party_refused {error,
///    party}` when [PartyMode] declined to start (nowhere safe to stand, no
///    map yet) — `error` is the sentence the Settings snackbar shows.
///
/// ## The call screen: `openCall` / `closeCall`
///
/// `call.spotlight` reads the call screen's controller and so answers
/// `call_screen_closed` while a call is up but the faces are not on display;
/// the only way to open them used to be tapping the "In a call with …" banner by
/// coordinate. `openCall` is that tap: the banner's own `openCallScreen`, pushed
/// from the mounted `HomeShell`'s context through `callScreenDebugActive`
/// (`../call_screen_debug.dart`, written only under `kDebugMode`). It refuses
/// what the banner could not do — `no_call` when there is no banner to tap (not
/// `inCall`, and no `callInterrupted` notice holding it open), `already_open`
/// when a call screen is mounted, `app_not_mounted` with no shell. `closeCall`
/// pops it back to the office (`not_open` without one). The push lands on the
/// next frame, so `openCall` answers `pending: true` and `call.spotlight` reads
/// the screen once it is up. Neither is outward: what this phone shows is its
/// own business, and opening the faces sends nothing.
library;

import '../app_state.dart';
import '../call_screen_debug.dart';
import '../media/spotlight_controller.dart';
import '../../ui/gameboy_theme.dart' show GameboyThemeId;
import 'debug_drive.dart';
import 'drive_result.dart';

/// `ext.gc.ui.{state, gameboy, sfx, party, openCall, closeCall}`.
///
/// [callScreen] is the mounted shell's door to the call screen (the app passes
/// nothing and gets `() => callScreenDebugActive`; a test passes its own);
/// [screens] is the registry mounted call screens write to (`spotlightRegistry`).
DriveFeature uiFeature({
  required AppState Function() app,
  required String Function() boot,
  CallScreenDebug? Function()? callScreen,
  SpotlightRegistry? screens,
}) {
  final door = callScreen ?? () => callScreenDebugActive;
  final registry = screens ?? spotlightRegistry;

  Map<String, Object?> callReadout() {
    final state = app();
    return {
      'boot': boot(),
      'inCall': state.inCall,
      'callInterrupted': state.callInterrupted,
      'screens': registry.count,
    };
  }

  Map<String, Object?> readout() {
    final state = app();
    return {
      'boot': boot(),
      'gameboyMode': state.gameboyMode,
      'gameboyTheme': state.gameboyTheme.id,
      'soundEffects': state.soundEffects,
      'party': state.party.toJson(),
    };
  }

  return DriveFeature('ui', [
    DriveAction('state', (args) async => DriveResult.ok(readout())),
    DriveAction('gameboy', (args) async {
      final on = _optionalBool(args, 'on');
      final theme = _optionalTheme(args);
      if (on == null && theme == null) {
        throw const DriveInvalidParams('give "on", "theme", or both');
      }
      final state = app();
      if (theme != null) await state.setGameboyTheme(theme);
      if (on != null) await state.setGameboyMode(on);
      return DriveResult.ok(readout());
    }),
    DriveAction('sfx', (args) async {
      final on = _optionalBool(args, 'on');
      if (on == null) throw const DriveInvalidParams('"on" is required');
      await app().setSoundEffects(on);
      return DriveResult.ok(readout());
    }),
    DriveAction(
      'party',
      (args) async {
        final on = _optionalBool(args, 'on');
        if (on == null) throw const DriveInvalidParams('"on" is required');
        final state = app();
        if (!state.collectorAttached) return const DriveResult.refused('not_connected');
        final error = await state.setPartyMode(on);
        if (error != null) {
          return DriveResult.refused('party_refused', {'error': error, 'party': state.party.toJson()});
        }
        return DriveResult.ok(readout());
      },
      outward: true,
    ),
    DriveAction('openCall', (args) async {
      final hook = door();
      if (hook == null) return DriveResult.refused('app_not_mounted', {'boot': boot()});
      final state = app();
      // The banner's own condition (`map_screen.dart`, `CallBanner` strip): no
      // banner, no tap.
      if (!state.inCall && !state.callInterrupted) return DriveResult.refused('no_call', callReadout());
      if (registry.count > 0) return DriveResult.refused('already_open', callReadout());
      hook.open();
      return DriveResult.ok({...callReadout(), 'pending': true});
    }),
    DriveAction('closeCall', (args) async {
      final hook = door();
      if (hook == null) return DriveResult.refused('app_not_mounted', {'boot': boot()});
      if (registry.count == 0 || !hook.close()) return DriveResult.refused('not_open', callReadout());
      return DriveResult.ok({...callReadout(), 'pending': true});
    }),
  ]);
}

bool? _optionalBool(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null || value is bool) return value as bool?;
  throw DriveInvalidParams('"$key" must be a boolean');
}

GameboyThemeId? _optionalTheme(Map<String, Object?> args) {
  final value = args['theme'];
  if (value == null) return null;
  if (value is String) {
    for (final t in GameboyThemeId.values) {
      if (t.id == value.toLowerCase()) return t;
    }
  }
  throw DriveInvalidParams('"theme" must be one of ${GameboyThemeId.values.map((t) => t.id).join(', ')}');
}
