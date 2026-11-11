/// `ext.gc.call.spotlight*`: who the call screen enlarges, and why — the state
/// `docs/sim_test_plan.md` C1–C7 used to be checked by screenshot (plan task
/// 4.1).
///
/// The spotlight is a state machine with a clock: a dwell before a new speaker
/// is promoted, stickiness while the target keeps talking, a linger before a
/// silent big view drops to the grid. Every one of those rules is a moment in
/// time, and a screenshot catches the moment it happens to be taken at. These
/// read the `SpotlightController` the screen itself renders from
/// (`../media/spotlight_controller.dart`), including its record of every change
/// of the face on screen, so "a blip never takes the big view" is "no
/// transition to a non-null target" and "one promotion per turn" is a count.
///
/// Four actions, one controller:
///
///  * `call.spotlight {historyMax?}` — the readout: `mode`, `view`
///    (`empty`/`grid`/`spotlight`), `target`, `since`/`sinceMs`, the raw
///    `decided` picks, `speaking`, `tiles`, the director's `candidate` and
///    `lingering` countdowns, the armed `timer`, `dwellMs`/`lingerMs`,
///    `promotions` and `transitions`. Read-only.
///  * `call.spotlight.mode {mode}` — the header toggle (`auto` | `manual`).
///  * `call.spotlight.pick {id}` — a tap on a face. Yourself in auto is the
///    screen's own no-op, answered `refused('self_in_auto')`.
///  * `call.spotlight.overview` — the return button.
///
/// The three levers are the same public methods the screen's buttons call,
/// and each answers with the readout after it. None is `outward`: the big view
/// is this phone's business. What it changes on the wire is which simulcast
/// layer the SFU sends *us*, which nobody else can see.
///
/// The controller exists only while a call screen is mounted, so every action
/// answers `refused('call_screen_closed')` without one — a closed screen is not
/// "nobody is enlarged", and saying so would be the dishonest empty reading the
/// drive's rules forbid.
library;

import '../media/call.dart';
import '../media/spotlight_controller.dart';
import 'debug_drive.dart';
import 'drive_result.dart';

/// `ext.gc.call.*`. [screens] is the registry the call screen writes to
/// (`spotlightRegistry` in the app); a seam so a test can hand its own.
DriveFeature callFeature({
  required Call? Function() call,
  required String Function() boot,
  SpotlightRegistry? screens,
}) {
  final registry = screens ?? spotlightRegistry;

  Map<String, Object?> readout(SpotlightController c, {int historyMax = kSpotlightHistory}) => {
        'boot': boot(),
        'inCall': call() != null,
        'screens': registry.count,
        ...c.debugSnapshot(historyMax: historyMax),
      };

  DriveResult closed() => DriveResult.refused('call_screen_closed', {'boot': boot()});

  return DriveFeature('call', [
    DriveAction('spotlight', (args) async {
      final historyMax = args.optionalInt('historyMax', min: 0, max: kSpotlightHistory);
      final c = registry.current;
      if (c == null) return closed();
      return DriveResult.ok(readout(c, historyMax: historyMax ?? kSpotlightHistory));
    }),
    DriveAction('spotlight.mode', (args) async {
      final name = args.requireString('mode');
      final mode = SpotlightMode.values.where((m) => m.name == name).firstOrNull;
      if (mode == null) throw DriveInvalidParams('"mode" must be "auto" or "manual"');
      final c = registry.current;
      if (c == null) return closed();
      c.setMode(mode);
      return DriveResult.ok(readout(c));
    }),
    DriveAction('spotlight.pick', (args) async {
      final id = args.requireString('id');
      final c = registry.current;
      if (c == null) return closed();
      final tiles = c.tiles;
      final tile = tiles.where((t) => t.id == id).firstOrNull;
      if (tile == null) {
        return DriveResult.refused('no_such_tile', {
          'id': id,
          'tiles': [for (final t in tiles) t.id],
        });
      }
      if (!c.tap(tile.id, isSelf: tile.isSelf)) {
        return DriveResult.refused('self_in_auto', {'id': id, 'mode': c.mode.name});
      }
      return DriveResult.ok(readout(c));
    }),
    DriveAction('spotlight.overview', (args) async {
      final c = registry.current;
      if (c == null) return closed();
      c.returnToOverview();
      return DriveResult.ok(readout(c));
    }),
  ]);
}
