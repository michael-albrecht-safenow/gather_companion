/// The office tab, re-housed as a handheld.
///
/// Gameboy mode changes two things and nothing else: the office is set inside a
/// moulded purple shell, and the controls move from the floating dock onto the
/// body as a D-pad and four buttons. Every button calls the exact same
/// [AppState] action the normal dock does — this file owns a *look* and an
/// *input surface*, not any behaviour of its own.
///
/// ## Why the screen is left alone
///
/// The office keeps its real colours. A true Gameboy would flatten it to four
/// greens, but the floor is the thing people read the room from, and a recolour
/// would cost legibility to buy nostalgia. So the shell is frame-only: the
/// purple palette below paints the body and its buttons, and [MapScreen] inside
/// the screen cut-out renders exactly as it always has.
///
/// ## The look is hardware, not a mobile app in a costume
///
/// The chrome follows a small "pixel console" grammar: a limited purple-plastic
/// palette, flat fills rather than soft gradients, and **hard** shadows — a solid
/// offset block, no blur — so every control reads as a moulded part you could
/// press with a thumbnail. The office world keeps its own pixel art inside the
/// screen; the shell around it is the console.
///
/// ## Why the D-pad is drawn here and not reused from `dpad.dart`
///
/// The movement *contract* is reused — a held pointer, direction from where the
/// thumb has slid to, `walk`/`stopWalking` on the way in and out — but the disc
/// in `dpad.dart` is glass over a floor, and this is a moulded cross on a plastic
/// body. The shape is the only difference, and it is the whole point here.
///
/// ## The LCD is a screen, so it carries a screen's furniture
///
/// Two things live *on* the LCD rather than over the whole device: a status strip
/// along its top (your Gather status, mic, camera, head count — the four things
/// worth knowing at a glance, drawn in the pixel grammar), and the Select menu, which
/// opens inside the screen instead of sliding a sheet over the plastic. Both are
/// the shell's own chrome; the office still renders underneath untouched. The
/// menu can be worked by thumb or by the hardware — the D-pad moves the highlight,
/// A chooses, Start backs out — because a handheld whose menu needs a touchscreen
/// is only half a handheld.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gather_client/gather_client.dart' show settableAvailabilities;

import '../src/app_state.dart';
import '../theme/gather_theme.dart' show availabilityColor, availabilityLabel, GatherThemeContext;

// The shell's own palette, kept deliberately apart from [GatherTokens]: the
// office inside the screen must stay the app's normal colours, so the retro
// purple lives only here and touches nothing the map draws with. The names echo
// the console design system — hardware plastic in one ramp, screen chrome in
// another, and a short semantic set for the lights.

// Hardware plastic: one purple ramp from deep shadow to bright highlight. The
// range is deliberately wide — the housing sits mid-ramp and the moulded
// controls (cross, pills, grille) sink to the near-black end, so a part always
// has a darker value to stand against. A control the same value as the body
// behind it reads as a hollow outline, which is the one thing to avoid.
const _hw990 = Color(0xFF160A2E); // the deepest: the drop under the cross, its sunk hub
const _hw950 = Color(0xFF241243); // near-black: the cross face and the hard drop under a part
const _hw900 = Color(0xFF35205F); // a dark moulded face — the pill slots
const _hw800 = Color(0xFF48287A); // the bezel and the recessed frame
const _hw700 = Color(0xFF63379A); // the main housing
const _hw600 = Color(0xFF7544B4); // a raised face, and the top-edge highlight
const _hw500 = Color(0xFF8B55C8); // the brightest catch of light on a dome
const _hw150 = Color(0xFFE6DAF7); // bright lavender-white: legible chrome text

// Neutral hardware greys. The D-pad and the SELECT/START keys are moulded in
// charcoal, not the body's purple — the console's one grey part, as the design
// system's neutral ramp specifies. Same grammar as the purple ramp: a dark
// surface, a deeper drop, a near-black outline, and a light label on top.
const _n950 = Color(0xFF11111A); // deepest: outline under the grey parts
const _n900 = Color(0xFF191923); // the hard drop under the D-pad and keys
const _n800 = Color(0xFF252531); // the dark moulded surface — cross face, key base
const _n700 = Color(0xFF343442); // the top-lit catch on a key
const _n300 = Color(0xFFA8A8B7); // primary hardware labels — the D-pad arrows
const _n200 = Color(0xFFC9C9D4); // pressed-state highlight detail

// Screen chrome: the near-black of the recessed well around the office.
const _scBlack = Color(0xFF11131C); // the screen frame
const _scMid = Color(0xFF292D40); // a row inside the menu
const _scBorder = Color(0xFF3C4054); // the thin bright line inside the bezel
const _scWhite = Color(0xFFF2F1F7); // primary text on the dark
const _scGlyphOff = Color(0xFF5A6072); // an off/idle status glyph on the LCD — dim, so "on" can glow past it

// Semantic lights.
const _online = Color(0xFF45D19A); // the one "on" accent — a live control glows it
const _danger = Color(0xFFEF5B67); // the power light
const _accentPink = Color(0xFFF05CA9); // the heart

/// The bundled pixel face, used for the shell's own labels and its menu and
/// nothing else — the office world keeps the system font (see `pubspec.yaml`).
/// Pixelify Sans has near-normal metrics and a real bold, so sizes here read
/// like ordinary type and lean on weight rather than the letter spacing a
/// monospace arcade face would have needed.
const _pixelFont = 'PixelifySans';

/// A pixel shadow: a solid block offset down, no blur. The signature of the
/// whole look — every moulded part casts one so it reads as sitting proud of the
/// body rather than painted onto it.
const _hardShadow = BoxShadow(color: _hw900, blurRadius: 0, offset: Offset(0, 4));

/// How wide the cross is. Each arm is then a target a thumb can hit without
/// looking, which is the point of a control used while watching the screen above it.
const double _dpadSize = 135;

/// Gather's eight, same codepoints and order as the dock's tray — the variation
/// selectors matter, so this list is copied rather than trimmed. See
/// `control_bar.dart`.
const _emotes = ['👋', '❤️', '🎉', '👍️', '🤣', '👏', '💯', '🔥'];

/// The Select menu's rows, in D-pad order top to bottom. Two of them — the
/// status choices and the emote strip — are rows the D-pad walks left/right
/// inside; the other three are single targets. Kept as a count so the cursor can
/// clamp without the menu and the router disagreeing about how many rows there are.
const int _menuRowStatus = 0;
const int _menuRowCamera = 1;
const int _menuRowEmotes = 2;
const int _menuRowActivity = 3;
const int _menuRowSettings = 4;
const int _menuRowCount = 5;

/// Wraps [child] (the office) in the handheld. [onOpenSettings]/[onOpenActivity]
/// are how the Select menu leaves for another tab — the shell cannot switch tabs
/// itself, so the home shell hands it the two it owns.
///
/// Stateful only for the Select menu: whether it is open, which row the cursor is
/// on, and which emote within the strip. Everything else is still a straight pass
/// to [AppState]. The menu state lives up here, above both the screen (which draws
/// the overlay) and the control deck (which, while the menu is open, points the
/// D-pad and the A/Start keys at it instead of at the office).
class GameboyShell extends StatefulWidget {
  const GameboyShell({
    super.key,
    required this.state,
    required this.child,
    required this.onOpenSettings,
    required this.onOpenActivity,
  });

  final AppState state;
  final Widget child;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenActivity;

  @override
  State<GameboyShell> createState() => _GameboyShellState();
}

class _GameboyShellState extends State<GameboyShell> {
  /// Whether the Select menu is open in the LCD. While true the control deck
  /// reroutes the hardware: the D-pad drives the cursor, A chooses, Start closes.
  bool _menuOpen = false;

  /// Which menu row the cursor is on (`_menuRow*`), and the sub-position within
  /// the two rows that have one: which status choice, and which emote. Both
  /// survive leaving and re-entering their strip, which is what a thumb expects.
  int _row = _menuRowStatus;
  int _status = 0;
  int _emote = 0;

  /// One key per menu row (`_menuRow*`). The LCD is short enough that Settings can
  /// sit below the fold, so a D-pad move has to scroll the lit row back into the
  /// well — otherwise the highlight walks off-screen and A fires a row nobody can
  /// see. The keys hang on the rows in [_GameboyMenu]; [_revealRow] rides them.
  final List<GlobalKey> _rowKeys = List.generate(_menuRowCount, (_) => GlobalKey());

  /// Scroll the focused row into view after a vertical move. Every row is built
  /// eagerly inside the menu's scroll view, so the context is already there; the
  /// post-frame hop just waits for the highlight's setState to lay out first.
  void _revealRow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _rowKeys[_row].currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  void _toggleMenu() {
    HapticFeedback.selectionClick();
    setState(() {
      _menuOpen = !_menuOpen;
      if (_menuOpen) {
        // Open on the status row with its cursor already on the status you are,
        // so the first thing the menu offers is a one-press change away from it.
        _row = _menuRowStatus;
        final at = settableAvailabilities.indexOf(widget.state.myAvailability ?? 'Active');
        _status = at < 0 ? 0 : at;
      }
    });
  }

  void _closeMenu() {
    if (!_menuOpen) return;
    HapticFeedback.selectionClick();
    setState(() => _menuOpen = false);
  }

  /// One D-pad step while the menu is open. Up/Down walk the rows; Left/Right move
  /// inside the emote strip and are inert on the single-target rows — the same
  /// clamp-at-the-ends feel the office's walk has when it meets a wall.
  void _move(String direction) {
    setState(() {
      switch (direction) {
        case 'Up':
          _row = (_row - 1).clamp(0, _menuRowCount - 1);
          _revealRow();
        case 'Down':
          _row = (_row + 1).clamp(0, _menuRowCount - 1);
          _revealRow();
        case 'Left':
          if (_row == _menuRowStatus) _status = (_status - 1).clamp(0, settableAvailabilities.length - 1);
          if (_row == _menuRowEmotes) _emote = (_emote - 1).clamp(0, _emotes.length - 1);
        case 'Right':
          if (_row == _menuRowStatus) _status = (_status + 1).clamp(0, settableAvailabilities.length - 1);
          if (_row == _menuRowEmotes) _emote = (_emote + 1).clamp(0, _emotes.length - 1);
      }
    });
    HapticFeedback.selectionClick();
  }

  /// Puts a refusal in front of the person, the app's one existing way: an action
  /// returns null on success or a sentence to show. The messenger is captured
  /// before the await because the press may have moved on by the time it answers.
  Future<void> _run(Future<String?> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    final failed = await action();
    if (failed == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failed)));
  }

  // The four menu actions, shared by a thumb tapping a row and the A button
  // choosing the highlighted one. Camera and a reaction do their thing and close;
  // Activity and Settings hand back to the home shell, which switches tab (that
  // tab switch takes the handheld off screen, so there is nothing left to close).
  void _doStatus(String availability) {
    _closeMenu();
    _run(() => widget.state.setAvailability(availability));
  }

  void _doCamera() {
    _closeMenu();
    _run(() => widget.state.setCameraOn(!widget.state.call.cameraOn));
  }

  void _doReact(String emote) {
    _closeMenu();
    _run(() => widget.state.sendEmoteLocalFirst(emote));
  }

  void _doActivity() {
    _closeMenu();
    widget.onOpenActivity();
  }

  void _doSettings() {
    _closeMenu();
    widget.onOpenSettings();
  }

  /// A press of the A button while the menu is open: do whatever the cursor is on.
  void _confirm() {
    switch (_row) {
      case _menuRowStatus:
        _doStatus(settableAvailabilities[_status]);
      case _menuRowCamera:
        _doCamera();
      case _menuRowEmotes:
        _doReact(_emotes[_emote]);
      case _menuRowActivity:
        _doActivity();
      case _menuRowSettings:
        _doSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // A top-lit mid-purple body: a short highlight along the top edge, then the
      // housing holds one mid value all the way down. It must *not* darken into
      // the controls' own value — a cross or a pill the same purple as the body
      // behind it reads as a hollow outline, which is exactly the washed-out look
      // this replaces.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_hw600, _hw700, _hw700],
          stops: [0, 0.22, 1],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Column(
            children: [
              Expanded(
                child: _Screen(
                  state: widget.state,
                  // The Select menu is the screen's overlay, not the device's: it
                  // is handed in here so it clips to the LCD well and leaves the
                  // plastic body showing around it.
                  menu: _menuOpen
                      ? _GameboyMenu(
                          state: widget.state,
                          rowKeys: _rowKeys,
                          focusedRow: _row,
                          focusedStatus: _status,
                          focusedEmote: _emote,
                          onStatus: _doStatus,
                          onCamera: _doCamera,
                          onReact: _doReact,
                          onActivity: _doActivity,
                          onSettings: _doSettings,
                          onDismiss: _closeMenu,
                        )
                      : null,
                  child: widget.child,
                ),
              ),
              // The purple band between the screen and the controls. Measured off
              // the mock: the gap there is ~10% of the screen width, which lands at
              // ~40 logical pixels on a phone — a deliberate breath between the LCD
              // and the D-pad, not the tight 8px of before.
              const SizedBox(height: 40),
              _ControlsDeck(
                state: widget.state,
                menuOpen: _menuOpen,
                onMenuMove: _move,
                onMenuConfirm: _confirm,
                onMenuClose: _closeMenu,
                onMenuToggle: _toggleMenu,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The strip across the top of the screen bezel: the room's name on the left as
/// the console's wordmark, the power light on the right — the two things moulded
/// into the top of a real one. It sits *inside* the dark purple surround, above
/// the LCD well, so the bezel reads as wider along the top the way the mock's
/// does. The name is taken *off* the LCD title so it is not printed twice (see
/// `map_screen.dart`). The head count is the LCD's job, carried on the status
/// strip inside the screen.
class _Header extends StatelessWidget {
  const _Header({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    // Listens on [state] alone: the name comes from the space, which only the
    // self plane changes, not a walk.
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
          child: Row(
            children: [
              const Icon(Icons.favorite, color: _accentPink, size: 18),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  state.spaceName ?? 'The office',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _pixelFont,
                    fontWeight: FontWeight.w700,
                    color: _hw150,
                    fontSize: 19,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: _danger,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: _danger, blurRadius: 6, spreadRadius: 1),
                  ],
                ),
              ),
              const SizedBox(width: 7),
              const Text(
                'POWER',
                style: TextStyle(
                  fontFamily: _pixelFont,
                  fontWeight: FontWeight.w700,
                  color: _hw150,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The LCD's own status strip, along the top of the screen well on the black.
///
/// It answers the four things worth knowing without opening anything: your Gather
/// status (Active, Busy, Away), whether the mic is live, whether the camera is
/// live, and how many people are in the room. The status is a coloured dot and its
/// name, the same value the rest of the app draws (`availabilityColor` /
/// `availabilityLabel`) but re-cut in the pixel face; the mic and camera are glyphs
/// that glow the live-green when on and sit dim when off; the head count is the
/// same pill the normal app bar carried. Drawn here rather than in the map's app
/// bar (which stands down in Gameboy mode) so the whole strip is one pixel-styled
/// thing the shell owns — and the status can be changed from the Select menu, so
/// what this shows is a live readout of a setting one press away.
class _LcdStatusBar extends StatelessWidget {
  const _LcdStatusBar({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final call = state.call;
        // "Here" counts the office, me included — the same sum the map's own chip
        // makes, kept in step by using the same two fields rather than a second
        // getter that could drift.
        final present = state.peopleOnMap.length + (state.mePerson == null ? 0 : 1);

        return Padding(
          padding: const EdgeInsets.fromLTRB(3, 1, 3, 1),
          child: Row(
            children: [
              _StatusReadout(availability: state.myAvailability ?? 'Active'),
              const SizedBox(width: 12),
              _StatusGlyph(
                icon: call.micOn ? Icons.mic : Icons.mic_off,
                colour: call.micOn ? _online : _scGlyphOff,
                label: call.micOn ? 'Microphone on' : 'Microphone off',
              ),
              const SizedBox(width: 11),
              _StatusGlyph(
                icon: call.cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                colour: call.cameraOn ? _online : _scGlyphOff,
                label: call.cameraOn ? 'Camera on' : 'Camera off',
              ),
              const Spacer(),
              // The follower count, carried onto the LCD so Gameboy mode keeps the
              // app's core signal — somebody is watching you move. Shown only when
              // there is one, the way the map's app bar leads with it, and set
              // before the head count so the pill that is always there never shifts.
              if (state.followers.isNotEmpty) ...[
                _FollowerChip(count: state.followers.length),
                const SizedBox(width: 8),
              ],
              _HeadCountChip(present: present),
            ],
          ),
        );
      },
    );
  }
}

/// Your Gather status on the LCD: a dot in the status's own colour and its name
/// in the pixel face. The colour and the wording are the app's — `availabilityColor`
/// and `availabilityLabel`, so nobody has to learn a second vocabulary — only the
/// type is themed.
class _StatusReadout extends StatelessWidget {
  const _StatusReadout({required this.availability});

  final String availability;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Status: ${availabilityLabel(availability)}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: availabilityColor(context.tokens, availability),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            availabilityLabel(availability),
            style: const TextStyle(
              fontFamily: _pixelFont,
              fontWeight: FontWeight.w700,
              color: _scWhite,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// One status glyph: an icon that carries its meaning in its colour, with the
/// meaning spoken for a screen reader so the colour is not the only channel.
class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.icon, required this.colour, required this.label});

  final IconData icon;
  final Color colour;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: Icon(icon, size: 18, color: colour),
    );
  }
}

/// The head count, re-cut for the LCD: the same "N here" pill the map's app bar
/// carried, in the pixel face on the screen's dark. The dot glows the live-green
/// when anyone is in, so an empty room reads at a glance too.
class _HeadCountChip extends StatelessWidget {
  const _HeadCountChip({required this.present});

  final int present;

  @override
  Widget build(BuildContext context) {
    final here = present > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _scMid,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _scBorder, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: here ? _online : _scGlyphOff,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$present here',
            style: const TextStyle(
              fontFamily: _pixelFont,
              fontWeight: FontWeight.w700,
              color: _scWhite,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// The follower count, re-cut for the LCD: the eye the map's app bar spoke as a
/// tinted pill, redrawn in the pixel face on the screen's dark so Gameboy mode
/// still shows that someone is following you. Lit green like the live glyphs,
/// because a follower is always someone currently watching.
class _FollowerChip extends StatelessWidget {
  const _FollowerChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: count == 1 ? 'One person is following you' : '$count people are following you',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _scMid,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: _scBorder, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.visibility, size: 13, color: _online),
              const SizedBox(width: 6),
              Text(
                '$count',
                style: const TextStyle(
                  fontFamily: _pixelFont,
                  fontWeight: FontWeight.w700,
                  color: _scWhite,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The recessed screen: a raised purple lip that carries the header along its
/// top, a near-black well with a thin bright inner line, and the office clipped
/// inside it. The bezel is wider at the top — the header (room name + power light)
/// lives in that band — so the dark purple reads as a deeper surround above the
/// LCD, the way the mock draws it. The bottom padding the shell adds for its
/// vanished nav rail is stripped on the well, so the map's own legend sits snug to
/// the screen's edge rather than floating a rail's height above it.
///
/// Inside the well, the office is topped by the [_LcdStatusBar] and may be covered
/// by the Select [menu] — both are the screen's furniture and so clip to it,
/// leaving the plastic body around the screen untouched.
class _Screen extends StatelessWidget {
  const _Screen({required this.state, required this.child, this.menu});

  final AppState state;
  final Widget child;

  /// The Select menu overlay, or null when it is closed. Drawn over the office,
  /// inside the LCD.
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    return Container(
      // The moulded lip around the well: a dark bezel, darker than the mid-purple
      // body so the screen reads as sunk into the console rather than laid on top
      // of it. Wider at the top (the header sits there) than on the other three
      // sides. It still catches a little light along the top and falls to shadow
      // at the bottom, and casts the same hard drop the buttons do. The gradient,
      // not per-side borders, because a rounded corner needs one border colour
      // all the way round.
      padding: const EdgeInsets.fromLTRB(6, 7, 6, 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_hw800, _hw900],
        ),
        borderRadius: BorderRadius.all(Radius.circular(14)),
        border: Border.fromBorderSide(BorderSide(color: _hw950, width: 1.5)),
        boxShadow: [_hardShadow],
      ),
      child: Column(
        children: [
          _Header(state: state),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              // The black well, with the thin bright line the real ones have just
              // inside the bezel.
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _scBlack,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: _scBorder, width: 1.5),
              ),
              child: Column(
                children: [
                  _LcdStatusBar(state: state),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: MediaQuery.removePadding(
                              context: context,
                              removeBottom: true,
                              child: child,
                            ),
                          ),
                          // The menu rides over the office, inside the LCD. An
                          // AnimatedSwitcher so it fades in and out rather than
                          // snapping — the one soft touch on a hard-edged face,
                          // bought because an instant full-screen flip of the LCD
                          // reads as a glitch.
                          Positioned.fill(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 160),
                              child: menu ?? const SizedBox.shrink(key: ValueKey('gb-menu-closed')),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Everything on the body below the screen. Rebuilt on [AppState] so the mic and
/// cart buttons show their live state, and on [AppState.positions] so the D-pad
/// dims exactly when there is nowhere to walk — the same two listenables the
/// normal dock splits its controls across.
///
/// While the Select menu is open ([menuOpen]) the deck quietly repoints the
/// hardware at it: the D-pad becomes the cursor, A chooses, Start backs out, and B
/// goes inert. The menu owns the meaning of the keys for as long as it is up, the
/// way a real handheld's buttons mean different things on a menu than in a game.
class _ControlsDeck extends StatelessWidget {
  const _ControlsDeck({
    required this.state,
    required this.menuOpen,
    required this.onMenuMove,
    required this.onMenuConfirm,
    required this.onMenuClose,
    required this.onMenuToggle,
  });

  final AppState state;
  final bool menuOpen;
  final void Function(String direction) onMenuMove;
  final VoidCallback onMenuConfirm;
  final VoidCallback onMenuClose;
  final VoidCallback onMenuToggle;

  /// Puts a refusal in front of the person, the app's one existing way: an action
  /// returns null on success or a sentence to show. The messenger is captured
  /// before the await because the press may have moved on by the time it answers.
  Future<void> _run(BuildContext context, Future<String?> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    final failed = await action();
    if (failed == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failed)));
  }

  /// Start: leave the conversation and walk home, each only when there is one to
  /// do — the dock's door, transcribed. See `control_bar.dart`'s `_leave`.
  Future<void> _goHome(BuildContext context) async {
    if (state.inHuddle) {
      await _run(context, state.leaveHuddle);
    }
    if (state.myDesk != null && !state.atMyDesk) {
      if (!context.mounted) return;
      await _run(context, state.goToMyDesk);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final call = state.call;
        // Two packed zones rather than one tall box with the keys pinned to its
        // edges: the cross and the A/B pair share an upper band, the SELECT/START
        // pair and the grille a lower one, with no dead plastic in between. The
        // buttons sit low against the cross's centre so the right of the body fills
        // the way the left does.
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _dpadSize,
              child: Stack(
                children: [
                  // D-pad, bottom-left. In the office it walks and dims when there
                  // is nowhere to go; while the menu is up it drives the cursor
                  // instead and is always live, because there is always a row to
                  // move to.
                  Positioned(
                    left: 2,
                    top: 0,
                    child: ListenableBuilder(
                      listenable: state.positions,
                      builder: (context, _) => _GbDpad(
                        key: const Key('gb-dpad'),
                        enabled: menuOpen || state.canWalk,
                        onPress: menuOpen ? onMenuMove : state.walk,
                        onRelease: menuOpen ? () {} : state.stopWalking,
                      ),
                    ),
                  ),
                  // A, raised and to the right: the cart, or — in the menu — the
                  // choose key. Lit while the cart is latched on; plain in the menu.
                  Positioned(
                    right: 18,
                    top: 30,
                    child: _GbRoundButton(
                      label: 'A',
                      size: 64,
                      lit: !menuOpen && state.boost,
                      onTap: menuOpen
                          ? onMenuConfirm
                          : () {
                              HapticFeedback.selectionClick();
                              state.boost = !state.boost;
                            },
                    ),
                  ),
                  // B, below and left of A: mute. Lit means the mic is live, so the
                  // button glows when you are the one being heard. Inert in the
                  // menu — it has no job there, and a stray mute mid-menu surprises.
                  Positioned(
                    right: 98,
                    top: 66,
                    child: _GbRoundButton(
                      label: 'B',
                      size: 64,
                      lit: !menuOpen && call.micOn,
                      onTap: menuOpen ? null : () => _run(context, () => state.setMicOn(!call.micOn)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Select and Start, the flat horizontal pair centred, with the moulded
            // grille tucked into the corner beside them.
            SizedBox(
              height: 64,
              child: Stack(
                children: [
                  const Positioned(
                    right: 10,
                    bottom: 2,
                    child: _SpeakerGrille(),
                  ),
                  Positioned.fill(
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Select opens the menu, and closes it again — a thumb
                          // that opened it reaches for the same key to put it away.
                          _GbPill(label: 'SELECT', onTap: onMenuToggle),
                          const SizedBox(width: 22),
                          // Start goes home in the office, and backs out of the menu
                          // while it is up.
                          _GbPill(label: 'START', onTap: menuOpen ? onMenuClose : () => _goHome(context)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A moulded cross that walks while a thumb is on it. Reuses the disc pad's
/// contract: direction is read from wherever the thumb has slid to, handed over
/// on a change and released on lift, so corners are a roll rather than four
/// separate presses.
class _GbDpad extends StatefulWidget {
  const _GbDpad({
    super.key,
    required this.enabled,
    required this.onPress,
    required this.onRelease,
  });

  final bool enabled;
  final void Function(String direction) onPress;
  final VoidCallback onRelease;

  @override
  State<_GbDpad> createState() => _GbDpadState();
}

class _GbDpadState extends State<_GbDpad> {
  String? _held;

  /// Which arm a touch at [local] asks for, or null for the still centre. The
  /// diagonals split evenly, as the disc pad's do, so a thumb rolling from one
  /// arm to the next hands over where it looks like it should.
  String? _directionAt(Offset local) {
    final centre = _dpadSize / 2;
    final dx = local.dx - centre;
    final dy = local.dy - centre;
    final dead = _dpadSize * 0.18;
    if (dx.abs() < dead && dy.abs() < dead) return null;
    if (dx.abs() > dy.abs()) return dx > 0 ? 'Right' : 'Left';
    return dy > 0 ? 'Down' : 'Up';
  }

  void _to(String? direction) {
    if (direction == _held) return;
    setState(() => _held = direction);
    if (direction == null) {
      widget.onRelease();
      return;
    }
    HapticFeedback.selectionClick();
    widget.onPress(direction);
  }

  void _lift() {
    if (_held == null) return;
    setState(() => _held = null);
    widget.onRelease();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: widget.enabled ? (e) => _to(_directionAt(e.localPosition)) : null,
      onPointerMove: widget.enabled ? (e) => _to(_directionAt(e.localPosition)) : null,
      onPointerUp: (_) => _lift(),
      onPointerCancel: (_) => _lift(),
      child: SizedBox(
        width: _dpadSize,
        height: _dpadSize,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(painter: _CrossPainter(held: _held, enabled: widget.enabled)),
            ),
            // A tap target per arm, for a screen reader — the pad itself is one
            // held pointer, so the honest meaning of a semantic tap is a single
            // step, as the disc pad in `dpad.dart` resolves it too.
            for (final arm in const [
              (direction: 'Up', x: 0.0, y: -0.72),
              (direction: 'Down', x: 0.0, y: 0.72),
              (direction: 'Left', x: -0.72, y: 0.0),
              (direction: 'Right', x: 0.72, y: 0.0),
            ])
              Align(
                alignment: Alignment(arm.x, arm.y),
                child: Semantics(
                  button: true,
                  enabled: widget.enabled,
                  label: 'Walk ${arm.direction.toLowerCase()}',
                  onTap: widget.enabled
                      ? () {
                          widget.onPress(arm.direction);
                          widget.onRelease();
                        }
                      : null,
                  child: const SizedBox(width: 46, height: 46),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CrossPainter extends CustomPainter {
  _CrossPainter({required this.held, required this.enabled});

  final String? held;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final arm = size.width * 0.40;
    const radius = Radius.circular(4); // chunky, near-square — moulded, not glass
    final vertical = RRect.fromRectAndRadius(
      Rect.fromCenter(center: centre, width: arm, height: size.height),
      radius,
    );
    final horizontal = RRect.fromRectAndRadius(
      Rect.fromCenter(center: centre, width: size.width, height: arm),
      radius,
    );

    // One plus-shaped silhouette. Filling and outlining the *union* — not each arm
    // on its own — means no fill seam or outline line is ever drawn across the
    // centre, so the old tic-tac-toe look is gone: the cross is a single moulded
    // part with nothing inside it.
    final cross = Path.combine(
      PathOperation.union,
      Path()..addRRect(vertical),
      Path()..addRRect(horizontal),
    );

    // The hard drop: a solid grey block offset down, no blur.
    final shadow = Paint()..color = _n900.withValues(alpha: enabled ? 1 : 0.4);
    canvas.drawPath(cross.shift(const Offset(0, 4)), shadow);

    // The moulded cross: one flat charcoal fill — the console's grey part, not the
    // body's purple — so the light grey arrows read against it. Two colours, a
    // solid plus, and no hub, square, or bevel bar in the middle.
    final face = Paint()..color = enabled ? _n800 : _n800.withValues(alpha: 0.5);
    canvas.drawPath(cross, face);

    // A single silhouette outline around the whole plus — one near-black edge, no
    // line crossing the centre.
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = _n950.withValues(alpha: enabled ? 1 : 0.4);
    canvas.drawPath(cross, outline);

    _arrow(canvas, size, 'Up');
    _arrow(canvas, size, 'Down');
    _arrow(canvas, size, 'Left');
    _arrow(canvas, size, 'Right');
  }

  void _arrow(Canvas canvas, Size size, String direction) {
    final centre = Offset(size.width / 2, size.height / 2);
    final reach = size.width * 0.34;
    final s = size.width * 0.088;
    final lit = held == direction;
    final paint = Paint()
      ..color = lit
          ? _n200
          : _n300.withValues(alpha: enabled ? 0.95 : 0.4);

    final (dx, dy) = switch (direction) {
      'Up' => (0.0, -1.0),
      'Down' => (0.0, 1.0),
      'Left' => (-1.0, 0.0),
      _ => (1.0, 0.0),
    };
    final tip = centre + Offset(dx * reach, dy * reach);
    // Perpendicular, for the two base corners.
    final perp = Offset(-dy, dx);
    final path = Path()
      ..moveTo(tip.dx + dx * s, tip.dy + dy * s)
      ..lineTo(tip.dx + perp.dx * s, tip.dy + perp.dy * s)
      ..lineTo(tip.dx - perp.dx * s, tip.dy - perp.dy * s)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CrossPainter old) => old.held != held || old.enabled != enabled;
}

/// One round button, A or B. Pressed is a push down into its own shadow rather
/// than a colour change; lit rings the button in the live-green accent for a
/// control that is currently *on*. A null [onTap] is the button's disabled state —
/// it still draws, so the face stays where a thumb expects it, but does nothing.
class _GbRoundButton extends StatefulWidget {
  const _GbRoundButton({
    required this.label,
    required this.size,
    required this.lit,
    required this.onTap,
  });

  final String label;
  final double size;
  final bool lit;
  final VoidCallback? onTap;

  @override
  State<_GbRoundButton> createState() => _GbRoundButtonState();
}

class _GbRoundButtonState extends State<_GbRoundButton> {
  bool _down = false;

  void _set(bool down) {
    if (_down == down) return;
    setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final lit = widget.lit;
    return Semantics(
      button: true,
      toggled: lit,
      label: widget.label,
      child: GestureDetector(
        onTapDown: widget.onTap == null ? null : (_) => _set(true),
        onTapUp: widget.onTap == null ? null : (_) => _set(false),
        onTapCancel: widget.onTap == null ? null : () => _set(false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _down ? 3 : 0, 0),
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // A matte moulded face with only a soft top sheen — not the glassy
            // candy highlight a strong radial gives. The mock's buttons are flat
            // plastic with the letter engraved into them, so the dome is gentle
            // (one step of light near the top) and the depth comes from the hard
            // drop below, not from gloss.
            gradient: const RadialGradient(
              center: Alignment(-0.25, -0.35),
              radius: 1.05,
              colors: [_hw500, _hw600],
            ),
            border: Border.all(color: lit ? _online : _hw950, width: 3),
            boxShadow: [
              // The hard drop — a deeper, more offset block than a soft shadow, so
              // the key reads as sitting proud of the body; it closes up on press.
              BoxShadow(color: _hw950, blurRadius: 0, offset: Offset(0, _down ? 2 : 7)),
              if (lit) const BoxShadow(color: _online, blurRadius: 10, spreadRadius: 0),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // A thin inner ring when on, so the live state reads even past a
              // thumb sitting on the button.
              if (lit)
                Container(
                  margin: EdgeInsets.all(widget.size * 0.15),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _online, width: 2),
                  ),
                ),
              Text(
                widget.label,
                style: TextStyle(
                  fontFamily: _pixelFont,
                  fontWeight: FontWeight.w700,
                  // Dark and engraved into the lit dome when idle, the way the
                  // mock prints its A/B; white only when the control is live.
                  color: lit ? _scWhite : _hw900,
                  fontSize: widget.size * 0.42,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A Select or Start key: a flat horizontal pill, dark plastic on a hard shadow,
/// with its name under it.
class _GbPill extends StatefulWidget {
  const _GbPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_GbPill> createState() => _GbPillState();
}

class _GbPillState extends State<_GbPill> {
  bool _down = false;

  void _set(bool down) {
    if (_down == down) return;
    setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(0, _down ? 2 : 0, 0),
              width: 50,
              height: 16,
              decoration: BoxDecoration(
                // A flat, perfectly horizontal key — long axis across, never
                // tilted, the way the mock lays the pair out. Moulded in charcoal
                // grey like the D-pad, not the body's purple, with a touch of light
                // along the top as a gradient so the rounded ends keep a single
                // border colour.
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_n700, _n800],
                ),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: _n950, width: 1),
                boxShadow: [
                  BoxShadow(color: _n900, blurRadius: 0, offset: Offset(0, _down ? 1 : 3)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.label,
              style: const TextStyle(
                fontFamily: _pixelFont,
                fontWeight: FontWeight.w700,
                // Dark grey, engraved into the body like the keys they name — not
                // the lavender chrome text.
                color: _n700,
                fontSize: 13,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The moulded grille in the corner. Identical upright slots — every one the same
/// length and width, each perfectly vertical — stepped up to the right so the
/// block reads as an angled speaker moulding while no single slot is itself
/// slanted, the way the mock draws it. Hidden from the reader: it is decoration,
/// not a control.
class _SpeakerGrille extends StatelessWidget {
  const _SpeakerGrille();

  @override
  Widget build(BuildContext context) {
    return const ExcludeSemantics(
      child: SizedBox(
        width: 74,
        height: 60,
        child: CustomPaint(painter: _GrillePainter()),
      ),
    );
  }
}

class _GrillePainter extends CustomPainter {
  const _GrillePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _hw990
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    const count = 6;
    const barLen = 32.0; // every slot the same height
    const stepX = 11.0; // march to the right
    const stepY = 3.0; // and climb, so the cluster reads as an angled moulding
    for (var i = 0; i < count; i++) {
      final x = 8 + i * stepX;
      final bottom = size.height - 4 - i * stepY;
      // A straight up-and-down slot: same endpoints' x, so it is never angled —
      // only its position moves, in both axes.
      canvas.drawLine(Offset(x, bottom), Offset(x, bottom - barLen), paint);
    }
  }

  @override
  bool shouldRepaint(_GrillePainter old) => false;
}

/// The Select menu, drawn inside the LCD: the controls that are not one of the
/// four physical buttons, worked by thumb or by the hardware. A scrim dims the
/// office behind it (tap it to close), and the rows carry a cursor the D-pad
/// moves — [focusedRow] is which row is lit, [focusedEmote] which emote within the
/// strip. Camera and the eight reactions do their thing and close; Settings and
/// Activity hand back to the home shell, which switches tab.
class _GameboyMenu extends StatelessWidget {
  const _GameboyMenu({
    required this.state,
    required this.rowKeys,
    required this.focusedRow,
    required this.focusedStatus,
    required this.focusedEmote,
    required this.onStatus,
    required this.onCamera,
    required this.onReact,
    required this.onActivity,
    required this.onSettings,
    required this.onDismiss,
  });

  final AppState state;

  /// One key per row (`_menuRow*`), owned by the shell so a D-pad move can scroll
  /// the lit row back into the LCD well.
  final List<GlobalKey> rowKeys;
  final int focusedRow;
  final int focusedStatus;
  final int focusedEmote;
  final ValueChanged<String> onStatus;
  final VoidCallback onCamera;
  final ValueChanged<String> onReact;
  final VoidCallback onActivity;
  final VoidCallback onSettings;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cameraOn = state.call.cameraOn;
    return Stack(
      key: const ValueKey('gb-menu-open'),
      children: [
        // The scrim: the office dimmed, not hidden, so the menu reads as laid over
        // the room rather than a different screen. Tapping it is the touch way out.
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            child: const ColoredBox(color: Color(0xD011131C)),
          ),
        ),
        Positioned.fill(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KeyedSubtree(
                  key: rowKeys[_menuRowStatus],
                  child: _StatusStrip(
                    current: state.myAvailability ?? 'Active',
                    focused: focusedRow == _menuRowStatus,
                    focusedStatus: focusedStatus,
                    onStatus: onStatus,
                  ),
                ),
                const SizedBox(height: 8),
                KeyedSubtree(
                  key: rowKeys[_menuRowCamera],
                  child: _MenuRow(
                    icon: cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                    lit: cameraOn,
                    focused: focusedRow == _menuRowCamera,
                    title: cameraOn ? 'Turn the camera off' : 'Turn the camera on',
                    onTap: onCamera,
                  ),
                ),
                const SizedBox(height: 8),
                KeyedSubtree(
                  key: rowKeys[_menuRowEmotes],
                  child: _EmoteStrip(
                    focused: focusedRow == _menuRowEmotes,
                    focusedEmote: focusedEmote,
                    onReact: onReact,
                  ),
                ),
                const SizedBox(height: 8),
                KeyedSubtree(
                  key: rowKeys[_menuRowActivity],
                  child: _MenuRow(
                    icon: Icons.notifications_rounded,
                    title: 'Activity',
                    focused: focusedRow == _menuRowActivity,
                    onTap: onActivity,
                  ),
                ),
                const SizedBox(height: 8),
                KeyedSubtree(
                  key: rowKeys[_menuRowSettings],
                  child: _MenuRow(
                    icon: Icons.settings_rounded,
                    title: 'Settings',
                    focused: focusedRow == _menuRowSettings,
                    onTap: onSettings,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The three Gather statuses as a row, each a dot in its own colour over its name.
/// The one you are on wears a filled tint (the app's selected-state recipe); the
/// cursor rings whichever the D-pad is over, so A sets the obvious one. A thumb can
/// tap any of them directly. This is the menu's only way to *change* status — the
/// strip on the LCD above only reports it.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.current,
    required this.focused,
    required this.focusedStatus,
    required this.onStatus,
  });

  /// The status you are, so the matching cell reads as selected.
  final String current;
  final bool focused;
  final int focusedStatus;
  final ValueChanged<String> onStatus;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        color: _scMid,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: focused ? _online : _scBorder, width: focused ? 2 : 1.5),
      ),
      child: Row(
        children: [
          for (var i = 0; i < settableAvailabilities.length; i++)
            Expanded(
              child: Builder(builder: (context) {
                final availability = settableAvailabilities[i];
                final colour = availabilityColor(t, availability);
                final selected = availability == current;
                final onCursor = focused && i == focusedStatus;
                return Semantics(
                  button: true,
                  selected: selected,
                  label: 'Set status to ${availabilityLabel(availability)}',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onStatus(availability),
                    child: Container(
                      height: 44,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        // The one you are wears a wash of its own colour; the cursor
                        // rings whichever cell it is over.
                        color: selected ? colour.withValues(alpha: 0.16) : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: onCursor ? _online : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            availabilityLabel(availability),
                            style: const TextStyle(
                              fontFamily: _pixelFont,
                              fontWeight: FontWeight.w700,
                              color: _scWhite,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
        ],
      ),
    );
  }
}

/// The eight reactions, divided across the row like the dock's tray. The strip
/// lights its border when the cursor is on it, and rings the one emote the cursor
/// sits on, so A sends the obvious one; a thumb can still tap any of them.
class _EmoteStrip extends StatelessWidget {
  const _EmoteStrip({
    required this.focused,
    required this.focusedEmote,
    required this.onReact,
  });

  final bool focused;
  final int focusedEmote;
  final ValueChanged<String> onReact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      decoration: BoxDecoration(
        color: _scMid,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: focused ? _online : _scBorder, width: focused ? 2 : 1.5),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _emotes.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                label: 'Send ${_emotes[i]}',
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => onReact(_emotes[i]),
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      // The cursor's ring, only while the strip is the focused row.
                      border: Border.all(
                        color: focused && i == focusedEmote ? _online : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: Center(child: Text(_emotes[i], style: const TextStyle(fontSize: 22))),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.lit = false,
    this.focused = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  /// The control is currently on (camera live) — tints it the live-green.
  final bool lit;

  /// The D-pad cursor is on this row — rings it so A's target is unmistakable.
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final colour = lit ? _online : _scWhite;
    return Material(
      color: _scMid,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            // A bright ring when the cursor is here, the bezel line otherwise.
            border: Border.all(color: focused ? _online : _scBorder, width: focused ? 2 : 1.5),
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 22, color: colour),
              const SizedBox(width: 14),
              Text(
                title,
                style: TextStyle(
                  fontFamily: _pixelFont,
                  color: colour,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
