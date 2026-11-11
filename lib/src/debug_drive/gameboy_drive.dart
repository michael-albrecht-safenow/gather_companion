/// `ext.gc.gameboy.*`: what the handheld's keys mean right now, and its Select menu
/// driven the way a thumb drives it (plan task 4.3).
///
/// Gameboy mode re-houses the office behind a D-pad and four keys whose meaning
/// shifts with the situation — A chooses in the menu, opens the call during one and
/// latches the cart otherwise; B is inert in the menu and, with somebody in call
/// distance, a mute that a second tap turns into a wave. That table now lives in
/// `../gameboy_controls.dart` ([gameboyButtons]) and the shell wires its keys from
/// it, so `gameboy.mapping` reads the wiring rather than restating it.
///
/// ## The shell has to be mounted
///
/// The menu's cursor is the mounted shell's, read through `gameboyDebugActive`
/// (set by `GameboyShell` under `kDebugMode`). With Gameboy mode off, or the map tab
/// not on display, `mapping` says `shellMounted: false` and carries no `buttons` or
/// `menu` — there are no keys to mean anything — and every menu action is
/// `refused('shell_not_mounted')`. `home` and `wave` are read off [AppState] and are
/// there either way.
///
/// ## Presses are the shell's own handlers
///
/// `menu.toggle` (Select), `menu.move {direction}` (a D-pad step while the menu is
/// up) and `menu.confirm` (A while the menu is up) call the exact callbacks the keys
/// call — haptics, blips, the LCD toast on a refusal — so a drive press is a press.
/// Movement, B and Start outside the menu are not here: walking is `move.*`'s
/// (Phase 5), and B's mute and wave and Start's walk home are the same AppState
/// actions the dock drives.
///
/// `menu.confirm` is **outward**: the lit row may set your Gather status, flip your
/// camera or send an emote, all of which the space sees. It is gated even on the
/// rows that only switch tab, because the gate is per action and the cursor decides
/// at press time. `toggle` and `move` only move a highlight on this phone.
library;

import '../app_state.dart';
import '../gameboy_controls.dart';
import 'debug_drive.dart';
import 'drive_result.dart';

/// `ext.gc.gameboy.{mapping, menu.toggle, menu.move, menu.confirm}`.
///
/// [shell] is the mounted shell (the app passes `() => gameboyDebugActive`; a test
/// may pass its own).
DriveFeature gameboyFeature({
  required AppState Function() app,
  required String Function() boot,
  GameboyShellDebug? Function()? shell,
}) {
  final registered = shell ?? () => gameboyDebugActive;
  // Mounted is not enough: the tabs live in an IndexedStack, so the shell stays
  // registered while Settings or Plans is on screen.
  GameboyShellDebug? mounted() {
    final s = registered();
    return s != null && s.onScreen() ? s : null;
  }

  Map<String, Object?> readout() {
    final state = app();
    final s = mounted();
    final home = gameboyHomeSteps(state);
    final huddle = state.huddleRows;
    return {
      'boot': boot(),
      'gameboyMode': state.gameboyMode,
      'shellMounted': s != null,
      if (s == null) 'detail': 'the handheld is not on screen (Gameboy mode off, or another tab is showing)',
      if (s != null) 'menu': s.menu.debugSnapshot(),
      if (s != null) 'buttons': s.buttons().toJson(),
      'home': {'leaveHuddle': home.leaveHuddle, 'toDesk': home.toDesk},
      'wave': {
        'ready': huddle.isNotEmpty,
        'target': huddle.isEmpty ? null : {'id': huddle.first.id, 'name': huddle.first.name},
      },
    };
  }

  DriveResult notMounted() => DriveResult.refused('shell_not_mounted', {'gameboyMode': app().gameboyMode});

  return DriveFeature('gameboy', [
    DriveAction('mapping', (args) async => DriveResult.ok(readout())),
    DriveAction('menu.toggle', (args) async {
      final s = mounted();
      if (s == null) return notMounted();
      s.toggleMenu();
      return DriveResult.ok(readout());
    }),
    DriveAction('menu.move', (args) async {
      final direction = _requireDirection(args);
      final s = mounted();
      if (s == null) return notMounted();
      if (!s.menu.isOpen) return const DriveResult.refused('menu_closed');
      s.moveMenu(direction);
      return DriveResult.ok(readout());
    }),
    DriveAction(
      'menu.confirm',
      (args) async {
        final s = mounted();
        if (s == null) return notMounted();
        if (!s.menu.isOpen) return const DriveResult.refused('menu_closed');
        final chose = s.menu.choice.toJson();
        s.confirmMenu();
        return DriveResult.ok({'chose': chose, ...readout()});
      },
      outward: true,
    ),
  ]);
}

/// The D-pad's own spelling (`Up`, `Down`, `Left`, `Right`), accepted in any case.
String _requireDirection(Map<String, Object?> args) {
  final raw = args.requireString('direction');
  for (final d in const ['Up', 'Down', 'Left', 'Right']) {
    if (d.toLowerCase() == raw.toLowerCase()) return d;
  }
  throw const DriveInvalidParams('"direction" must be one of up, down, left, right');
}
