/// Whose face the call screen enlarges, and the one timer behind that choice —
/// moved out of `CallScreen`'s `State` so it can be read without a screenshot.
///
/// ## Why this is not in the widget any more
///
/// The decision used to live in `_CallScreenState`: the mode toggle, the manual
/// pick, the pin carried across a toggle, the [SpotlightDirector] and the dwell
/// timer that re-asks it. All of it was correct, and none of it was observable.
/// `docs/sim_test_plan.md` C1–C7 ("a blip never takes the big view", "one
/// promotion per turn, no jump mid-turn") could only be checked by screenshotting
/// a simulator at the right moment and squinting. A behaviour that is a state
/// machine with a clock does not need pixels to be checked; it needs the state.
/// So the state moved here, a [ChangeNotifier] the screen subscribes to and
/// renders, and the debug drive (`call.spotlight`, `../debug_drive/call_drive.dart`)
/// reads the same object the screen draws from. One code path, two readers.
///
/// This is a move, not a redesign. Every rule below is the widget's rule as it
/// was, including the ordering: each public operation finishes all of its state
/// changes before it notifies once, and the screen re-syncs the SFU watch set
/// once per notification (plus once per room change in manual mode, where the
/// controller does not notify), so it recomputes the watch set exactly as often
/// as it did when these were `setState` blocks.
///
/// ## The seams
///
/// [SpotlightDirector] is pure and takes the time it is handed; this class owns
/// the clock ([now]) and the timer ([startTimer]) so a test can drive a real
/// 1.5 s dwell under `fake_async` instead of faking a zero one. The tiles come
/// from a callback rather than a field because the screen derives them fresh
/// from `AppState` on every change, and the timer's re-ask must see the room as
/// it is when the deadline lands, not as it was when the timer was armed.
///
/// ## The history
///
/// Every change of the face actually on screen is recorded, with what caused
/// it, in a short ring ([kSpotlightHistory]). That is what turns "no thrash" and
/// "one promotion per turn" into something an agent can assert: read the
/// transitions after a scenario has run and count them. Nothing reads it but
/// the drive, so the bookkeeping ([_observe], the promotion count) runs only
/// under `kDebugMode`: a release build keeps the widget's old fast path, where a
/// room change in manual mode did no work at all.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'spotlight_director.dart';

/// Who the call screen enlarges, and who decides.
///
/// In [manual] the person looking picks: tap a face to enlarge it, the return
/// button to go back. In [auto] the view follows whoever is talking, and a tap
/// on a face leaves auto for manual to watch that person. The toggle in the
/// header flips between the two, over and over.
enum SpotlightMode { manual, auto }

/// What the controller needs to know about one tile: its id, whether it is
/// yourself, and whether its ring is lit. The screen's `CallTile` carries far
/// more; this is the slice the decision reads.
typedef SpotlightTile = ({String id, bool isSelf, bool speaking});

/// How the controller arms its one timer. `Timer.new` in the app; a test may
/// pass its own, though `fake_async` already fakes `Timer.new`.
typedef SpotlightTimer = Timer Function(Duration duration, void Function() callback);

/// How many transitions [SpotlightController.history] keeps.
const int kSpotlightHistory = 64;

/// One change of the face on screen.
@immutable
class SpotlightTransition {
  const SpotlightTransition({
    required this.at,
    required this.mode,
    required this.cause,
    this.from,
    this.to,
  });

  final DateTime at;
  final SpotlightMode mode;

  /// What moved it: `promoted` (a speaker held the floor the full dwell),
  /// `fallback` (a silent big view ran out its linger), `room` (the tiles
  /// changed under it — a holder left, or a pinned face came back), `mode`,
  /// `tap`, `overview`.
  final String cause;

  /// The enlarged id before and after; null is the overview grid.
  final String? from;
  final String? to;

  Map<String, Object?> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'mode': mode.name,
        'cause': cause,
        'from': from,
        'to': to,
      };
}

/// The spotlight's state and timer, for one open call screen.
class SpotlightController extends ChangeNotifier {
  SpotlightController({
    required List<SpotlightTile> Function() tiles,
    SpotlightDirector? director,
    DateTime Function()? now,
    SpotlightTimer? startTimer,
  })  : _tilesOf = tiles,
        director = director ?? SpotlightDirector(),
        _now = now ?? DateTime.now,
        _startTimer = startTimer ?? Timer.new {
    _since = _now();
  }

  final List<SpotlightTile> Function() _tilesOf;
  final DateTime Function() _now;
  final SpotlightTimer _startTimer;

  /// The automatic-spotlight machine.
  final SpotlightDirector director;

  /// How the spotlight is chosen, and the state each side of the toggle keeps.
  ///
  /// [manualId] is the face the person tapped in manual mode. [autoPinned] is
  /// the big view carried across when the toggle flips to auto — a temporary pin
  /// that the next promoted speaker overrides without the mode changing. (A tap
  /// in auto no longer pins; it switches to manual.) Only one is live at a time,
  /// decided by [mode].
  SpotlightMode _mode = SpotlightMode.manual;
  String? _manualId;
  String? _autoPinned;

  SpotlightMode get mode => _mode;
  String? get manualId => _manualId;
  String? get autoPinned => _autoPinned;

  /// Fires when a pending speaker has held the floor long enough to promote, or
  /// a silent big view has lingered long enough to drop, so the view moves even
  /// when no further speaking change arrives to re-ask.
  Timer? _dwellTimer;
  DateTime? _dwellDue;

  bool _disposed = false;

  /// The face on screen as last observed, when it took that value, and how it
  /// got there.
  String? _shown;
  late DateTime _since;
  int _promotions = 0;
  final List<SpotlightTransition> _history = [];

  /// Every change of the face on screen, oldest first, at most
  /// [kSpotlightHistory].
  List<SpotlightTransition> get history => List.unmodifiable(_history);

  /// How many fresh promotions the director has made over this controller's life.
  int get promotions => _promotions;

  /// The tiles as the screen would draw them now.
  List<SpotlightTile> get tiles => _tilesOf();

  /// The speaking set the director is fed: everybody lit except yourself — you
  /// do not get enlarged on your own screen for talking.
  static Set<String> speakingIn(Iterable<SpotlightTile> tiles) => {
        for (final tile in tiles)
          if (tile.speaking && !tile.isSelf) tile.id,
      };

  /// The face being enlarged right now, or null for the overview grid.
  String? get effective => effectiveIn(_tilesOf());

  /// The face to enlarge among [tiles], or null for the overview grid.
  ///
  /// Resolved against the live tile list every time: a pinned or promoted id that
  /// has since left the call, or that resolves to yourself, falls back to the
  /// overview rather than enlarging nothing.
  String? effectiveIn(Iterable<SpotlightTile> tiles) {
    String? present(String? id, {required bool allowSelf}) {
      if (id == null) return null;
      for (final tile in tiles) {
        if (tile.id != id) continue;
        if (tile.isSelf && !allowSelf) return null;
        return id;
      }
      return null;
    }

    return switch (_mode) {
      SpotlightMode.manual => present(_manualId, allowSelf: true),
      SpotlightMode.auto =>
        present(_autoPinned, allowSelf: false) ?? present(director.target, allowSelf: false),
    };
  }

  /// The roster or call changed. Advances the automatic spotlight (and notifies)
  /// in auto; in manual only notes (debug builds) whether the face on screen
  /// moved under it, and does not notify — the caller re-syncs itself.
  void roomChanged() {
    if (_disposed) return;
    if (_mode != SpotlightMode.auto) {
      _observe('room');
      return;
    }
    final promoted = _driveAuto();
    _observe(promoted ? 'promoted' : 'room');
    notifyListeners();
  }

  /// Advances the automatic spotlight from who is talking and re-arms the
  /// timer. Returns whether this was a fresh promotion. Does not notify.
  bool _driveAuto() {
    final now = _now();
    final result = director.update(speakingIn(_tilesOf()), now);
    // A fresh promotion is the moment a manual pin gives way to the room.
    if (result.promoted) {
      _autoPinned = null;
      if (kDebugMode) _promotions++;
    }

    _cancelTimer();
    // A pending promotion (somebody counting towards the floor) or a pending
    // fallback (a silent big view counting down to the grid) — either one needs
    // the view re-asked when its deadline lands, since no speaking change will.
    final left = director.timeToPromote(now) ?? director.timeToFallback(now);
    if (left != null) {
      _dwellDue = now.add(left);
      _dwellTimer = _startTimer(left, _onDeadline);
    }
    return result.promoted;
  }

  void _onDeadline() {
    if (_disposed) return;
    _dwellTimer = null;
    _dwellDue = null;
    // The before/after reads only label the transition; release skips them.
    final before = kDebugMode ? effective : null;
    final promoted = _driveAuto();
    if (kDebugMode) {
      final after = effective;
      _observe(promoted ? 'promoted' : (before != null && after == null ? 'fallback' : 'room'));
    }
    notifyListeners();
  }

  void _cancelTimer() {
    _dwellTimer?.cancel();
    _dwellTimer = null;
    _dwellDue = null;
  }

  /// Flips the toggle, carrying the current big view across so it does not jump.
  void setMode(SpotlightMode mode) {
    if (_disposed || mode == _mode) return;
    if (mode == SpotlightMode.auto) {
      // Carry the manually enlarged face across as auto's temporary pin, so
      // the big view holds until the next speaker holds the floor — rather than
      // dropping to the grid for the length of a dwell. A self enlargement has
      // no place in auto and is dropped; [effectiveIn] refuses it too.
      _autoPinned = _manualId;
      _manualId = null;
      director.reset();
    } else {
      // Keep whoever is big now, so turning auto off freezes the view rather
      // than dropping it back to the grid.
      _manualId = _autoPinned ?? director.target;
      _autoPinned = null;
      director.reset();
      _cancelTimer();
    }
    _mode = mode;
    var promoted = false;
    if (mode == SpotlightMode.auto) promoted = _driveAuto();
    _observe(promoted ? 'promoted' : 'mode');
    notifyListeners();
  }

  /// A tap on a face: enlarge it, and leave auto for manual if that is where the
  /// tap came from. Never yourself in auto — the room does not need to watch you
  /// watch it, and tapping yourself there is a no-op rather than a mode switch.
  /// Returns whether the tap did anything.
  bool tap(String id, {required bool isSelf}) {
    if (_disposed) return false;
    if (_mode == SpotlightMode.auto && isSelf) return false;
    _manualId = id;
    if (_mode == SpotlightMode.auto) {
      // Tapping a face is a request to watch that person: leave the automatic
      // follow and pin them, so the toggle reflects the manual view the tap
      // produced. The next speaker no longer overrides it.
      _mode = SpotlightMode.manual;
      _autoPinned = null;
      _cancelTimer();
    }
    _observe('tap');
    notifyListeners();
    return true;
  }

  /// Back to the overview grid. In auto the machine starts counting afresh, so
  /// the next speaker to hold the floor brings the big view back on its own.
  void returnToOverview() {
    if (_disposed) return;
    var promoted = false;
    if (_mode == SpotlightMode.manual) {
      _manualId = null;
    } else {
      _autoPinned = null;
      director.reset();
      _cancelTimer();
      promoted = _driveAuto();
    }
    _observe(promoted ? 'promoted' : 'overview');
    notifyListeners();
  }

  /// Records a change of the face on screen, if there was one. Debug only: it
  /// re-derives the tiles, and only the drive reads what it records.
  void _observe(String cause) {
    if (!kDebugMode) return;
    final now = effective;
    if (now == _shown) return;
    final at = _now();
    _history.add(SpotlightTransition(at: at, mode: _mode, cause: cause, from: _shown, to: now));
    if (_history.length > kSpotlightHistory) _history.removeAt(0);
    _shown = now;
    _since = at;
  }

  /// What the spotlight is doing, as JSON, for `call.spotlight`. Read-only;
  /// referenced only from the debug drive, so it shakes out of a release.
  ///
  /// [historyMax] bounds how many of the most recent transitions are included.
  Map<String, Object?> debugSnapshot({int historyMax = kSpotlightHistory}) {
    final now = _now();
    final tiles = _tilesOf();
    final target = effectiveIn(tiles);
    int ago(DateTime t) => now.difference(t).inMilliseconds;
    final candidate = director.candidate;
    final candidateSince = director.candidateSince;
    final silentSince = director.silentSince;
    final promoteIn = director.timeToPromote(now);
    final fallbackIn = director.timeToFallback(now);
    final recent = _history.length <= historyMax ? _history : _history.sublist(_history.length - historyMax);
    return {
      'mode': _mode.name,
      // `empty` is the "nobody here" card; `grid` the overview; `spotlight` one
      // face big with the rest in the strip.
      'view': tiles.isEmpty ? 'empty' : (target == null ? 'grid' : 'spotlight'),
      'target': target,
      // When the face on screen last changed, as this controller observed it.
      'since': _since.toUtc().toIso8601String(),
      'sinceMs': ago(_since),
      // The raw choices behind [target], before the live tile list filtered
      // them. A non-null one with a null target is a pick whose holder left.
      'decided': {
        'manualId': _manualId,
        'autoPinned': _autoPinned,
        'directorTarget': director.target,
      },
      'speaking': speakingIn(tiles).toList()..sort(),
      'tiles': [for (final t in tiles) t.id],
      'selfId': [for (final t in tiles) if (t.isSelf) t.id].firstOrNull,
      'candidate': candidate == null || candidateSince == null
          ? null
          : {
              'id': candidate,
              'since': candidateSince.toUtc().toIso8601String(),
              'heldMs': ago(candidateSince),
              'promoteInMs': promoteIn?.inMilliseconds,
            },
      'lingering': silentSince == null || fallbackIn == null
          ? null
          : {
              'since': silentSince.toUtc().toIso8601String(),
              'silentMs': ago(silentSince),
              'fallbackInMs': fallbackIn.inMilliseconds,
            },
      'timer': _dwellDue == null ? null : {'dueInMs': _dwellDue!.difference(now).inMilliseconds},
      'dwellMs': director.dwell.inMilliseconds,
      'lingerMs': director.linger.inMilliseconds,
      'promotions': _promotions,
      'transitions': [for (final t in recent) t.toJson()],
      'transitionsDropped': _history.length - recent.length,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimer();
    super.dispose();
  }
}

/// Every [SpotlightController] whose screen is mounted, newest last — the one
/// the drive reads is [current], the screen on top.
///
/// Same shape and the same rule as `renderRegistry`: written **only inside
/// `if (kDebugMode)`** at the screen, so a release build drops the writes and
/// tree-shakes this with the drive.
class SpotlightRegistry {
  final List<SpotlightController> _mounted = [];

  void attach(SpotlightController controller) => _mounted.add(controller);
  void detach(SpotlightController controller) => _mounted.remove(controller);

  /// The most recently mounted controller, or null with no call screen open.
  SpotlightController? get current => _mounted.isEmpty ? null : _mounted.last;

  /// How many call screens are mounted (more than one is a navigation bug).
  int get count => _mounted.length;

  @visibleForTesting
  void debugReset() => _mounted.clear();
}

/// The one registry the call screen writes to. Only ever touched inside
/// `if (kDebugMode)`; see [SpotlightRegistry].
final SpotlightRegistry spotlightRegistry = SpotlightRegistry();
