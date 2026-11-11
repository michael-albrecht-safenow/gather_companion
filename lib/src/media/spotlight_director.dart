/// Picks whose face to enlarge in automatic mode, from who is talking.
///
/// The call screen's spotlight can follow the active speaker, and the one thing
/// that must not happen is for it to jump — a cough, a one-word "yeah", a scrape
/// of a chair all light the speaking ring for a moment, and a big view that
/// chased every one of them would be unwatchable. So promotion is gated two ways,
/// the same shape as [VoiceActivity] one level down:
///
///  * **Dwell.** A new speaker has to hold the floor for [dwell] before the view
///    moves to them. Shorter than that and they never become the target.
///  * **Sticky.** Once somebody is the target, they keep it for as long as they
///    keep talking. A second person talking over them does not steal it; the view
///    moves only once the current speaker actually stops and somebody else has
///    held the floor for the dwell. That is what turns "loudest wins, moment to
///    moment" into "the person with the floor", which is what a meeting actually
///    looks like.
///
/// And once the view is on somebody, it *stays* big across the gaps. A finished
/// turn does not drop back to the grid — the last speaker lingers, enlarged, and
/// the next speaker to hold the floor takes the big view over directly, so a
/// handoff is one face replacing another rather than a flash of the overview
/// between them. Only a real lull — nobody talking at all for [linger] — falls
/// back to the grid.
///
/// Pure on purpose, exactly like [VoiceActivity]: no timers, no clock of its own.
/// It is handed the set of people speaking and the time, and it answers who to
/// show. The call screen owns the one timer that re-asks when a dwell — or a
/// [linger] — elapses.
///
/// Self is never in the set it is handed — you do not get enlarged on your own
/// screen for talking — so that rule lives in the caller, not here.
library;

/// The automatic-spotlight decision, as a small state machine.
class SpotlightDirector {
  SpotlightDirector({
    this.dwell = const Duration(milliseconds: 1500),
    this.linger = const Duration(seconds: 5),
  });

  /// How long a new speaker must hold the floor before the view moves to them.
  final Duration dwell;

  /// How long a silent big view holds the last speaker before it falls back to
  /// the overview grid. A short lull — the pause between turns — keeps the face
  /// up; only a real one this long drops it.
  final Duration linger;

  /// Who the view is on now, or null for the overview grid.
  String? _target;

  /// Who is counting towards becoming the target, and since when.
  String? _candidate;
  DateTime? _candidateSince;

  /// When the room fell silent while the view was still on [_target], for the
  /// [linger] countdown. Null whenever anybody is talking.
  DateTime? _silentSince;

  String? get target => _target;

  /// Who is counting towards the floor, and since when — null when nobody is.
  /// Read-only, for `SpotlightController`'s readout; the decision never reads
  /// them from outside.
  String? get candidate => _candidate;
  DateTime? get candidateSince => _candidateSince;

  /// When a big view went silent and started its [linger] countdown, or null.
  /// Read-only, for the same readout.
  DateTime? get silentSince => _silentSince;

  /// Feeds in who is speaking right now. Returns the id to enlarge — or null for
  /// the overview grid — and whether that was a *fresh* promotion, which is the
  /// signal the caller uses to drop a manual pin.
  ({String? target, bool promoted}) update(Set<String> speaking, DateTime now) {
    // Sticky: the current target keeps the floor while they keep talking, no
    // matter who else has started up alongside them.
    if (_target != null && speaking.contains(_target)) {
      _candidate = null;
      _candidateSince = null;
      _silentSince = null;
      return (target: _target, promoted: false);
    }

    if (speaking.isEmpty) {
      // Nobody is talking. The last speaker lingers, enlarged, through the pause
      // between turns; only once the lull runs the full [linger] does the view
      // fall back to the overview. (With no target there is nothing to hold.)
      _candidate = null;
      _candidateSince = null;
      if (_target == null) return (target: null, promoted: false);
      _silentSince ??= now;
      if (now.difference(_silentSince!) >= linger) {
        _target = null;
        _silentSince = null;
        return (target: null, promoted: false);
      }
      return (target: _target, promoted: false);
    }

    // Somebody other than the target is talking. Any speech pauses the silence
    // clock, and the newcomer has to hold the floor the full dwell before the
    // view moves — while they count, the last speaker stays big, so the handoff
    // is one face replacing another rather than a bounce through the grid.
    _silentSince = null;

    final next = _pick(speaking);
    if (next != _candidate) {
      _candidate = next;
      _candidateSince = now;
    }

    if (now.difference(_candidateSince!) >= dwell) {
      _target = next;
      _candidate = null;
      _candidateSince = null;
      return (target: _target, promoted: true);
    }

    // Speaking, but not yet long enough to move the view: hold whatever is big
    // now (the lingering last speaker, or the grid if nobody has earned it yet).
    return (target: _target, promoted: false);
  }

  /// Which speaker to count. Stays with whoever is already counting — so a brief
  /// second voice cannot reset the clock on the one who was about to be promoted
  /// — and otherwise takes the lowest id, so the same set always picks the same
  /// person rather than flickering between two.
  String _pick(Set<String> speaking) {
    final current = _candidate;
    if (current != null && speaking.contains(current)) return current;
    return (speaking.toList()..sort()).first;
  }

  /// How long until the pending candidate would be promoted, or null if nobody
  /// is counting. The call screen schedules its one timer off this, so promotion
  /// fires even when no further speaking change arrives to re-ask.
  Duration? timeToPromote(DateTime now) {
    final since = _candidateSince;
    if (since == null) return null;
    final left = dwell - now.difference(since);
    return left.isNegative ? Duration.zero : left;
  }

  /// How long until a silent big view falls back to the grid, or null if it is
  /// not currently lingering. The call screen schedules its one timer off this
  /// too, so the drop happens even when no further speaking change arrives to
  /// re-ask. Mutually exclusive with [timeToPromote]: one needs speech, the
  /// other silence.
  Duration? timeToFallback(DateTime now) {
    final since = _silentSince;
    if (since == null || _target == null) return null;
    final left = linger - now.difference(since);
    return left.isNegative ? Duration.zero : left;
  }

  /// Back to the overview, now. For the return button and for leaving auto mode.
  void reset() {
    _target = null;
    _candidate = null;
    _candidateSince = null;
    _silentSince = null;
  }
}
