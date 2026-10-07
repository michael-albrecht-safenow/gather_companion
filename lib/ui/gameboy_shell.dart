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
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/app_state.dart';

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
const _scDark = Color(0xFF191C29); // the menu surface
const _scMid = Color(0xFF292D40); // a row inside the menu
const _scBorder = Color(0xFF3C4054); // the thin bright line inside the bezel
const _scWhite = Color(0xFFF2F1F7); // primary text on the dark

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

/// Wraps [child] (the office) in the handheld. [onOpenSettings]/[onOpenActivity]
/// are how the Select menu leaves for another tab — the shell cannot switch tabs
/// itself, so the home shell hands it the two it owns.
class GameboyShell extends StatelessWidget {
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
              Expanded(child: _Screen(state: state, child: child)),
              // The purple band between the screen and the controls. Measured off
              // the mock: the gap there is ~10% of the screen width, which lands at
              // ~40 logical pixels on a phone — a deliberate breath between the LCD
              // and the D-pad, not the tight 8px of before.
              const SizedBox(height: 40),
              _ControlsDeck(
                state: state,
                onOpenSettings: onOpenSettings,
                onOpenActivity: onOpenActivity,
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
/// `map_screen.dart`). The head count is the LCD's job, carried on the "N here"
/// chip inside the screen.
class _Header extends StatelessWidget {
  const _Header({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    // Listens on [state] alone: the name comes from the space, which only the
    // self plane changes, not a walk. The LCD's own head count watches presence
    // separately, so the two never contend for the same listenable.
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

/// The recessed screen: a raised purple lip that carries the header along its
/// top, a near-black well with a thin bright inner line, and the office clipped
/// inside it. The bezel is wider at the top — the header (room name + power light)
/// lives in that band — so the dark purple reads as a deeper surround above the
/// LCD, the way the mock draws it. The bottom padding the shell adds for its
/// vanished nav rail is stripped on the well, so the map's own legend sits snug to
/// the screen's edge rather than floating a rail's height above it.
class _Screen extends StatelessWidget {
  const _Screen({required this.state, required this.child});

  final AppState state;
  final Widget child;

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
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: MediaQuery.removePadding(
                  context: context,
                  removeBottom: true,
                  child: child,
                ),
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
class _ControlsDeck extends StatelessWidget {
  const _ControlsDeck({
    required this.state,
    required this.onOpenSettings,
    required this.onOpenActivity,
  });

  final AppState state;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenActivity;

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

  void _openMenu(BuildContext context) {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _scDark,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      builder: (sheetContext) => _GameboyMenu(
        state: state,
        onCamera: () async {
          Navigator.of(sheetContext).pop();
          await _run(context, () => state.setCameraOn(!state.call.cameraOn));
        },
        onReact: (emote) async {
          Navigator.of(sheetContext).pop();
          await _run(context, () => state.sendEmoteLocalFirst(emote));
        },
        onSettings: () {
          Navigator.of(sheetContext).pop();
          onOpenSettings();
        },
        onActivity: () {
          Navigator.of(sheetContext).pop();
          onOpenActivity();
        },
      ),
    );
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
                  // D-pad, bottom-left. Dimmed, not removed, when there is nowhere
                  // to walk — a wall is found by walking into it, not a dead control.
                  Positioned(
                    left: 2,
                    top: 0,
                    child: ListenableBuilder(
                      listenable: state.positions,
                      builder: (context, _) => _GbDpad(
                        key: const Key('gb-dpad'),
                        enabled: state.canWalk,
                        onPress: state.walk,
                        onRelease: state.stopWalking,
                      ),
                    ),
                  ),
                  // A, raised and to the right: the cart. Lit while it is latched on.
                  Positioned(
                    right: 18,
                    top: 30,
                    child: _GbRoundButton(
                      label: 'A',
                      size: 64,
                      lit: state.boost,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        state.boost = !state.boost;
                      },
                    ),
                  ),
                  // B, below and left of A: mute. Lit means the mic is live, so the
                  // button glows when you are the one being heard.
                  Positioned(
                    right: 98,
                    top: 66,
                    child: _GbRoundButton(
                      label: 'B',
                      size: 64,
                      lit: call.micOn,
                      onTap: () => _run(context, () => state.setMicOn(!call.micOn)),
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
                          _GbPill(label: 'SELECT', onTap: () => _openMenu(context)),
                          const SizedBox(width: 22),
                          _GbPill(label: 'START', onTap: () => _goHome(context)),
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
/// control that is currently *on*.
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
  final VoidCallback onTap;

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
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
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

/// The Select menu: the controls that are not one of the four physical buttons,
/// one tap each. Camera and the eight reactions do their thing and close; Settings
/// and Activity hand back to the home shell, which switches tab.
class _GameboyMenu extends StatelessWidget {
  const _GameboyMenu({
    required this.state,
    required this.onCamera,
    required this.onReact,
    required this.onSettings,
    required this.onActivity,
  });

  final AppState state;
  final VoidCallback onCamera;
  final ValueChanged<String> onReact;
  final VoidCallback onSettings;
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) {
    final cameraOn = state.call.cameraOn;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MenuRow(
              icon: cameraOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
              lit: cameraOn,
              title: cameraOn ? 'Turn the camera off' : 'Turn the camera on',
              onTap: onCamera,
            ),
            const SizedBox(height: 8),
            // The eight reactions, divided across the row like the dock's tray.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              decoration: BoxDecoration(
                color: _scMid,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _scBorder, width: 1.5),
              ),
              child: Row(
                children: [
                  for (final emote in _emotes)
                    Expanded(
                      child: Semantics(
                        button: true,
                        label: 'Send $emote',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => onReact(emote),
                          child: SizedBox(
                            height: 40,
                            child: Center(child: Text(emote, style: const TextStyle(fontSize: 22))),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _MenuRow(icon: Icons.notifications_rounded, title: 'Activity', onTap: onActivity),
            const SizedBox(height: 8),
            _MenuRow(icon: Icons.settings_rounded, title: 'Settings', onTap: onSettings),
          ],
        ),
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
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool lit;

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
            border: Border.all(color: _scBorder, width: 1.5),
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
