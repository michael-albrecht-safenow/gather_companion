/// The handheld's *hardware* palette, and the themes that swap it.
///
/// Gameboy mode ([GameboyShell]) is frame-only: it moulds the office into a
/// plastic shell and leaves the office inside the screen alone. A theme changes
/// nothing but that plastic — the purple ramp becomes blue, and a brand can be
/// printed in the band below the screen. Everything else the shell draws (the
/// charcoal D-pad and keys, the near-black LCD well, the green/red/pink lights)
/// is shared across themes and stays in [GameboyShell]; a live control glows the
/// same green whichever shell it wears.
///
/// The one ramp that a theme owns is the hardware plastic: eight values from the
/// deepest moulded shadow to the brightest catch of light. [GbHardware] carries
/// them, [GameboyThemeScope] hands the active set down the tree the way
/// `context.tokens` hands down the app's design tokens, and each shell widget
/// reads `context.gbHardware` in its build.
library;

import 'package:flutter/widgets.dart';

/// Which hardware skin the handheld wears. The [id] is the stable string the
/// preference persists — the enum's own name is free to change, the id is not.
enum GameboyThemeId {
  purple('purple'),
  safeNow('safenow');

  const GameboyThemeId(this.id);

  /// The persisted key. See [UiPreferences.saveGameboyThemeId].
  final String id;

  /// Resolve a persisted (or missing) id back to a theme, defaulting to [purple]
  /// — the look someone who has never picked a theme should get, matching the
  /// defensive defaults [UiPreferences] reads with.
  static GameboyThemeId fromId(String? id) {
    for (final t in GameboyThemeId.values) {
      if (t.id == id) return t;
    }
    return GameboyThemeId.purple;
  }
}

/// The hardware plastic ramp: one colour family from the deepest moulded shadow
/// (`hw990`) to the brightest highlight (`hw500`), plus `hw150` for the legible
/// chrome text printed on the body. The housing sits mid-ramp (`hw700`) and the
/// moulded parts sink to the dark end, so a control always has a darker value to
/// stand against. The field names and roles mirror the comments the shell's old
/// `_hw*` consts carried.
@immutable
class GbHardware {
  const GbHardware({
    required this.hw990,
    required this.hw950,
    required this.hw900,
    required this.hw800,
    required this.hw700,
    required this.hw600,
    required this.hw500,
    required this.hw150,
  });

  /// The deepest: the drop under the cross, its sunk hub, the speaker grille.
  final Color hw990;

  /// Near-black: button outlines and the hard drop under a part.
  final Color hw950;

  /// A dark moulded face — the pill slots, the hard shadow block.
  final Color hw900;

  /// The bezel and the recessed frame.
  final Color hw800;

  /// The main housing — the body's own value.
  final Color hw700;

  /// A raised face, and the top-edge highlight.
  final Color hw600;

  /// The brightest catch of light on a dome.
  final Color hw500;

  /// Legible chrome text printed on the body.
  final Color hw150;
}

/// The original purple shell, kept verbatim so the default look is unchanged.
const kPurpleHardware = GbHardware(
  hw990: Color(0xFF160A2E),
  hw950: Color(0xFF241243),
  hw900: Color(0xFF35205F),
  hw800: Color(0xFF48287A),
  hw700: Color(0xFF63379A),
  hw600: Color(0xFF7544B4),
  hw500: Color(0xFF8B55C8),
  hw150: Color(0xFFE6DAF7),
);

/// SafeNow blue: the same mould cast in the brand's blue. The housing is SafeNow
/// blue (`#0022FF`) at `hw700`; darker navies sink below it for the moulded parts
/// and bezel, brighter blues rise above for the raised faces and catch-light. The
/// chrome text is the brand cream (`#F0ECE3`) so the shell's own labels read on
/// blue rather than disappearing into it.
const kSafeNowHardware = GbHardware(
  hw990: Color(0xFF04061F),
  hw950: Color(0xFF06093A),
  hw900: Color(0xFF0A1066),
  hw800: Color(0xFF0A18B0),
  hw700: Color(0xFF0022FF),
  hw600: Color(0xFF2E51FF),
  hw500: Color(0xFF5B78FF),
  hw150: Color(0xFFF0ECE3),
);

/// The cream the SafeNow brand is printed in — its own name so the mark and the
/// chrome text share one source.
const kSafeNowCream = Color(0xFFF0ECE3);

/// A theme: an id, a human label, the hardware ramp it paints with, a swatch for
/// the settings picker, and an optional brandmark printed below the LCD.
@immutable
class GameboyTheme {
  const GameboyTheme({
    required this.id,
    required this.label,
    required this.hardware,
    required this.swatch,
    this.brandmark,
  });

  final GameboyThemeId id;

  /// Shown in the settings subtitle and spoken as the swatch's label.
  final String label;

  final GbHardware hardware;

  /// The colour of this theme's swatch in the settings selector — the body value.
  final Color swatch;

  /// Printed in the band below the screen, or null for a bare band (the DMG
  /// "GAME BOY" wordmark spot). Purple ships bare; SafeNow prints its logo.
  final WidgetBuilder? brandmark;
}

const _purpleTheme = GameboyTheme(
  id: GameboyThemeId.purple,
  label: 'Purple',
  hardware: kPurpleHardware,
  swatch: Color(0xFF63379A),
);

const _safeNowTheme = GameboyTheme(
  id: GameboyThemeId.safeNow,
  label: 'SafeNow',
  hardware: kSafeNowHardware,
  swatch: Color(0xFF0022FF),
  brandmark: _safeNowBrandmark,
);

/// Every theme, in picker order. Purple first — the default.
const kGameboyThemes = <GameboyTheme>[_purpleTheme, _safeNowTheme];

/// The theme for an id. Falls back to the first (purple) if an id ever has no
/// entry, so a stale preference can never leave the shell without a palette.
GameboyTheme themeById(GameboyThemeId id) {
  for (final t in kGameboyThemes) {
    if (t.id == id) return t;
  }
  return kGameboyThemes.first;
}

/// Hands the active [GbHardware] down the tree, read via `context.gbHardware`.
/// The same shape as the app's token scope: one inherited value the whole shell
/// below it paints from, so switching themes is a single rebuild at the root.
class GameboyThemeScope extends InheritedWidget {
  const GameboyThemeScope({
    super.key,
    required this.hardware,
    required super.child,
  });

  final GbHardware hardware;

  static GbHardware of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GameboyThemeScope>();
    assert(scope != null, 'No GameboyThemeScope found in context');
    return scope!.hardware;
  }

  @override
  bool updateShouldNotify(GameboyThemeScope old) => old.hardware != hardware;
}

extension GbThemeContext on BuildContext {
  /// The handheld's active hardware palette. Mirrors `context.tokens`.
  GbHardware get gbHardware => GameboyThemeScope.of(this);
}

/// The SafeNow brandmark: the pixel symbol beside the wordmark, both in cream so
/// the mark reads as printed onto the blue body. Built lazily per theme so the
/// purple band stays bare.
Widget _safeNowBrandmark(BuildContext context) => const _SafeNowMark();

/// The SafeNow logo, printed in the band below the LCD: a pixel-art cast of the
/// symbol next to the word in the shell's pixel face. Decoration, so hidden from
/// the reader — the Settings row names the theme in words.
class _SafeNowMark extends StatelessWidget {
  const _SafeNowMark();

  @override
  Widget build(BuildContext context) {
    return const ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: CustomPaint(painter: _SafeNowSymbolPainter()),
          ),
          SizedBox(width: 10),
          Text(
            'SafeNow',
            style: TextStyle(
              fontFamily: 'PixelifySans',
              fontWeight: FontWeight.w700,
              color: kSafeNowCream,
              fontSize: 20,
              letterSpacing: 0.5,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// The SafeNow badge, inverted for the blue body: a filled cream disc with the
/// brand's own symbol knocked out in blue on top of it. On the real logo the disc
/// is blue and the symbol white; here the body is already the blue, so the disc
/// becomes the cream and the symbol the blue — the "pin" reads as a hole in the
/// cream coin against the plastic around it.
///
/// The symbol is the brand's actual vector, transcribed from the logo SVG's white
/// path (the `M…C…` data, absolute coords in its 143.652 artboard) rather than
/// guessed at a pixel grid — two interlocking swooshes with the mark's own 180°
/// turn. Drawn at any size by scaling that artboard to the painter's box.
class _SafeNowSymbolPainter extends CustomPainter {
  const _SafeNowSymbolPainter();

  /// The logo's artboard is a square this many units on a side; the disc is the
  /// inscribed circle, the symbol lives inside it.
  static const double _art = 143.652;

  /// The two swooshes of the SafeNow mark, built once from the SVG path in the
  /// artboard's own coordinates. Reused every paint — it never changes.
  static final Path _symbol = _buildSymbol();

  static Path _buildSymbol() {
    final p = Path();
    // First swoosh.
    p.moveTo(54.6972, 94.4436);
    p.lineTo(66.3, 83.4995);
    p.cubicTo(60.8628, 81.7293, 56.7764, 77.2111, 55.5675, 71.6327);
    p.cubicTo(54.3585, 66.0543, 56.2088, 60.2549, 60.4271, 56.4009);
    p.lineTo(79.8658, 38.0655);
    p.cubicTo(66.46, 34.4743, 52.2979, 40.2299, 45.2208, 52.1457);
    p.cubicTo(38.1437, 64.0615, 39.8831, 79.222, 49.4759, 89.2333);
    p.close();
    // Second swoosh, the 180° partner.
    p.moveTo(98.886, 52.8082);
    p.cubicTo(100.363, 55.4632, 101.434, 58.3232, 102.065, 61.2939);
    p.lineTo(102.049, 61.3177);
    p.cubicTo(104.238, 71.3536, 101.28, 81.8185, 94.1575, 89.2332);
    p.lineTo(71.8181, 111.518);
    p.lineTo(60.6762, 100.368);
    p.lineTo(82.1335, 80.121);
    p.lineTo(82.4434, 79.8355);
    p.cubicTo(86.4399, 76.0114, 88.1857, 70.4056, 87.0654, 64.9946);
    p.cubicTo(85.9451, 59.5837, 82.116, 55.1273, 76.9281, 53.1968);
    p.lineTo(88.7534, 42.0465);
    p.cubicTo(92.9507, 44.7664, 96.427, 48.4585, 98.886, 52.8082);
    p.close();
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Fit the square artboard into the box, centred.
    final scale = (size.width < size.height ? size.width : size.height) / _art;
    final drawn = _art * scale;
    canvas.save();
    canvas.translate((size.width - drawn) / 2, (size.height - drawn) / 2);
    canvas.scale(scale);

    // The cream coin — the inscribed circle of the artboard.
    const centre = Offset(_art / 2, _art / 2);
    canvas.drawCircle(centre, _art / 2, Paint()..color = kSafeNowCream);
    // The symbol knocked out in the body blue.
    canvas.drawPath(_symbol, Paint()..color = const Color(0xFF0022FF));

    canvas.restore();
  }

  @override
  bool shouldRepaint(_SafeNowSymbolPainter old) => false;
}
