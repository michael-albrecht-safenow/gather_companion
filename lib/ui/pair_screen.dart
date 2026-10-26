import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../src/app_state.dart';
import '../src/pairing.dart';
import '../theme/gather_theme.dart';
import 'type_code_dialog.dart';

/// Pairing with the computer by looking at the square its bridge printed.
///
/// The camera opens straight away: this screen is only ever reached when there is
/// a computer to pair with, so asking first would be a tap in front of the only thing
/// anyone came here to do. The instruction sits under the frame rather than in
/// front of it, because the person who has already run the command needs the
/// viewfinder and the person who has not needs the sentence.
///
/// Typing the code stays available throughout. The camera can be refused at the
/// OS level, and a scanner is then a dead end rather than a convenience.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key, required this.state, this.onClose});

  final AppState state;

  /// A back affordance when there is something to go back to. Absent on first
  /// run, where this screen *is* the next step.
  final VoidCallback? onClose;

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final MobileScannerController _controller = MobileScannerController(
    // One format, and only the codes this app can act on. A reader that reacts to
    // every label in the room is noise.
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// Set while a code is being claimed, so the detector stops firing into it.
  bool _claiming = false;
  /// Set while the in-app login webview is up, so nothing else fires under it.
  bool _signingIn = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_claiming) return;
    for (final barcode in capture.barcodes) {
      final payload = PairPayload.parse(barcode.rawValue ?? '');
      // Anything that is not a pairing code is ignored in silence. A URL passing
      // through the frame is not worth interrupting anyone over, and cannot be —
      // the code alphabet excludes every character a person could misread.
      if (payload == null) continue;
      await _claim(payload);
      return;
    }
  }

  Future<void> _claim(PairPayload payload) async {
    if (!payload.hasAddress) {
      setState(() => _error =
          'That square has no address in it, so this phone cannot tell which '
          'computer to reach. Update the bridge, or type the code and address in.');
      return;
    }

    setState(() {
      _claiming = true;
      _error = null;
    });
    // Stopping the camera is what makes success feel decided rather than merely
    // slow: the frame freezes at the moment the code was taken.
    await _controller.stop();

    final failure = await widget.state.pair(
      host: payload.host!,
      port: payload.port!,
      code: payload.code,
    );
    if (!mounted) return;

    if (failure == null) {
      widget.onClose?.call();
      return;
    }
    setState(() {
      _claiming = false;
      _error = failure;
    });
    await _controller.start();
  }

  /// The bridge-free path: sign in to Gather in-app, no computer involved.
  Future<void> _signIn() async {
    if (_signingIn || _claiming) return;
    await _controller.stop();
    if (!mounted) return;
    setState(() {
      _signingIn = true;
      _error = null;
    });

    final failure = await widget.state.signInWithGather();
    if (!mounted) return;

    if (failure == null && widget.state.isConfigured) {
      widget.onClose?.call();
      return;
    }
    // Either a reported failure, or a silent cancel that left us unconfigured —
    // in both cases drop back to the scanner.
    setState(() {
      _signingIn = false;
      _error = failure;
    });
    await _controller.start();
  }

  Future<void> _typeItInstead() async {
    await _controller.stop();
    if (!mounted) return;
    final paired = await showTypeCode(context, widget.state);
    if (!mounted) return;
    if (paired) {
      widget.onClose?.call();
      return;
    }
    await _controller.start();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: Column(
          children: [
            _Header(onClose: widget.onClose),
            Expanded(
              child: Center(
                child: _Viewfinder(
                  controller: _controller,
                  onDetect: _onDetect,
                  claiming: _claiming,
                ),
              ),
            ),
            _SignInButton(
              onPressed: (_claiming || _signingIn) ? null : _signIn,
              busy: _signingIn,
            ),
            _Hint(error: _error, onType: _claiming ? null : _typeItInstead),
          ],
        ),
      ),
    );
  }
}

/// The primary, bridge-free path: sign in to Gather on the phone itself.
///
/// Sits above the pairing hint because it is the one that needs no computer. The
/// QR flow stays under it as the fallback for a phone that would rather pair.
class _SignInButton extends StatelessWidget {
  const _SignInButton({required this.onPressed, required this.busy});

  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 6, kTextGutter, 0),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: t.brand,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: busy
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    valueColor: AlwaysStoppedAnimation(t.background),
                  ),
                )
              : const Text('Sign in to Gather'),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 14, kGutter, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pair with your computer', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Point the camera at the square in your terminal',
                  style: TextStyle(fontSize: 12.5, color: t.mutedForeground),
                ),
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, color: t.mutedForeground),
              tooltip: 'Close',
            ),
        ],
      ),
    );
  }
}

/// The camera, squared off and framed.
///
/// Square because a QR code is, and the corner marks sit exactly where the symbol
/// should land — people aim at a frame far more accurately than at a full-screen
/// preview with no indication of where to put anything.
class _Viewfinder extends StatelessWidget {
  const _Viewfinder({
    required this.controller,
    required this.onDetect,
    required this.claiming,
  });

  final MobileScannerController controller;
  final void Function(BarcodeCapture) onDetect;
  final bool claiming;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final radius = t.radius + 10;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: MobileScanner(
                controller: controller,
                onDetect: onDetect,
                errorBuilder: (context, error) => _CameraUnavailable(error: error),
                fit: BoxFit.cover,
              ),
            ),
            IgnorePointer(
              child: CustomPaint(
                painter: _CornersPainter(
                  color: claiming ? t.ok : t.brand,
                  radius: radius,
                ),
              ),
            ),
            if (claiming)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: t.background.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(radius),
                ),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(t.ok),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Four brackets at the corners of the frame.
class _CornersPainter extends CustomPainter {
  _CornersPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Proportional to the frame, so the brackets scale with the screen without
    // ever meeting in the middle.
    final arm = size.shortestSide * 0.14;
    final r = radius;

    for (final corner in _Corner.values) {
      final path = Path();
      switch (corner) {
        case _Corner.topLeft:
          path.moveTo(0, arm + r);
          path.lineTo(0, r);
          path.arcToPoint(Offset(r, 0), radius: Radius.circular(r));
          path.lineTo(arm + r, 0);
        case _Corner.topRight:
          path.moveTo(size.width - arm - r, 0);
          path.lineTo(size.width - r, 0);
          path.arcToPoint(Offset(size.width, r), radius: Radius.circular(r));
          path.lineTo(size.width, arm + r);
        case _Corner.bottomRight:
          path.moveTo(size.width, size.height - arm - r);
          path.lineTo(size.width, size.height - r);
          path.arcToPoint(
            Offset(size.width - r, size.height),
            radius: Radius.circular(r),
          );
          path.lineTo(size.width - arm - r, size.height);
        case _Corner.bottomLeft:
          path.moveTo(arm + r, size.height);
          path.lineTo(r, size.height);
          path.arcToPoint(Offset(0, size.height - r), radius: Radius.circular(r));
          path.lineTo(0, size.height - arm - r);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_CornersPainter old) => old.color != color || old.radius != radius;
}

enum _Corner { topLeft, topRight, bottomRight, bottomLeft }

/// Shown in place of the preview when the camera cannot be used at all.
///
/// Refusing camera access is a reasonable thing to have done, and it must not be a
/// dead end — the code can always be typed.
class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    return ColoredBox(
      color: t.secondary.withValues(alpha: 0.5),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, size: 30, color: t.mutedForeground),
              const SizedBox(height: 14),
              Text(
                denied
                    ? 'Gather Companion cannot use the camera'
                    : 'The camera is not available',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: t.foreground,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Type the code in instead — the bridge prints it under the square.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: t.mutedForeground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What to do, under the frame.
class _Hint extends StatelessWidget {
  const _Hint({required this.error, required this.onType});

  final String? error;
  final VoidCallback? onType;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 22, kTextGutter, 6),
      child: Column(
        children: [
          if (error != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: t.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(t.radius),
                border: Border.all(color: t.danger.withValues(alpha: 0.35)),
              ),
              child: Text(
                error!,
                style: TextStyle(fontSize: 13, height: 1.4, color: t.danger),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            'No square on screen yet?',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.foreground),
          ),
          const SizedBox(height: 8),
          // Must match INVOKE in bridge/bin/gather-bridge.js. Dart cannot import
          // that constant, so this copy is kept in step by hand.
          const _Command(text: 'npx gather-app-bridge pair'),
          const SizedBox(height: 10),
          Text(
            'Run that on the computer that has Gather open. It prints a square to point '
            'this at.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.5, color: t.faint),
          ),
          TextButton(
            onPressed: onType,
            child: Text(
              'Type the code instead',
              style: TextStyle(fontSize: 13, color: t.mutedForeground),
            ),
          ),
        ],
      ),
    );
  }
}

/// The command, set as a command rather than as prose.
class _Command extends StatelessWidget {
  const _Command({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: t.secondary,
        // The step-down radius everything nested-scale uses, rather than its
        // own third size.
        borderRadius: BorderRadius.circular(t.radius - 2),
        border: Border.all(color: t.border),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: t.foreground,
          fontFamilyFallback: kMonoFallback,
        ),
      ),
    );
  }
}
