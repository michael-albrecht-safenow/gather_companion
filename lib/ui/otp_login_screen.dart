import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../theme/gather_theme.dart';

/// Email + one-time-code login for a bether-style backend.
///
/// The counterpart to [PairScreen] for an OTP backend (decision §5: the chosen
/// backend decides the login, and this is the one an `otp` descriptor routes to).
/// Two steps on one screen — ask for the address, then for the code the backend
/// emails back — because a single field that silently changes meaning is the kind
/// of thing people mistype into. No embedded webview anywhere: the whole point of
/// an OTP backend is a login that needs no webkit (decision §4).
///
/// It drives [AppState.requestOtpCode] / [AppState.loginWithOtp], which carry the
/// active profile and store the session under it. On success the app's own routing
/// swaps this screen for the office the moment the session lands, so there is no
/// navigation to do here; [onClose] only backs out to the picker.
class OtpLoginScreen extends StatefulWidget {
  const OtpLoginScreen({super.key, required this.state, this.onClose});

  final AppState state;

  /// Back to the backend picker. Always present here — unlike first-run pairing,
  /// an OTP login is always reached by having chosen a backend, so there is always
  /// somewhere to go back to.
  final VoidCallback? onClose;

  @override
  State<OtpLoginScreen> createState() => _OtpLoginScreenState();
}

enum _Step { email, code }

class _OtpLoginScreenState extends State<OtpLoginScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();

  _Step _step = _Step.email;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim();

  Future<void> _sendCode() async {
    final email = _email;
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter the email address for this backend.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await widget.state.requestOtpCode(email);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
      if (failure == null) _step = _Step.code;
    });
  }

  Future<void> _verify() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the code the backend emailed you.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    // On success the routing swaps this screen out as isConfigured flips; only a
    // failure returns here, so there is nothing to do on the null case.
    final failure = await widget.state.loginWithOtp(_email, code);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final name = widget.state.activeProfile?.name ?? 'your backend';

    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              title: 'Sign in to $name',
              subtitle: _step == _Step.email
                  ? 'Enter your email and the backend sends a one-time code'
                  : 'Enter the code sent to $_email',
              onClose: widget.onClose,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(kTextGutter, 8, kTextGutter, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null) ...[
                      _ErrorBanner(message: _error!),
                      const SizedBox(height: 16),
                    ],
                    if (_step == _Step.email)
                      _EmailStep(
                        controller: _emailController,
                        busy: _busy,
                        onSubmit: _busy ? null : _sendCode,
                      )
                    else
                      _CodeStep(
                        controller: _codeController,
                        busy: _busy,
                        onSubmit: _busy ? null : _verify,
                        onChangeEmail: _busy
                            ? null
                            : () => setState(() {
                                  _step = _Step.email;
                                  _error = null;
                                  _codeController.clear();
                                }),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmailStep extends StatelessWidget {
  const _EmailStep({required this.controller, required this.busy, required this.onSubmit});

  final TextEditingController controller;
  final bool busy;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => onSubmit?.call(),
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'you@example.com',
          ),
        ),
        const SizedBox(height: 16),
        _PrimaryButton(label: 'Send me a code', busy: busy, onPressed: onSubmit),
      ],
    );
  }
}

class _CodeStep extends StatelessWidget {
  const _CodeStep({
    required this.controller,
    required this.busy,
    required this.onSubmit,
    required this.onChangeEmail,
  });

  final TextEditingController controller;
  final bool busy;
  final VoidCallback? onSubmit;
  final VoidCallback? onChangeEmail;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => onSubmit?.call(),
          decoration: const InputDecoration(
            labelText: 'Code',
            hintText: '123456',
          ),
        ),
        const SizedBox(height: 16),
        _PrimaryButton(label: 'Sign in', busy: busy, onPressed: onSubmit),
        const SizedBox(height: 4),
        TextButton(
          onPressed: onChangeEmail,
          child: Text(
            'Use a different email',
            style: TextStyle(fontSize: 13, color: t.mutedForeground),
          ),
        ),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.busy, required this.onPressed});

  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return FilledButton(
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
          : Text(label),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: t.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(t.radius),
        border: Border.all(color: t.danger.withValues(alpha: 0.35)),
      ),
      child: Text(message, style: TextStyle(fontSize: 13, height: 1.4, color: t.danger)),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle, required this.onClose});

  final String title;
  final String subtitle;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 14, kGutter, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(subtitle, style: TextStyle(fontSize: 12.5, color: t.mutedForeground)),
              ],
            ),
          ),
          if (onClose != null)
            IconButton(
              onPressed: onClose,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close_rounded, color: t.mutedForeground),
              tooltip: 'Back',
            ),
        ],
      ),
    );
  }
}
