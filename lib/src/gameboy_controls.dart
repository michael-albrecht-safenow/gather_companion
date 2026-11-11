/// What the handheld's keys *mean*, with no widget in sight (plan task 4.3).
///
/// Gameboy mode (`lib/ui/gameboy_shell.dart`) is a look and an input surface: a
/// D-pad, A, B, Select and Start on a purple shell, every one of them calling an
/// [AppState] action the normal dock already has. What the shell does own is the
/// *mapping* — which action a key fires in which situation — and that mapping is
/// the part that has bitten: B that unmutes on the first tap of a double-tap would
/// broadcast you to a room you only meant to wave at, an A that boosts during a
/// call instead of opening it hides the call, a Start that walks you off while the
/// menu is up throws away the menu. Those are decisions, so they live here, where a
/// unit test can pin every row of the table and the debug drive can read the table
/// the buttons are wired from (`gameboy.mapping`) rather than an agent guessing it
/// from a screenshot.
///
/// What stays in the widget is presentation: the haptics and blips, the LCD toast
/// and its timer, the scroll-into-view of the lit menu row, and B's double-tap
/// *window* — the 280 ms timer that holds an unmute back. The window is timing,
/// the plan's "tap-window timers are presentation"; which step a tap takes once
/// the widget knows whether it fell inside the window is [decideBTap], here.
///
/// Three pieces:
///
///  * [GameboyMenu] — the Select menu's cursor: open/closed, the lit row, the lit
///    status and emote, and what A would choose ([GameboyMenu.choice]).
///  * [gameboyButtons] — what each key does right now, as a [GbButtonMap].
///  * [decideBTap] — the one step a B tap takes (see its table).
///
/// [GameboyShellDebug] / [gameboyDebugActive] is the debug drive's window onto a
/// mounted shell. The shell writes it only under `kDebugMode`, so release
/// tree-shakes the drive's only reader; it carries no names.
library;

import 'package:gather_client/gather_client.dart' show settableAvailabilities;

import 'app_state.dart';

/// Gather's eight, same codepoints and order as the dock's tray — the variation
/// selectors matter, so this list is copied rather than trimmed. See
/// `lib/ui/control_bar.dart`.
const gbEmotes = ['👋', '❤️', '🎉', '👍️', '🤣', '👏', '💯', '🔥'];

/// Where Select-menu rows other than status, camera and emotes leave to. The shell
/// cannot switch tabs itself; it hands these to the home shell's callbacks.
enum GbTab { dial, activity, plans, settings }

/// What A would do on the lit menu row.
sealed class GbMenuChoice {
  const GbMenuChoice();

  Map<String, Object?> toJson();
}

/// Set your Gather status to [availability].
final class GbChooseStatus extends GbMenuChoice {
  const GbChooseStatus(this.availability);

  final String availability;

  @override
  Map<String, Object?> toJson() => {'kind': 'status', 'availability': availability};
}

/// Flip the camera.
final class GbChooseCamera extends GbMenuChoice {
  const GbChooseCamera();

  @override
  Map<String, Object?> toJson() => {'kind': 'camera'};
}

/// Send [emote].
final class GbChooseEmote extends GbMenuChoice {
  const GbChooseEmote(this.emote);

  final String emote;

  @override
  Map<String, Object?> toJson() => {'kind': 'emote', 'emote': emote};
}

/// Leave the handheld for [tab].
final class GbChooseTab extends GbMenuChoice {
  const GbChooseTab(this.tab);

  final GbTab tab;

  @override
  Map<String, Object?> toJson() => {'kind': 'tab', 'tab': tab.name};
}

/// The Select menu's cursor.
///
/// Rows run top to bottom in D-pad order. Two of them — the status choices and the
/// emote strip — are rows the D-pad walks left/right inside; the other five are
/// single targets. Every move clamps at the ends, the same feel the office's walk
/// has when it meets a wall. The sub-positions (which status, which emote) survive
/// leaving and re-entering their row, which is what a thumb expects.
///
/// Plain mutable state, not a [ChangeNotifier]: the shell is its only listener and
/// wraps every call in its own `setState`, and the drive reads it on demand.
class GameboyMenu {
  static const int rowStatus = 0;
  static const int rowCamera = 1;
  static const int rowEmotes = 2;
  static const int rowDial = 3;
  static const int rowActivity = 4;
  static const int rowPlans = 5;
  static const int rowSettings = 6;

  /// Kept as a count so the cursor clamps without the menu and the router
  /// disagreeing about how many rows there are.
  static const int rowCount = 7;

  static const _rowNames = ['status', 'camera', 'emotes', 'dial', 'activity', 'plans', 'settings'];

  bool isOpen = false;
  int row = rowStatus;
  int status = 0;
  int emote = 0;

  /// Select: opens a closed menu, closes an open one. Opening lands on the status
  /// row with its cursor already on the status you are ([myAvailability], or
  /// `Active` when unknown), so the first thing the menu offers is a one-press
  /// change away from it. Returns whether the menu is now open.
  bool toggle(String? myAvailability) {
    isOpen = !isOpen;
    if (isOpen) {
      row = rowStatus;
      final at = settableAvailabilities.indexOf(myAvailability ?? 'Active');
      status = at < 0 ? 0 : at;
    }
    return isOpen;
  }

  /// Closes the menu. Returns whether it was open — a close of a closed menu is a
  /// no-op, and the shell plays no cue for it.
  bool close() {
    if (!isOpen) return false;
    isOpen = false;
    return true;
  }

  /// One D-pad step: `Up`/`Down` walk the rows, `Left`/`Right` move inside the
  /// status and emote rows and are inert on the single-target ones. Returns whether
  /// the step was vertical — the shell then scrolls the lit row into view.
  bool move(String direction) {
    switch (direction) {
      case 'Up':
        row = (row - 1).clamp(0, rowCount - 1);
        return true;
      case 'Down':
        row = (row + 1).clamp(0, rowCount - 1);
        return true;
      case 'Left':
        if (row == rowStatus) status = (status - 1).clamp(0, settableAvailabilities.length - 1);
        if (row == rowEmotes) emote = (emote - 1).clamp(0, gbEmotes.length - 1);
      case 'Right':
        if (row == rowStatus) status = (status + 1).clamp(0, settableAvailabilities.length - 1);
        if (row == rowEmotes) emote = (emote + 1).clamp(0, gbEmotes.length - 1);
    }
    return false;
  }

  /// What A would do on the lit row.
  GbMenuChoice get choice => switch (row) {
    rowStatus => GbChooseStatus(settableAvailabilities[status]),
    rowCamera => const GbChooseCamera(),
    rowEmotes => GbChooseEmote(gbEmotes[emote]),
    rowDial => const GbChooseTab(GbTab.dial),
    rowActivity => const GbChooseTab(GbTab.activity),
    rowPlans => const GbChooseTab(GbTab.plans),
    _ => const GbChooseTab(GbTab.settings),
  };

  Map<String, Object?> debugSnapshot() => {
    'open': isOpen,
    'row': _rowNames[row],
    'status': settableAvailabilities[status],
    'emote': gbEmotes[emote],
    'choice': choice.toJson(),
  };
}

/// What A does: choose in the menu, open the call during one, latch the cart
/// (boost) otherwise.
enum GbAAction { confirm, openCall, boost }

/// What B does: nothing in the menu (a stray mute would surprise); a plain mic
/// toggle with nobody in call distance; with somebody there, a tap that may turn
/// into a wave — [muteOrWave] when the mic is live (the first tap mutes at once),
/// [unmuteOrWave] when it is off (the unmute waits out the double-tap window).
enum GbBAction { inert, toggleMic, muteOrWave, unmuteOrWave }

/// What Start does: back out of the menu, or leave the conversation and walk home.
enum GbStartAction { closeMenu, goHome }

/// What the D-pad drives: the menu cursor, or your avatar.
enum GbDpadAction { cursor, walk }

/// Every key's meaning at one moment. Select always toggles the menu.
class GbButtonMap {
  const GbButtonMap({
    required this.a,
    required this.b,
    required this.start,
    required this.dpad,
    required this.dpadEnabled,
  });

  final GbAAction a;
  final GbBAction b;
  final GbStartAction start;
  final GbDpadAction dpad;

  /// Whether the pad takes a press at all: always in the menu, otherwise only when
  /// there is somewhere to walk.
  final bool dpadEnabled;

  Map<String, Object?> toJson() => {
    'a': a.name,
    'b': b.name,
    'select': 'toggleMenu',
    'start': start.name,
    'dpad': dpad.name,
    'dpadEnabled': dpadEnabled,
  };
}

/// The mapping the shell's keys are wired from. While the menu is open it owns the
/// keys — the D-pad is the cursor, A chooses, Start backs out, B goes inert — the
/// way a real handheld's buttons mean something else on a menu than in a game.
GbButtonMap gameboyButtons({
  required bool menuOpen,
  required bool inCall,
  required bool micOn,
  required bool waveReady,
  required bool canWalk,
}) => GbButtonMap(
  a: menuOpen
      ? GbAAction.confirm
      : inCall
      ? GbAAction.openCall
      : GbAAction.boost,
  b: menuOpen
      ? GbBAction.inert
      : !waveReady
      ? GbBAction.toggleMic
      : micOn
      ? GbBAction.muteOrWave
      : GbBAction.unmuteOrWave,
  start: menuOpen ? GbStartAction.closeMenu : GbStartAction.goHome,
  dpad: menuOpen ? GbDpadAction.cursor : GbDpadAction.walk,
  dpadEnabled: menuOpen || canWalk,
);

/// [gameboyButtons] read off [state]. "Wave ready" is somebody in call distance —
/// Gather's cluster, [AppState.huddleRows].
GbButtonMap gameboyButtonsFor(AppState state, {required bool menuOpen}) => gameboyButtons(
  menuOpen: menuOpen,
  inCall: state.inCall,
  micOn: state.call.micOn,
  waveReady: state.huddleRows.isNotEmpty,
  canWalk: state.canWalk,
);

/// What Start would do outside the menu, each only when there is one to do — the
/// dock's door, transcribed (`control_bar.dart`'s `_leave`). The shell asks again
/// after leaving the huddle, because the leave can change where you are.
({bool leaveHuddle, bool toDesk}) gameboyHomeSteps(AppState state) =>
    (leaveHuddle: state.inHuddle, toDesk: state.myDesk != null && !state.atMyDesk);

/// The one step a B tap takes, outside the menu.
enum GbBStep {
  /// Nobody to wave at: plain mute/unmute, instant.
  toggleMic,

  /// The second tap of a mute-then-wave: put the mic back silently and wave. Net:
  /// mic unchanged, wave sent.
  restoreMicAndWave,

  /// First tap while live: mute now (the safe direction) and arm the window for a
  /// second tap to turn the pair into a wave.
  muteAndArm,

  /// Second tap before a deferred unmute fired: cancel it and wave — you stay muted.
  cancelUnmuteAndWave,

  /// First tap while muted: hold the unmute back behind the window, where a second
  /// tap can still cancel it. The mic is never opened on the first tap.
  deferUnmute,
}

/// Decides B, split by direction so an unmute never fires on the first tap.
///
/// [muteArmed] is "a muting B tap landed inside the double-tap window"; it is
/// checked *before* [micOn], because the first tap mutes asynchronously and by the
/// second one `micOn` can already read false — branching on it first would route a
/// perfectly normal second tap into the mic-off path and schedule an unmute instead
/// of waving. The pending tap is the intent, and the only reliable witness that the
/// first tap was a mute. [unmutePending] is "a deferred unmute is waiting".
///
/// | waveReady | muteArmed | micOn | unmutePending | step |
/// |---|---|---|---|---|
/// | no  | –   | –   | –   | [GbBStep.toggleMic] |
/// | yes | yes | –   | –   | [GbBStep.restoreMicAndWave] |
/// | yes | no  | yes | –   | [GbBStep.muteAndArm] |
/// | yes | no  | no  | yes | [GbBStep.cancelUnmuteAndWave] |
/// | yes | no  | no  | no  | [GbBStep.deferUnmute] |
GbBStep decideBTap({
  required bool waveReady,
  required bool muteArmed,
  required bool micOn,
  required bool unmutePending,
}) {
  if (!waveReady) return GbBStep.toggleMic;
  if (muteArmed) return GbBStep.restoreMicAndWave;
  if (micOn) return GbBStep.muteAndArm;
  if (unmutePending) return GbBStep.cancelUnmuteAndWave;
  return GbBStep.deferUnmute;
}

/// A mounted shell, as the debug drive sees it: its menu, the mapping its keys are
/// wired from, and the shell's own handlers for Select, a D-pad step in the menu
/// and A in the menu — the exact callbacks the keys call, haptics and blips and
/// LCD toast included, so a drive press is a press and not a second path.
class GameboyShellDebug {
  GameboyShellDebug({
    required this.menu,
    required this.buttons,
    required this.toggleMenu,
    required this.moveMenu,
    required this.confirmMenu,
    this.onScreen = _always,
  });

  final GameboyMenu menu;
  final GbButtonMap Function() buttons;
  final void Function() toggleMenu;
  final void Function(String direction) moveMenu;
  final void Function() confirmMenu;

  /// Whether the shell is the tab on display. `HomeShell` keeps every tab alive in
  /// an `IndexedStack`, so a mounted shell is not necessarily a visible one — and a
  /// press on a handheld nobody can see (an outward confirm included) is not a press.
  final bool Function() onScreen;

  static bool _always() => true;
}

/// The shell on display, for the debug drive. Written by `GameboyShell` only under
/// `kDebugMode` (set on mount, cleared on dispose if still its own), so release
/// never writes it and the drive's reader shakes out with the drive.
GameboyShellDebug? gameboyDebugActive;
