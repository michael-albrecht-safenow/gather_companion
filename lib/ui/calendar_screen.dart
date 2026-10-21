/// The Plans tab: meetings somebody scheduled ahead of time.
///
/// This is the one screen whose contents Gather knows nothing about. Everything
/// else in the app is a view onto Gather's live state — who is here, what is being
/// said, where people stand. A plan is the opposite: a title and a time the user
/// typed, kept on this phone (see [PlannedMeeting]), because Gather has no calendar
/// of its own to put it in. What it borrows from the rest of the app is the one
/// thing a plan can share with the live office — a *place*. A meeting pinned to a
/// Gather room carries a "Walk here" that hands straight to the same routing the
/// map's "Go here" uses ([AppState.walkToMeeting]).
///
/// Modelled on the Activity tab: a day-headed list under a plain app bar, read
/// above the `Scaffold` so the last row clears the floating rail. Unlike Activity,
/// this list is *writable* — the `+` opens a sheet, and each row edits.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gather_client/gather_client.dart';

import '../src/app_state.dart';
import '../src/calendar.dart';
import '../src/day_timeline_layout.dart';
import '../src/google_calendar.dart';
import '../theme/gather_theme.dart';
import 'day_timeline.dart';

/// The Plans list splits entries into upcoming vs past and labels day headers and the
/// live "Go to meeting" button against the current time. Those checks run on build, but
/// the screen's only other trigger is [AppState] — which an idle space does not notify
/// as the clock moves. So a ticker rebuilds it on its own: once a minute, and on resume,
/// a meeting crosses from upcoming to past, a header flips TODAY→TOMORROW, and the live
/// button appears at the start and clears at the end without needing a roster change.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.state, @visibleForTesting this.clock});

  final AppState state;

  /// The clock the screen reads "now" from — which day is today, which meetings are
  /// past. Defaults to [DateTime.now]; tests inject a fixed instant so a fixture's day
  /// and past/upcoming split don't drift with the wall clock (a meeting pinned to "now"
  /// otherwise crosses midnight when the suite runs late in the day).
  final DateTime Function()? clock;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> with WidgetsBindingObserver {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A minute is finer than any boundary the list draws (whole-minute times, calendar
    // days) and cheap — a rebuild of a short list against unchanged data.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    // Minutes may have passed with the timer paused in the background; catch up at once.
    if (lifecycleState == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final t = context.tokens;
    // Read above the `Scaffold`: the shell folds the rail's height into the bottom
    // padding, which a `Scaffold` body is entitled to take off again. The trailing
    // gap below is what lifts the last card, and the FAB, clear of the dock.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.background,
        title: const Text('Plans'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
        actions: [
          // Only shown when this build carries an OAuth client — otherwise there is
          // nothing to connect to and the action would mislead.
          if (state.googleAvailable) _GoogleButton(state: state),
        ],
      ),
      floatingActionButton: Padding(
        // Lifts the FAB above the floating rail it would otherwise sit under.
        padding: EdgeInsets.only(bottom: bottomInset),
        child: FloatingActionButton(
          backgroundColor: t.brand,
          foregroundColor: t.primaryForeground,
          onPressed: () => _openEditor(context, state, null),
          child: const Icon(Icons.add_rounded),
        ),
      ),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final now = (widget.clock ?? DateTime.now)();
          // One timeline, two sources: plans this phone owns and read-only Google
          // events it only mirrors. Merged and sorted together so a 10am standup from
          // Google and an 11am plan made here sit in one day in the right order.
          final entries = <_Entry>[
            for (final m in state.plannedMeetings) _Entry.plan(state, m),
            for (final e in state.googleEvents) _Entry.google(state, e),
          ];
          final upcoming = [for (final e in entries) if (!e.endsAt.isBefore(now)) e]
            ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
          // Past descending: the most recent is the one worth seeing first.
          final past = [for (final e in entries) if (e.endsAt.isBefore(now)) e]
            ..sort((a, b) => b.startsAt.compareTo(a.startsAt));

          // Offered whenever a Google account could be connected but is not — above
          // the list so it reads as the next thing to do, not buried under it. The
          // app-bar icon does the same, but a tappable row naming what it is for is
          // the discoverable hint; the icon alone is a guess.
          final showConnect = state.googleAvailable && !state.googleConnected;

          if (entries.isEmpty) {
            return ListView(
              padding: EdgeInsets.only(top: 8, bottom: bottomInset + 96),
              children: [
                if (showConnect) _ConnectGoogleBanner(state: state),
                _Empty(bottomInset: bottomInset),
              ],
            );
          }

          return ListView(
            padding: EdgeInsets.only(top: 8, bottom: bottomInset + 96),
            children: [
              if (showConnect) _ConnectGoogleBanner(state: state),
              ..._timelineSections(context, upcoming, now),
              if (past.isNotEmpty) ...[
                const _SectionHeader('EARLIER'),
                for (final e in past) e.build(context, past: true),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Upcoming entries as one day-headed [DayTimeline] per day — the whole point of the
/// redesign. Every day from today to the last day an event touches gets a section, so a
/// clear day shows up as "Free for the day" rather than silently vanishing; a lone
/// event weeks out would otherwise paint a fortnight of empty days, so the horizon is
/// capped and the far event just sits at the end of it.
List<Widget> _timelineSections(BuildContext context, List<_Entry> upcoming, DateTime now) {
  if (upcoming.isEmpty) return const [];
  final today = DateTime(now.year, now.month, now.day);
  final horizon = DateTime(today.year, today.month, today.day + 14);

  // Dense days from today to the horizon, so a clear day shows as "Free for the day"
  // rather than a silent gap — plus every day a real event actually touches beyond the
  // horizon. Capping the empty-day fill keeps a lone far-future meeting from painting a
  // fortnight of blank days, while still giving it its own section so it stays visible
  // and editable (the only way to reach its edit/delete is its block). Stepping by civil
  // date, not +24h, keeps the headers right across a daylight-saving change.
  final days = <DateTime>{};
  for (var day = today; !day.isAfter(horizon); day = DateTime(day.year, day.month, day.day + 1)) {
    days.add(day);
  }
  for (final e in upcoming) {
    var day = DateTime(e.startsAt.year, e.startsAt.month, e.startsAt.day);
    final last = DateTime(e.endsAt.year, e.endsAt.month, e.endsAt.day);
    while (!day.isAfter(last)) {
      if (day.isAfter(horizon)) days.add(day);
      day = DateTime(day.year, day.month, day.day + 1);
    }
  }
  final ordered = days.toList()..sort();

  final out = <Widget>[];
  for (final day in ordered) {
    final dayStart = day;
    final dayEnd = DateTime(day.year, day.month, day.day + 1);
    // Every entry that touches this day, clipped to it — a meeting across midnight or a
    // multi-day all-day event appears on each day it covers, bounded to the day's edges.
    final timed = <TimelineItem>[];
    final allDay = <TimelineItem>[];
    for (var i = 0; i < upcoming.length; i++) {
      final e = upcoming[i];
      if (!e.startsAt.isBefore(dayEnd) || !e.endsAt.isAfter(dayStart)) continue;
      final item = TimelineItem(
        start: e.startsAt.isBefore(dayStart) ? dayStart : e.startsAt,
        end: e.endsAt.isAfter(dayEnd) ? dayEnd : e.endsAt,
        allDay: e.allDay,
        key: i,
      );
      (e.allDay ? allDay : timed).add(item);
    }
    out.add(_SectionHeader(_dayLabel(day, now: now)));
    out.add(DayTimeline(
      bands: layoutDay(timed, minItemDuration: kTimelineMinSlot),
      allDay: allDay,
      blockBuilder: (ctx, item) => upcoming[item.key as int].block(ctx),
    ));
  }
  return out;
}

/// One entry in the merged Plans timeline: either a [PlannedMeeting] this phone owns or
/// a read-only [GoogleEvent] it mirrors. Carries a start, an end, whether it is all-day,
/// a compact [block] for the timeline grid, and the full [build] card still used by the
/// dimmed "EARLIER" past list.
class _Entry {
  _Entry._(this.startsAt, this.endsAt, this.allDay, this._block, this._card);

  factory _Entry.plan(AppState state, PlannedMeeting m) => _Entry._(
        m.startsAt,
        m.endsAt,
        false,
        (context) => _TimelineBlock.plan(state, m),
        (context, {required past}) => _MeetingCard(state: state, meeting: m, past: past),
      );

  factory _Entry.google(AppState state, GoogleEvent e) => _Entry._(
        e.startsAt,
        e.endsAt,
        e.allDay,
        (context) => _TimelineBlock.google(state, e),
        (context, {required past}) => _GoogleEventCard(state: state, event: e, past: past),
      );

  final DateTime startsAt;
  final DateTime endsAt;
  final bool allDay;
  final Widget Function(BuildContext context) _block;
  final Widget Function(BuildContext context, {required bool past}) _card;

  Widget block(BuildContext context) => _block(context);
  Widget build(BuildContext context, {required bool past}) => _card(context, past: past);
}

/// The compact block a timeline lane draws: a title, its time, a place when pinned, and
/// a brand ring while it is live. Filled brand for a plan this phone owns, muted for a
/// read-only Google event, so the two read apart at a glance. Fills whatever height the
/// grid gives it; the time hides on a block too short to hold it.
class _TimelineBlock extends StatelessWidget {
  const _TimelineBlock._({
    required this.title,
    required this.time,
    required this.place,
    required this.live,
    required this.owned,
    required this.onTap,
  });

  factory _TimelineBlock.plan(AppState state, PlannedMeeting m) {
    final now = DateTime.now();
    return _TimelineBlock._(
      title: m.title,
      time: _timeRange(m),
      place: (m.roomName?.isNotEmpty ?? false) ? m.roomName : null,
      live: !m.startsAt.isAfter(now) && m.endsAt.isAfter(now),
      owned: true,
      onTap: (context) => _openEditor(context, state, m),
    );
  }

  factory _TimelineBlock.google(AppState state, GoogleEvent e) {
    final now = DateTime.now();
    final live = !e.startsAt.isAfter(now) && e.endsAt.isAfter(now);
    return _TimelineBlock._(
      title: e.title,
      time: e.allDay ? 'All day' : _googleTimeRange(e),
      place: (e.location?.isNotEmpty ?? false) ? e.location : null,
      live: live,
      owned: false,
      // A Google event is a read-only mirror — there is nothing to edit, so unlike a
      // plan the tap cannot open the editor. Instead it opens a detail peek: the block
      // on the grid may be too short to print the time or place, and this is the only
      // way to read them off. The peek carries the "Go to meeting" walk when the event
      // is live and its location resolves to a room here.
      onTap: (context) => _showGoogleEventPeek(context, state, e),
    );
  }

  final String title;
  final String time;
  final String? place;
  final bool live;
  final bool owned;
  final void Function(BuildContext context) onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bg = owned ? t.brand : t.secondary;
    final fg = owned ? t.primaryForeground : t.foreground;
    return Material(
      color: bg,
      child: InkWell(
        onTap: () => onTap(context),
        child: Container(
          decoration: live
              ? BoxDecoration(
                  border: Border.all(color: t.brand, width: 2),
                  borderRadius: BorderRadius.circular(t.radius),
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          child: LayoutBuilder(
            builder: (context, c) {
              // A short block holds only the title; the time and then the place appear
              // as it grows. The thresholds leave headroom so a block never overflows
              // its lane — the rows are laid out, not scrolled.
              final showTime = c.maxHeight >= 42;
              final showPlace = c.maxHeight >= 66 && place != null;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: fg, fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.15),
                  ),
                  if (showTime) ...[
                    const SizedBox(height: 1),
                    Text(
                      time,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.82),
                        fontSize: 10.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  if (showPlace) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.place_outlined, size: 11, color: fg.withValues(alpha: 0.7)),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            place!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 10.5),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The Plans tab's Google connection, as an app-bar action. A cloud-off icon offers
/// to connect; once connected it turns to a menu that refreshes or disconnects. A
/// spinner while the consent sheet or a refresh is in flight.
class _GoogleButton extends StatefulWidget {
  const _GoogleButton({required this.state});

  final AppState state;

  @override
  State<_GoogleButton> createState() => _GoogleButtonState();
}

class _GoogleButtonState extends State<_GoogleButton> {
  bool _busy = false;

  Future<void> _connect() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final error = await widget.state.connectGoogle();
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    await widget.state.refreshGoogleEvents();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (!widget.state.googleConnected) {
      return IconButton(
        tooltip: 'Connect Google Calendar',
        icon: const Icon(Icons.event_available_outlined),
        onPressed: _connect,
      );
    }
    return PopupMenuButton<String>(
      tooltip: 'Google Calendar',
      icon: Icon(Icons.event_available, color: t.brand),
      color: t.popover,
      onSelected: (value) {
        if (value == 'refresh') _refresh();
        if (value == 'disconnect') widget.state.disconnectGoogle();
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'refresh', child: Text('Refresh', style: TextStyle(color: t.foreground))),
        PopupMenuItem(value: 'disconnect', child: Text('Disconnect Google', style: TextStyle(color: t.foreground))),
      ],
    );
  }
}

/// A read-only Google event. Shaped like [_MeetingCard] so the two read as one list,
/// but with no walk and no delete — this phone does not own it — and a small Google
/// marker so it is clear where it came from. All-day events show their day, not a
/// 00:00 time.
class _GoogleEventCard extends StatelessWidget {
  const _GoogleEventCard({required this.state, required this.event, required this.past});

  final AppState state;
  final GoogleEvent event;
  final bool past;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hasPlace = event.location != null && event.location!.isNotEmpty;
    // Offered only while the meeting is actually on and its location is a Gather link
    // naming a room in this space — the approved "else do nothing". A past or future
    // event, or a link to somewhere a single walk cannot reach, carries no button.
    final now = DateTime.now();
    final isLive = !past &&
        !event.startsAt.isAfter(now) &&
        event.endsAt.isAfter(now);
    final canWarp = isLive && state.canGoToMeeting(event);

    return Opacity(
      opacity: past ? 0.55 : 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kTextGutter, 4, kTextGutter, 4),
        child: Material(
          color: t.card,
          borderRadius: BorderRadius.circular(t.radius),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        event.title,
                        style: TextStyle(color: t.foreground, fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      event.allDay ? 'All day' : _googleTimeRange(event),
                      style: TextStyle(
                        color: t.faint,
                        fontSize: 13,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                if (hasPlace) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.place_outlined, size: 15, color: t.mutedForeground),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          event.location!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.mutedForeground, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.event_available, size: 13, color: t.faint),
                    const SizedBox(width: 4),
                    Text('Google Calendar', style: TextStyle(color: t.faint, fontSize: 12)),
                  ],
                ),
                if (canWarp) ...[
                  const SizedBox(height: 10),
                  _GoToMeetingButton(state: state, event: event),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Go to meeting" action on a live Google event whose Gather link resolves to a
/// room here — walks the user straight in with [AppState.walkToGoogleEvent], the same
/// routing "Walk here" uses. A spinner while the hop runs; a snack when the room has
/// slipped off the floor plan since the card was built.
class _GoToMeetingButton extends StatefulWidget {
  const _GoToMeetingButton({required this.state, required this.event, this.dismissFirst = false});

  final AppState state;
  final GoogleEvent event;

  /// When true the button lives inside a modal (the peek) that sits above the
  /// Scaffold the snack would land on. The sheet is popped before the result shows,
  /// so a walk failure or an "Asked to join…" reply isn't hidden behind it — the same
  /// path [_MeetingEditorState._walkFromEditor] takes from its sheet.
  final bool dismissFirst;

  @override
  State<_GoToMeetingButton> createState() => _GoToMeetingButtonState();
}

class _GoToMeetingButtonState extends State<_GoToMeetingButton> {
  bool _busy = false;

  Future<void> _go() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    final error = await widget.state.walkToGoogleEvent(widget.event);
    if (!mounted) return;
    setState(() => _busy = false);
    if (widget.dismissFirst) navigator.pop();
    if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.brand,
      borderRadius: BorderRadius.circular(t.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radius),
        onTap: _busy ? null : _go,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy)
                SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2, color: t.primaryForeground),
                )
              else
                Icon(Icons.meeting_room_rounded, size: 16, color: t.primaryForeground),
              const SizedBox(width: 6),
              Text(
                'Go to meeting',
                style: TextStyle(color: t.primaryForeground, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A read-only detail peek for one mirrored Google event, opened by tapping its timeline
/// block. A Google event cannot be edited here — it is a mirror of a calendar this phone
/// does not own — so the tap that would open the editor on a plan opens this instead: the
/// full title, the exact day and time, the place when there is one, and the same "Go to
/// meeting" walk the live block used to carry, when the event is on and resolves to a room.
void _showGoogleEventPeek(BuildContext context, AppState state, GoogleEvent event) {
  final t = context.tokens;
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.card,
    showDragHandle: true,
    builder: (context) => _GoogleEventPeek(state: state, event: event),
  );
}

class _GoogleEventPeek extends StatelessWidget {
  const _GoogleEventPeek({required this.state, required this.event});

  final AppState state;
  final GoogleEvent event;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hasPlace = event.location != null && event.location!.isNotEmpty;
    // Offered whenever the event's location resolves to a room on the floor here — not
    // only while it is live. Matches the own-plan editor, whose "Walk here" shows the
    // moment a room is pinned, so a meeting you want to head to early is reachable.
    final canWarp = state.canGoToMeeting(event);
    final when = _peekWhen(event);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              event.title,
              style: TextStyle(color: t.foreground, fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            _PeekRow(icon: Icons.schedule, text: when),
            if (hasPlace) ...[
              const SizedBox(height: 8),
              _PeekRow(icon: Icons.place_outlined, text: event.location!),
            ],
            const SizedBox(height: 8),
            _PeekRow(icon: Icons.event_available, text: 'Google Calendar'),
            if (canWarp) ...[
              const SizedBox(height: 16),
              _GoToMeetingButton(state: state, event: event, dismissFirst: true),
            ],
          ],
        ),
      ),
    );
  }
}

/// A line in the Google event peek: an icon beside its text, sharing the look the
/// colleague calendar's peek uses so the two read as one thing.
class _PeekRow extends StatelessWidget {
  const _PeekRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: t.mutedForeground),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: TextStyle(color: t.foreground, fontSize: 14)),
        ),
      ],
    );
  }
}

/// "Today" / "Tomorrow" / a weekday / a date, to set the peek's time in a day.
String _peekDay(DateTime at) {
  final delta = _calendarDaysUntil(at);
  if (delta == 0) return 'Today';
  if (delta == 1) return 'Tomorrow';
  if (delta > 1 && delta < 7) return _weekdays[at.weekday - 1];
  return '${at.day} ${_months[at.month - 1]}';
}

String _googleTimeRange(GoogleEvent e) => '${_time(e.startsAt)}–${_time(e.endsAt)}';

/// The peek's one-line "when". A same-day event reads its day once ("Today · 09:00–10:00"
/// or "Today · All day"); an event that crosses days spells out both ends so an overnight
/// meeting isn't mistaken for a one-hour one and a multi-day span shows its length.
///
/// Google gives all-day events an *exclusive* end — a single Monday all-day event ends at
/// Tuesday 00:00 — so the last day shown is the day before [GoogleEvent.endsAt] for all-day
/// events, which also collapses the common one-day case back to "Today · All day".
String _peekWhen(GoogleEvent e) {
  final startDay = _peekDay(e.startsAt);
  if (e.allDay) {
    final lastDay = e.endsAt.subtract(const Duration(days: 1));
    final sameDay = _isSameCalendarDay(e.startsAt, lastDay);
    return sameDay
        ? '$startDay · All day'
        : '$startDay – ${_peekDay(lastDay)} · All day';
  }
  if (_isSameCalendarDay(e.startsAt, e.endsAt)) {
    return '$startDay · ${_googleTimeRange(e)}';
  }
  return '$startDay ${_time(e.startsAt)} – ${_peekDay(e.endsAt)} ${_time(e.endsAt)}';
}

bool _isSameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

class _Empty extends StatelessWidget {
  const _Empty({required this.bottomInset});

  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.fromLTRB(32, 48, 32, 24 + bottomInset),
      child: Center(
        child: Text(
          'No plans yet.\nTap + to schedule a meeting and get a reminder before it starts.',
          textAlign: TextAlign.center,
          style: TextStyle(color: t.mutedForeground, height: 1.5),
        ),
      ),
    );
  }
}

/// The tappable hint shown in the Plans tab when a Google account could be connected
/// but is not. The app-bar icon connects too, but this row names what it does — the
/// discoverable version of the same action. Carries its own busy state so the whole
/// row shows a spinner while the consent sheet is up.
class _ConnectGoogleBanner extends StatefulWidget {
  const _ConnectGoogleBanner({required this.state});

  final AppState state;

  @override
  State<_ConnectGoogleBanner> createState() => _ConnectGoogleBannerState();
}

class _ConnectGoogleBannerState extends State<_ConnectGoogleBanner> {
  bool _busy = false;

  Future<void> _connect() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final error = await widget.state.connectGoogle();
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 8, kTextGutter, 8),
      child: Material(
        color: t.card,
        borderRadius: BorderRadius.circular(t.radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(t.radius),
          onTap: _busy ? null : _connect,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.event_available_outlined, color: t.brand, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connect Google Calendar',
                        style: TextStyle(color: t.foreground, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'See the meetings you already have, right here.',
                        style: TextStyle(color: t.mutedForeground, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (_busy)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Icon(Icons.chevron_right_rounded, color: t.mutedForeground),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kTextGutter, 16, kTextGutter, 8),
      child: Text(
        label,
        style: TextStyle(
          color: t.mutedForeground,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// One planned meeting. Tapping the body edits it; the two actions below walk you
/// to its room and delete it. A past meeting is dimmed and keeps only its delete —
/// there is nowhere to be walked to for something that already happened.
class _MeetingCard extends StatelessWidget {
  const _MeetingCard({required this.state, required this.meeting, required this.past});

  final AppState state;
  final PlannedMeeting meeting;
  final bool past;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hasRoom = meeting.roomName != null && meeting.roomName!.isNotEmpty;

    return Opacity(
      opacity: past ? 0.55 : 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kTextGutter, 4, kTextGutter, 4),
        child: Material(
          color: t.card,
          borderRadius: BorderRadius.circular(t.radius),
          child: InkWell(
            borderRadius: BorderRadius.circular(t.radius),
            onTap: () => _openEditor(context, state, meeting),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          meeting.title,
                          style: TextStyle(color: t.foreground, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _timeRange(meeting),
                        style: TextStyle(
                          color: t.faint,
                          fontSize: 13,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  if (hasRoom) ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.place_outlined, size: 15, color: t.mutedForeground),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            meeting.roomName!,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.mutedForeground, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (!past && hasRoom)
                        _Action(
                          icon: Icons.directions_walk_rounded,
                          label: 'Walk here',
                          onTap: () => _walk(context),
                        ),
                      const Spacer(),
                      _Action(
                        icon: Icons.delete_outline_rounded,
                        label: 'Delete',
                        tint: t.danger,
                        onTap: () => _delete(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _walk(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await state.walkToMeeting(meeting);
    messenger.showSnackBar(SnackBar(
      content: Text(error ?? 'On your way to ${meeting.roomName}.'),
    ));
  }

  Future<void> _delete(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await state.deleteMeeting(meeting.id);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}

/// One of a card's inline actions: an icon with a word, flat, in the accent or a
/// given tint. Small enough that two sit on one line under the title.
class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.tint});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final colour = tint ?? t.brand;
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: colour,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

/// Opens the create/edit sheet. [existing] null means a new meeting.
Future<void> _openEditor(BuildContext context, AppState state, PlannedMeeting? existing) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.tokens.popover,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => _MeetingEditor(state: state, existing: existing),
  );
}

/// The create/edit sheet. A title, a day and time, a length, an optional Gather
/// room to pin it to, and how long before to be reminded. Lifts above the keyboard
/// while the title is being typed.
class _MeetingEditor extends StatefulWidget {
  const _MeetingEditor({required this.state, required this.existing});

  final AppState state;
  final PlannedMeeting? existing;

  @override
  State<_MeetingEditor> createState() => _MeetingEditorState();
}

class _MeetingEditorState extends State<_MeetingEditor> {
  late final TextEditingController _title =
      TextEditingController(text: widget.existing?.title ?? '');
  late DateTime _start = widget.existing?.startsAt ?? _defaultStart();
  late int _durationMinutes = widget.existing == null
      ? 30
      : widget.existing!.endsAt.difference(widget.existing!.startsAt).inMinutes.clamp(5, 480);
  late String? _roomStableId = widget.existing?.roomStableId;
  late int _remindMinutes = widget.existing?.remindMinutesBefore ?? 5;
  bool _saving = false;

  /// The next round half-hour: the overwhelmingly common thing to want, so it is
  /// what the pickers open on.
  static DateTime _defaultStart() {
    final now = DateTime.now();
    final rounded = DateTime(now.year, now.month, now.day, now.hour).add(
      Duration(minutes: now.minute < 30 ? 30 : 60),
    );
    return rounded;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // The sheet rides above the keyboard rather than being covered by it.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final rooms = widget.state.plannableRooms;
    final editing = widget.existing != null;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + keyboard),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: t.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(
              editing ? 'Edit meeting' : 'New meeting',
              style: TextStyle(color: t.foreground, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: !editing,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(color: t.foreground),
              decoration: InputDecoration(
                hintText: 'What is it?',
                hintStyle: TextStyle(color: t.faint),
                filled: true,
                fillColor: t.secondary,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(t.radius),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _Field(
              label: 'When',
              child: _PickerButton(
                text: '${_dayLabelFull(_start)}, ${_time(_start)}',
                onTap: _pickWhen,
              ),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'Length',
              child: _DurationPicker(
                minutes: _durationMinutes,
                onChanged: (m) => setState(() => _durationMinutes = m),
              ),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'Where',
              child: _RoomPicker(
                rooms: rooms,
                selectedStableId: _roomStableId,
                onChanged: (id) => setState(() => _roomStableId = id),
              ),
            ),
            const SizedBox(height: 12),
            _Field(
              label: 'Remind me',
              child: _ReminderPicker(
                minutes: _remindMinutes,
                onChanged: (m) => setState(() => _remindMinutes = m),
              ),
            ),
            // Walk and delete used to live on the meeting's list card. The timeline
            // draws a compact block with no room for them, so they move here — the one
            // place an existing meeting is already open for action.
            if (editing) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  if (widget.existing!.roomName?.isNotEmpty ?? false)
                    _Action(
                      icon: Icons.directions_walk_rounded,
                      label: 'Walk here',
                      onTap: _walkFromEditor,
                    ),
                  const Spacer(),
                  _Action(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete',
                    tint: t.danger,
                    onTap: _deleteFromEditor,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: t.brand,
                  foregroundColor: t.primaryForeground,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _saving ? null : _save,
                child: Text(editing ? 'Save changes' : 'Add meeting'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickWhen() async {
    // The usual range is yesterday to a year out, but a meeting being edited can sit
    // outside it — an old one from before yesterday, or (in theory) one beyond the
    // year. showDatePicker asserts initialDate is within [firstDate, lastDate], so
    // the window is widened to take in the existing value rather than crash on it.
    final now = DateTime.now();
    final low = now.subtract(const Duration(days: 1));
    final high = now.add(const Duration(days: 365));
    final date = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: _start.isBefore(low) ? _start : low,
      lastDate: _start.isAfter(high) ? _start : high,
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
    );
    if (time == null || !mounted) return;
    setState(() {
      _start = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final title = _title.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    if (title.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Give the meeting a name.')));
      return;
    }
    setState(() => _saving = true);

    // Resolve the chosen room off the live map so its label and floor travel with
    // the plan — the map may be gone by the time the meeting is walked to.
    final room = _resolveRoom(_roomStableId);
    final existing = widget.existing;

    // A chosen room the live map cannot resolve right now (the map is gone, or the
    // room is on a floor not loaded) must not silently wipe the place an edited
    // meeting already carried. Clearing the location is reserved for the user
    // explicitly picking "No place" — which is `_roomStableId == null`. So when the
    // picker still names the same id the meeting was saved with but it will not
    // resolve, keep the stored room, floor and fallback coordinates untouched.
    final keepSaved = room == null &&
        _roomStableId != null &&
        existing != null &&
        existing.roomStableId == _roomStableId;

    final meeting = PlannedMeeting(
      id: existing?.id ?? _newId(),
      title: title,
      startsAt: _start,
      endsAt: _start.add(Duration(minutes: _durationMinutes)),
      roomStableId: keepSaved ? existing.roomStableId : room?.stableId,
      roomName: keepSaved ? existing.roomName : room?.name,
      floorId: keepSaved
          ? existing.floorId
          : (room == null ? null : widget.state.map?.floorId),
      x: keepSaved ? existing.x : null,
      y: keepSaved ? existing.y : null,
      remindMinutesBefore: _remindMinutes,
      deviceEventId: existing?.deviceEventId,
    );

    final error = existing == null
        ? await widget.state.addMeeting(meeting)
        : await widget.state.updateMeeting(meeting);
    if (!mounted) return;
    if (error != null) {
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    navigator.pop();
  }

  SpaceRoom? _resolveRoom(String? stableId) {
    if (stableId == null) return null;
    for (final room in widget.state.plannableRooms) {
      if (room.stableId == stableId) return room;
    }
    return null;
  }

  /// Walks to the meeting being edited, then closes the sheet — the same hop the list
  /// card's "Walk here" ran, now that the timeline block hands off to this sheet.
  Future<void> _walkFromEditor() async {
    if (_saving) return;
    final existing = widget.existing!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final error = await widget.state.walkToMeeting(existing);
    if (!mounted) return;
    navigator.pop();
    messenger.showSnackBar(SnackBar(
      content: Text(error ?? 'On your way to ${existing.roomName}.'),
    ));
  }

  /// Deletes the meeting being edited and closes the sheet; a failure keeps the sheet
  /// open with the reason.
  Future<void> _deleteFromEditor() async {
    // Share the save busy flag so delete and save can't overlap: a delete mid-save could
    // race `updateMeeting`'s calendar-mirror await and overwrite or resurrect a meeting.
    // The Save button already disables on `_saving`; this closes the other direction.
    if (_saving) return;
    setState(() => _saving = true);
    final existing = widget.existing!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final error = await widget.state.deleteMeeting(existing.id);
    if (!mounted) return;
    if (error != null) {
      setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    navigator.pop();
  }
}

String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

/// A labelled row in the editor: a caption over its control.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(color: t.mutedForeground, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.5),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// A flat field-shaped button that opens a picker — used for the date/time row.
class _PickerButton extends StatelessWidget {
  const _PickerButton({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: t.secondary,
      borderRadius: BorderRadius.circular(t.radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(t.radius),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.schedule_rounded, size: 18, color: t.mutedForeground),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: TextStyle(color: t.foreground, fontSize: 15))),
            ],
          ),
        ),
      ),
    );
  }
}

class _DurationPicker extends StatelessWidget {
  const _DurationPicker({required this.minutes, required this.onChanged});

  final int minutes;
  final ValueChanged<int> onChanged;

  static const _options = [15, 30, 45, 60, 90, 120];

  @override
  Widget build(BuildContext context) {
    // A duration not on the shortlist (an edited meeting of an odd length) still
    // shows, added to the choices so the menu can render it.
    final options = {..._options, minutes}.toList()..sort();
    return _Dropdown<int>(
      value: minutes,
      items: [for (final m in options) (m, _durationLabel(m))],
      onChanged: onChanged,
    );
  }
}

class _ReminderPicker extends StatelessWidget {
  const _ReminderPicker({required this.minutes, required this.onChanged});

  final int minutes;
  final ValueChanged<int> onChanged;

  static const _options = [0, 5, 10, 15, 30, 60];

  @override
  Widget build(BuildContext context) {
    final options = {..._options, minutes}.toList()..sort();
    return _Dropdown<int>(
      value: minutes,
      items: [for (final m in options) (m, m == 0 ? 'At start time' : '${_durationLabel(m)} before')],
      onChanged: onChanged,
    );
  }
}

/// The room picker. Empty when the office has not loaded — a plan can still be made
/// without a place, and pinned later once there is a floor plan to pin it to.
class _RoomPicker extends StatelessWidget {
  const _RoomPicker({required this.rooms, required this.selectedStableId, required this.onChanged});

  final List<SpaceRoom> rooms;
  final String? selectedStableId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (rooms.isEmpty) {
      return Text(
        selectedStableId == null
            ? 'No place — connect to the office to pin a room.'
            : 'Room saved; connect to the office to change it.',
        style: TextStyle(color: t.faint, fontSize: 13),
      );
    }
    return _Dropdown<String?>(
      value: rooms.any((r) => r.stableId == selectedStableId) ? selectedStableId : null,
      items: [
        (null, 'No place'),
        for (final room in rooms)
          if (room.stableId != null) (room.stableId, room.name ?? 'Room'),
      ],
      onChanged: onChanged,
    );
  }
}

/// A field-shaped dropdown sharing the pickers' look, generic over its value.
class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.value, required this.items, required this.onChanged});

  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: t.secondary, borderRadius: BorderRadius.circular(t.radius)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          dropdownColor: t.popover,
          iconEnabledColor: t.mutedForeground,
          style: TextStyle(color: t.foreground, fontSize: 15),
          items: [
            for (final (v, label) in items)
              DropdownMenuItem<T>(value: v, child: Text(label)),
          ],
          onChanged: (v) {
            if (v != null || null is T) onChanged(v as T);
          },
        ),
      ),
    );
  }
}

// ---- formatting ------------------------------------------------------------

String _timeRange(PlannedMeeting m) => '${_time(m.startsAt)}–${_time(m.endsAt)}';

String _time(DateTime at) {
  final h = at.hour.toString().padLeft(2, '0');
  final m = at.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String _durationLabel(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (m == 0) return h == 1 ? '1 hour' : '$h hours';
  return '${h}h ${m}m';
}

/// Whole calendar days from today to [at]'s date, counted as calendar ordinals.
///
/// The dates are rebuilt in UTC purely to subtract them: a local-midnight
/// subtraction measures elapsed *duration*, and a spring-forward day is only 23
/// hours, so `inDays` truncates tomorrow to 0 and the header says TODAY. UTC days
/// are all 24 hours, so the difference is the number of calendar days regardless of
/// any daylight-saving step in between.
int _calendarDaysUntil(DateTime at, {DateTime? now}) {
  final day = DateTime.utc(at.year, at.month, at.day);
  final ref = now ?? DateTime.now();
  final today = DateTime.utc(ref.year, ref.month, ref.day);
  return day.difference(today).inDays;
}

/// Short day label for the list headers — TODAY / TOMORROW / weekday / date.
String _dayLabel(DateTime at, {DateTime? now}) {
  final delta = _calendarDaysUntil(at, now: now);
  if (delta == 0) return 'TODAY';
  if (delta == 1) return 'TOMORROW';
  if (delta > 1 && delta < 7) return _weekdays[at.weekday - 1].toUpperCase();
  return '${at.day} ${_months[at.month - 1]} ${at.year}'.toUpperCase();
}

/// Longer day label for the editor's When button — "Today", "Tomorrow", or a date.
String _dayLabelFull(DateTime at) {
  final delta = _calendarDaysUntil(at);
  if (delta == 0) return 'Today';
  if (delta == 1) return 'Tomorrow';
  return '${_weekdays[at.weekday - 1]} ${at.day} ${_months[at.month - 1]}';
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
