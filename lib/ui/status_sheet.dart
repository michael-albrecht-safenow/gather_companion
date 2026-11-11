/// Who you are in the room: available, busy, away, and a line saying why.
///
/// Gather opens this as a popover above the avatar in its bar. On a phone it is a
/// sheet, for the ordinary reason — a popover anchored to a 48-point tile at the
/// bottom-left of a screen would either cover the thing it belongs to or point at
/// it from a distance, and the app already has one sheet (`type_code_dialog.dart`)
/// whose recipe this follows exactly.
///
/// ## Both halves are read back, and neither is an echo
///
/// Availability comes off the roster, and so does the status line. That second
/// one was an echo of whatever this phone last sent for a while, because
/// `SpaceUserStatus` was one of the models the reader discarded — so it survived
/// no restart and knew nothing about a status set from the Mac. It is tracked
/// now. The join runs from the status row's own `spaceUserId` rather than from
/// `SpaceUser.activeCustomStatusId`, because that field, and
/// `activeUserGeneratedStatusId` beside it, were never set on anybody: measured
/// across 98 rows, including people whose status was on screen at the time.
///
/// One consequence worth knowing: what comes back may be a status **Gather
/// wrote**, not one you typed. A connected calendar produces `CalendarInferred`
/// rows — "Lunch 🥗" — and this sheet will happily show you one and let you
/// replace it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../theme/gather_theme.dart';

/// How long a status stands before Gather drops it by itself.
///
/// Gather's own picker offers a menu of these. One is enough here: the common
/// case by a distance is "for the rest of today", and a phone is not where
/// somebody sets up a status that expires next Tuesday. Public so the debug drive's
/// `status.setCustom` defaults to the same expiry rather than one no control sets.
const statusClearAfter = Duration(hours: 8);

Future<void> showStatusSheet(BuildContext context, AppState state) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      // The sheet paints its own container, as `showTypeCode` does.
      backgroundColor: Colors.transparent,
      builder: (context) => _StatusSheet(state: state),
    );

class _StatusSheet extends StatefulWidget {
  const _StatusSheet({required this.state});

  final AppState state;

  @override
  State<_StatusSheet> createState() => _StatusSheetState();
}

class _StatusSheetState extends State<_StatusSheet> {
  late final _text = TextEditingController(text: widget.state.customStatus?.text ?? '');
  late String? _emoji = widget.state.customStatus?.emoji;

  /// Whether the emoji row is open under the field.
  bool _picking = false;

  /// The availability just tapped, shown until the roster agrees or Gather refuses.
  ///
  /// The sheet is its own route, so nothing rebuilt it when the roster patch landed:
  /// the tap went out, the sheet redrew against the roster it already had, and the
  /// new choice only lit up when a *second* tap happened to redraw it after the
  /// patch. So the sheet now listens to the state, and holds the tap in the meantime
  /// so the chip moves under the finger rather than a quarter of a second later.
  String? _asked;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _text.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    setState(() {
      if (_asked != null && widget.state.myAvailability == _asked) _asked = null;
    });
  }

  Future<void> _run(Future<String?> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    final failed = await action();
    if (!mounted) return;
    if (failed != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(failed)));
      return;
    }
    setState(() {});
  }

  Future<void> _pick(String availability) async {
    HapticFeedback.selectionClick();
    setState(() => _asked = availability);
    final messenger = ScaffoldMessenger.of(context);
    final failed = await widget.state.setAvailability(availability);
    if (!mounted || failed == null) return;
    // Refused: let go of the tap so the chips show what is actually true.
    setState(() => _asked = null);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(failed)));
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    await _run(() => text.isEmpty
        ? widget.state.clearCustomStatus()
        : widget.state.setCustomStatus(
            text: text,
            emoji: _emoji,
            clearAt: DateTime.now().toUtc().add(statusClearAfter),
          ));
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final state = widget.state;
    final current = _asked ?? state.myAvailability;
    final me = state.mePerson;

    return Container(
      decoration: BoxDecoration(
        color: t.popover,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: t.border)),
      ),
      // The keyboard's height goes *inside* the sheet rather than under it. As a
      // margin below the sheet it was a transparent strip, and the map showed
      // through it behind the keyboard — and around its edges while it animated.
      padding: EdgeInsets.fromLTRB(kGutter, 12, kGutter, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: t.ring,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              me?.label ?? 'You',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 2),
            Text(
              availabilityLabel(current ?? 'Active'),
              style: TextStyle(fontSize: 13, color: t.mutedForeground),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                for (final availability in settableAvailabilities) ...[
                  Expanded(
                    child: _Choice(
                      availability: availability,
                      // `Focused` comes off a focus area rather than this
                      // picker, and it is not one of the three — so it lights
                      // none of them rather than pretending to be Active.
                      selected: current == availability,
                      onTap: () => _pick(availability),
                    ),
                  ),
                  if (availability != settableAvailabilities.last)
                    const SizedBox(width: 8),
                ],
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _text,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              maxLength: 80,
              decoration: InputDecoration(
                hintText: 'Update your status',
                counterText: '',
                prefixIcon: _EmojiButton(
                  emoji: _emoji,
                  open: _picking,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _picking = !_picking);
                  },
                ),
                suffixIcon: IconButton(
                  onPressed: _submit,
                  icon: Icon(Icons.arrow_forward_rounded, color: t.mutedForeground),
                  tooltip: 'Set',
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _picking
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _EmojiRow(
                        selected: _emoji,
                        onPick: (next) {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _emoji = next;
                            _picking = false;
                          });
                        },
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            // Only when there is one to take down — the same rule the control
            // bar follows for the conversation button.
            if (state.customStatus != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () async {
                    _text.clear();
                    setState(() => _emoji = null);
                    await _run(state.clearCustomStatus);
                  },
                  child: const Text('Clear it'),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Your status clears itself after eight hours.',
              style: TextStyle(fontSize: 11.5, color: t.faint),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the three, tinted in its own colour when it is the one you are on.
///
/// The fill-and-border pair is the link strip's recipe (0.12 fill, 0.3 border),
/// which is also what Gather draws around the selected state — so it is both the
/// app's own language and a faithful copy, which does not happen often.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.availability,
    required this.selected,
    required this.onTap,
  });

  final String availability;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final colour = availabilityColor(t, availability);

    return Semantics(
      button: true,
      selected: selected,
      label: availabilityLabel(availability),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(t.radius),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: selected ? colour.withValues(alpha: 0.12) : t.secondary,
              borderRadius: BorderRadius.circular(t.radius),
              border: Border.all(
                color: selected ? colour.withValues(alpha: 0.3) : t.border,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    availabilityLabel(availability),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected ? t.foreground : t.mutedForeground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The emoji that sits in front of the status line.
///
/// A short list rather than a keyboard: the system emoji picker is not something
/// a Flutter text field can summon on its own, and the six here cover what a
/// status line is usually about.
const _statusEmoji = ['🎧', '📅', '🍽️', '🚶', '🤒', '🌴'];

/// The field's leading slot: the emoji you have, or a face asking for one.
///
/// It opens a row inside the sheet rather than a menu. It was a `PopupMenuButton`,
/// and a popup anchored to a 48-point slot in a text field opened as a tall
/// full-width list of single emoji over the sheet — and over the keyboard, when
/// the field had focus — which read as something broken rather than as a picker.
class _EmojiButton extends StatelessWidget {
  const _EmojiButton({required this.emoji, required this.open, required this.onTap});

  final String? emoji;
  final bool open;
  final VoidCallback onTap;

  /// The gap between the plate and the field's edge — the same on the left, the
  /// top and the bottom.
  static const _inset = 6.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);

    // The field's own height, worked out the way the field works it out: its
    // content padding plus one line of the text it holds, at the reader's text size.
    //
    // A text field centres its leading icon and grows to fit it, so a slot exactly
    // this tall *is* the field's full height and the insets below are the gaps by
    // construction. Left to the default 48-point slot, the plate sat centred in a
    // 56-point field with ten points above and below it and six to its left.
    final style = theme.textTheme.bodyLarge ?? const TextStyle();
    final padding = theme.inputDecorationTheme.contentPadding?.resolve(Directionality.of(context)) ?? EdgeInsets.zero;
    final line = MediaQuery.textScalerOf(context).scale(style.fontSize ?? 16) * (style.height ?? 1.2);
    final plate = (padding.vertical + line).ceilToDouble() - _inset * 2;

    return Semantics(
      button: true,
      expanded: open,
      label: emoji == null ? 'Pick an emoji' : 'Emoji $emoji. Change it',
      child: Padding(
        // A little less on the right, where the hint text is the neighbour and
        // not the field's border.
        padding: const EdgeInsets.fromLTRB(_inset, _inset, 4, _inset),
        child: Material(
          color: open ? t.brand.withValues(alpha: 0.16) : t.card,
          // Concentric with the field's corner, one inset inside it.
          borderRadius: BorderRadius.circular(t.radius - _inset),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox.square(
              dimension: plate,
              child: Center(
                child: emoji == null
                    ? Icon(Icons.add_reaction_outlined, size: 20, color: open ? t.brandSoft : t.faint)
                    : Text(emoji!, style: const TextStyle(fontSize: 20, height: 1)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The six, plus a way to have none, as one row of equal plates.
///
/// The plates are [_Choice]'s — the tinted fill and border for the one you have —
/// so the row reads as more of the same sheet rather than as a second widget
/// dropped into it.
class _EmojiRow extends StatelessWidget {
  const _EmojiRow({required this.selected, required this.onPick});

  final String? selected;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final options = <String?>[..._statusEmoji, null];

    return Row(
      children: [
        for (final option in options) ...[
          if (option != options.first) const SizedBox(width: 6),
          Expanded(
            child: Semantics(
              button: true,
              selected: option == selected,
              label: option ?? 'No emoji',
              child: Material(
                color: option == selected ? t.brand.withValues(alpha: 0.12) : t.secondary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(t.radius - 2),
                  side: BorderSide(
                    color: option == selected ? t.brand.withValues(alpha: 0.4) : t.border,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onPick(option),
                  child: SizedBox(
                    height: 44,
                    child: Center(
                      child: option == null
                          ? Icon(Icons.block_rounded, size: 18, color: t.faint)
                          : Text(option, style: const TextStyle(fontSize: 20, height: 1)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
