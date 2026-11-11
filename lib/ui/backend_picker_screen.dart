import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../src/app_state.dart';
import '../src/backend_profiles.dart';
import '../theme/gather_theme.dart';

/// Choosing which backend to connect to — the entry for a general client.
///
/// Shown whenever no backend is active (decision §3: a fresh install forces none).
/// It lists the backends already added — which persist and stay choosable forever,
/// even after more are added — alongside the built-in Gather option, and the two
/// ways to add a new one: scan a QR carrying a descriptor URL, or type the URL
/// (decision §1). Picking a backend hands off to [AppState.activateBackend], which
/// either connects (a stored session) or routes on to that backend's login.
///
/// When nothing has been added yet the header doubles as the first-run walkthrough
/// (decision §2): a sentence saying what a backend is and that one must be added to
/// begin, rather than a separate multi-page flow.
class BackendPickerScreen extends StatefulWidget {
  const BackendPickerScreen({super.key, required this.state, this.onClose});

  final AppState state;

  /// A back affordance when the picker was opened over something (the settings
  /// switcher, or the "use a different backend" link on a login screen). Absent on
  /// the fresh-install entry, where the picker *is* the first step.
  final VoidCallback? onClose;

  @override
  State<BackendPickerScreen> createState() => _BackendPickerScreenState();
}

class _BackendPickerScreenState extends State<BackendPickerScreen> {
  final _urlController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _addFromUrl(String rawUrl) async {
    if (rawUrl.trim().isEmpty) {
      setState(() => _error = 'Type a backend address first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.state.addBackendFromUrl(rawUrl);
    if (!mounted) return;
    if (result.error != null) {
      setState(() {
        _busy = false;
        _error = result.error;
      });
      return;
    }
    // Added — go straight to its login (one less tap than adding then picking).
    _urlController.clear();
    await widget.state.activateBackend(result.profile!);
  }

  Future<void> _scanQr() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _UrlScannerScreen()),
    );
    if (!mounted || scanned == null || scanned.isEmpty) return;
    await _addFromUrl(scanned);
  }

  Future<void> _choose(BackendProfile profile) async {
    await widget.state.activateBackend(profile);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final known = widget.state.knownProfiles;

    return Scaffold(
      backgroundColor: t.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(empty: known.isEmpty, onClose: widget.onClose),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(kTextGutter, 4, kTextGutter, 16),
                children: [
                  if (_error != null) ...[
                    _ErrorBanner(message: _error!),
                    const SizedBox(height: 16),
                  ],
                  if (known.isNotEmpty) ...[
                    _SectionLabel('Your backends'),
                    for (final p in known)
                      _BackendTile(
                        title: p.name,
                        subtitle: p.config.apiBase,
                        onTap: _busy ? null : () => _choose(p),
                        onRemove: _busy ? null : () => _confirmRemove(p),
                      ),
                    const SizedBox(height: 20),
                  ],
                  _SectionLabel('Add a backend'),
                  _AddRow(
                    controller: _urlController,
                    busy: _busy,
                    onAdd: _busy ? null : () => _addFromUrl(_urlController.text),
                    onScan: _busy ? null : _scanQr,
                  ),
                  const SizedBox(height: 20),
                  _SectionLabel('Or use Gather'),
                  _BackendTile(
                    title: gatherProfile.name,
                    subtitle: 'Gather\'s own cloud',
                    onTap: _busy ? null : () => _choose(gatherProfile),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BackendProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${profile.name}?'),
        content: const Text('This forgets the backend and signs you out of it on this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed == true) await widget.state.removeBackend(profile.id);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.empty, required this.onClose});

  final bool empty;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 16, kGutter, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Choose a backend', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  empty
                      ? 'This app connects to a Gather-protocol backend — Gather\'s cloud, '
                          'a self-hosted server, or your own. Scan or type its address to begin.'
                      : 'Pick one to connect, or add another.',
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: t.mutedForeground),
                ),
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.6, color: t.faint),
      ),
    );
  }
}

class _BackendTile extends StatelessWidget {
  const _BackendTile({required this.title, required this.subtitle, required this.onTap, this.onRemove});

  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: t.secondary,
        borderRadius: BorderRadius.circular(t.radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(t.radius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: t.foreground)),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: t.faint)),
                      ],
                    ],
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    onPressed: onRemove,
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.delete_outline_rounded, size: 20, color: t.mutedForeground),
                    tooltip: 'Remove',
                  ),
                Icon(Icons.chevron_right_rounded, color: t.mutedForeground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddRow extends StatelessWidget {
  const _AddRow({required this.controller, required this.busy, required this.onAdd, required this.onScan});

  final TextEditingController controller;
  final bool busy;
  final VoidCallback? onAdd;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => onAdd?.call(),
                decoration: const InputDecoration(
                  labelText: 'Backend address',
                  hintText: 'office.example.com',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              onPressed: onScan,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              tooltip: 'Scan a QR code',
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: onAdd,
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
              : const Text('Add backend'),
        ),
      ],
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

/// A full-screen QR scanner that pops the raw scanned string back to the picker.
///
/// Unlike [PairScreen]'s scanner, which only reacts to pairing codes, this returns
/// whatever QR it reads: a backend's descriptor QR carries a plain URL, and the
/// picker validates it by fetching the descriptor.
class _UrlScannerScreen extends StatefulWidget {
  const _UrlScannerScreen();

  @override
  State<_UrlScannerScreen> createState() => _UrlScannerScreenState();
}

class _UrlScannerScreenState extends State<_UrlScannerScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _done = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        title: const Text('Scan backend QR'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(t.radius + 10),
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error) => ColoredBox(
                  color: t.secondary,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'The camera is not available. Type the address instead.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, height: 1.45, color: t.mutedForeground),
                      ),
                    ),
                  ),
                ),
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
