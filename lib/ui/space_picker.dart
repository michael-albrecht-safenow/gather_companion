import 'package:flutter/material.dart';
import 'package:gather_client/gather_client.dart';

import '../theme/gather_theme.dart';

/// Which space to open, asked right after an in-app sign-in.
///
/// The bridge learned the space from the desktop client's last-opened-space on
/// disk; the phone has no such shortcut, so a harvested session arrives with no
/// space bound. Rather than hand the collector a null it can only fill from an
/// `recent-spaces` call that may come back empty — stranding it on "Reconnecting"
/// with nothing to join — we ask here, from the account's recent spaces, before
/// adopting the credentials.
///
/// Returns the chosen space, or null when the sheet is dismissed (a deliberate
/// cancel that leaves the phone unconfigured).
Future<GatherSpace?> showSpacePicker(
  BuildContext context,
  List<GatherSpace> spaces,
) {
  return showModalBottomSheet<GatherSpace>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _SpacePickerSheet(spaces: spaces),
  );
}

class _SpacePickerSheet extends StatelessWidget {
  const _SpacePickerSheet({required this.spaces});

  final List<GatherSpace> spaces;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return Container(
      decoration: BoxDecoration(
        color: t.popover,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: t.border)),
      ),
      padding: const EdgeInsets.fromLTRB(kGutter, 12, kGutter, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            Text('Open which space?',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'The phone follows one space at a time. You can switch later from Gather.',
              style: TextStyle(fontSize: 12.5, color: t.mutedForeground),
            ),
            const SizedBox(height: 12),
            // The list is already most-recent first. Bounded so a long history
            // scrolls inside the sheet rather than pushing the grabber off screen.
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: spaces.length,
                separatorBuilder: (_, _) => Divider(height: 1, color: t.border),
                itemBuilder: (context, i) {
                  final space = spaces[i];
                  final label = (space.name?.trim().isNotEmpty ?? false)
                      ? space.name!.trim()
                      : space.id;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label, style: TextStyle(color: t.foreground)),
                    trailing: Icon(Icons.chevron_right, color: t.mutedForeground),
                    onTap: () => Navigator.of(context).pop(space),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
