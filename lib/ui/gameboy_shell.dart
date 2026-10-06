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

// The shell's own palette. Deliberately not [GatherTokens]: the office inside the
// screen must stay the app's normal colours, so the retro purple lives only here
// and touches nothing the map draws with.
const _gbBody = Color(0xFF7B52C7);
const _gbBodyLight = Color(0xFF9A6FE0);
const _gbBodyDark = Color(0xFF4F3486);
const _gbScreenFrame = Color(0xFF2A1E4A);
const _gbButton = Color(0xFF3B2A63);
const _gbButtonEdge = Color(0xFF2A1E4A);
const _gbButtonText = Color(0xFFC9B8F0);
const _gbHeaderText = Color(0xFFCDBDF2);
const _gbHeart = Color(0xFFE56FA0);
const _gbLed = Color(0xFFE2585F);
const _gbLit = Color(0xFF9BBC0F); // the one "on" accent — a Gameboy green.
const _gbSheet = Color(0xFF241A3E);

/// How wide the cross is. Each arm is then a target a thumb can hit without
/// looking, which is the point of a control used while watching the screen above it.
const double _dpadSize = 150;

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
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_gbBodyLight, _gbBody, _gbBodyDark],
          stops: [0, 0.4, 1],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
          child: Column(
            children: [
              _Header(name: state.spaceName),
              const SizedBox(height: 8),
              Expanded(child: _Screen(child: child)),
              const SizedBox(height: 8),
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

/// The strip above the screen: the office this is on the left, the power light
/// on the right — the two things moulded into the top of a real one. The name is
/// the space's own, as the LCD title has it, so the shell is badged with the room
/// you are in rather than a fixed wordmark.
class _Header extends StatelessWidget {
  const _Header({required this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          const Icon(Icons.favorite, color: _gbHeart, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name ?? 'The office',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _gbHeaderText,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: _gbLed,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: _gbLed.withValues(alpha: 0.7), blurRadius: 6, spreadRadius: 1)],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'POWER',
            style: TextStyle(
              color: _gbHeaderText,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// The recessed screen: a dark bezel with the office clipped inside it. The
/// bottom padding the shell adds for its vanished nav rail is stripped here, so
/// the map's own legend sits snug to the screen's edge rather than floating a
/// rail's height above it.
class _Screen extends StatelessWidget {
  const _Screen({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: _gbScreenFrame,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.45), width: 2),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: child,
        ),
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
      backgroundColor: _gbSheet,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
        // edges: the cross and the A/B pair share an upper band, the slanted pair
        // and the grille a lower one, with no dead plastic in between. The buttons
        // sit low against the cross's centre so the right of the body fills the
        // way the left does.
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
                      size: 66,
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
                      size: 58,
                      lit: call.micOn,
                      onTap: () => _run(context, () => state.setMicOn(!call.micOn)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Select and Start, the slanted pair centred, with the moulded grille
            // tucked into the corner beside them.
            SizedBox(
              height: 50,
              child: Stack(
                children: [
                  const Positioned(
                    right: 16,
                    bottom: 0,
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
    final arm = size.width * 0.36;
    final radius = const Radius.circular(12);
    final vertical = RRect.fromRectAndRadius(
      Rect.fromCenter(center: centre, width: arm, height: size.height),
      radius,
    );
    final horizontal = RRect.fromRectAndRadius(
      Rect.fromCenter(center: centre, width: size.width, height: arm),
      radius,
    );

    final shadow = Paint()..color = Colors.black.withValues(alpha: enabled ? 0.35 : 0.2);
    canvas.drawRRect(vertical.shift(const Offset(0, 3)), shadow);
    canvas.drawRRect(horizontal.shift(const Offset(0, 3)), shadow);

    final face = Paint()..color = enabled ? _gbButton : _gbButton.withValues(alpha: 0.5);
    canvas.drawRRect(vertical, face);
    canvas.drawRRect(horizontal, face);

    // A faint rim, so the cross reads as raised plastic rather than a flat hole.
    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = _gbButtonEdge.withValues(alpha: enabled ? 1 : 0.5);
    canvas.drawRRect(vertical, rim);
    canvas.drawRRect(horizontal, rim);

    // The still hub.
    canvas.drawCircle(centre, arm * 0.3, Paint()..color = _gbBodyDark.withValues(alpha: enabled ? 1 : 0.5));

    _arrow(canvas, size, 'Up');
    _arrow(canvas, size, 'Down');
    _arrow(canvas, size, 'Left');
    _arrow(canvas, size, 'Right');
  }

  void _arrow(Canvas canvas, Size size, String direction) {
    final centre = Offset(size.width / 2, size.height / 2);
    final reach = size.width * 0.34;
    final s = size.width * 0.07;
    final lit = held == direction;
    final paint = Paint()
      ..color = lit
          ? Colors.white
          : _gbButtonText.withValues(alpha: enabled ? 0.9 : 0.4);

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

/// One round button, A or B. Pressed is a push down rather than a colour change;
/// lit is the green accent for a control that is currently *on*.
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
          transform: Matrix4.translationValues(0, _down ? 2 : 0, 0),
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.3, -0.4),
              radius: 0.9,
              colors: lit
                  ? [_gbLit, const Color(0xFF6E8C0A)]
                  : [_gbBody, _gbButton],
            ),
            border: Border.all(color: _gbButtonEdge, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: lit ? _gbLit.withValues(alpha: 0.55) : Colors.black.withValues(alpha: 0.4),
                blurRadius: lit ? 10 : 6,
                offset: Offset(0, _down ? 1 : 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              widget.label,
              style: TextStyle(
                color: lit ? Colors.white : _gbButtonText,
                fontSize: widget.size * 0.34,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A Select or Start key: a slanted little pill with its name under it.
class _GbPill extends StatelessWidget {
  const _GbPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: -0.32,
              child: Container(
                width: 48,
                height: 15,
                decoration: BoxDecoration(
                  color: _gbButton,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _gbButtonEdge, width: 1.5),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 3, offset: const Offset(0, 2))],
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              style: TextStyle(
                color: _gbHeaderText,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The moulded grille in the corner. Six slanted ribs, shortening outward, as the
/// mock has them. Hidden from the reader — it is decoration, not a control.
class _SpeakerGrille extends StatelessWidget {
  const _SpeakerGrille();

  @override
  Widget build(BuildContext context) {
    return const ExcludeSemantics(
      child: SizedBox(
        width: 70,
        height: 40,
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
      ..color = _gbBodyDark
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const count = 6;
    for (var i = 0; i < count; i++) {
      final x = size.width - i * 11.0;
      // Each rib a touch shorter than the last, so the block reads as angled.
      final top = size.height - (count - i) * 5.0;
      canvas.drawLine(Offset(x, size.height), Offset(x - 8, top.clamp(0, size.height)), paint);
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
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  for (final emote in _emotes)
                    Expanded(
                      child: Semantics(
                        button: true,
                        label: 'Send $emote',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
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
    final colour = lit ? _gbLit : _gbHeaderText;
    return Material(
      color: Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 22, color: colour),
              const SizedBox(width: 14),
              Text(
                title,
                style: TextStyle(color: colour, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
