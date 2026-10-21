/// A read-only peek at one person's shared calendar.
///
/// Reached by tapping a colleague — from the map's person card or the Warp Dial —
/// this sheet answers "are they free, and when?". It is the same question the Plans
/// tab answers for yourself, pointed at somebody else: their events come from a Google
/// calendar they shared with *this* account, matched by name (Gather carries no email
/// to key on), so a person with nothing shared shows the honest "no shared calendar"
/// rather than a blank the user might read as "free".
///
/// Themed entirely through [context.tokens], so the retro Gameboy palette restyles it
/// with no per-mode code — the same contract the person card and Dial tiles keep.
library;

import 'package:flutter/material.dart';

import '../src/app_state.dart';
import '../src/day_timeline_layout.dart';
import '../src/google_calendar.dart';
import '../theme/gather_theme.dart';
import 'day_timeline.dart';

/// Opens the calendar sheet for the person named [label]. A thin wrapper over
/// `showModalBottomSheet` so both call sites open it identically.
Future<void> showPersonCalendar(
  BuildContext context,
  AppState state,
  String label, {
  String? email,
}) {
  final t = context.tokens;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.card,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) =>
        _PersonCalendarSheet(state: state, label: label, email: email),
  );
}

class _PersonCalendarSheet extends StatelessWidget {
  const _PersonCalendarSheet({
    required this.state,
    required this.label,
    this.email,
  });

  final AppState state;
  final String label;

  /// The colleague's wire calendar email, when the Dial had one — the strong key the
  /// sheet reads by, falling back to the label the map's person card can offer.
  final String? email;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final firstName = label.split(' ').first;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "$firstName's plans",
                style: TextStyle(color: t.foreground, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: FutureBuilder<PersonCalendar>(
                  future: state.calendarForLabel(label, email: email),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final result = snapshot.data;
                    if (result == null ||
                        result.status == CalendarLookup.noCalendar) {
                      return _Hint(
                        icon: Icons.event_busy_outlined,
                        text: '$firstName has not shared a calendar with you.',
                      );
                    }
                    if (result.status == CalendarLookup.unavailable) {
                      // A read that failed — offline or refused — is not an empty
                      // calendar; saying "nothing planned" would be a lie.
                      return _Hint(
                        icon: Icons.cloud_off_outlined,
                        text: 'Couldn’t load $firstName’s calendar. Check your '
                            'connection and try again.',
                      );
                    }
                    final upcoming = [
                      for (final e in result.events) if (!e.isPast) e,
                    ]..sort((a, b) => a.startsAt.compareTo(b.startsAt));
                    if (upcoming.isEmpty) {
                      return _Hint(
                        icon: Icons.event_available_outlined,
                        text: 'Nothing on $firstName’s calendar for the next week.',
                      );
                    }
                    return ListView(
                      shrinkWrap: true,
                      children: _personSections(context, upcoming),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The colleague's week as one [DayTimeline] per day — the same shape the Plans tab
/// draws for yourself, so "when are they free" reads at a glance. Every day from today
/// to the last event they have gets a section; a clear day shows "Free for the day".
List<Widget> _personSections(BuildContext context, List<GoogleEvent> events) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  // Render the queried window, not the span of returned events. `fetchEventsFor` pulls a
  // seven-day window, so draw exactly that: every day in it shows — a day with nothing
  // reads as free — and an event stretching past it (a multi-week all-day banner) is
  // clipped to the window rather than dragging the sheet into days that were never
  // fetched. Stepping by civil date, not +24h, keeps the headers right across DST.
  final windowEnd = DateTime(today.year, today.month, today.day + 7);

  final out = <Widget>[];
  for (var day = today; day.isBefore(windowEnd); day = DateTime(day.year, day.month, day.day + 1)) {
    final dayStart = day;
    final dayEnd = DateTime(day.year, day.month, day.day + 1);
    final timed = <TimelineItem>[];
    final allDay = <TimelineItem>[];
    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      if (!e.startsAt.isBefore(dayEnd) || !e.endsAt.isAfter(dayStart)) continue;
      final item = TimelineItem(
        start: e.startsAt.isBefore(dayStart) ? dayStart : e.startsAt,
        end: e.endsAt.isAfter(dayEnd) ? dayEnd : e.endsAt,
        allDay: e.allDay,
        key: i,
      );
      (e.allDay ? allDay : timed).add(item);
    }
    out.add(_DayHeader(label: _dayLabel(day)));
    out.add(DayTimeline(
      bands: layoutDay(timed, minItemDuration: kTimelineMinSlot),
      allDay: allDay,
      blockBuilder: (ctx, item) => _PersonBlock(event: events[item.key as int]),
    ));
  }
  return out;
}

/// A day label above a colleague's timeline — Today / Tomorrow / a weekday / a date.
class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 2),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: t.mutedForeground,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// A read-only block on a colleague's timeline: their event's title, its time range
/// where the block is tall enough, and its place where there is more room still. Muted —
/// you cannot act on someone else's calendar — but every block taps through to [_EventPeek]
/// for the full detail, which is the only way to read the time off a short event the block
/// is too small to print it on.
class _PersonBlock extends StatelessWidget {
  const _PersonBlock({required this.event});

  final GoogleEvent event;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hasPlace = event.location != null && event.location!.isNotEmpty;
    return Material(
      color: t.secondary,
      child: InkWell(
        onTap: () => _showEventPeek(context, event),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          child: LayoutBuilder(
            builder: (context, c) {
              // Title always; the time appears once the block clears a line for it, the
              // place once there is a line beyond that. A shorter block shows less and the
              // tap fills in the rest, so nothing overflows the lane.
              final showTime = c.maxHeight >= 38;
              final showPlace = c.maxHeight >= 56 && hasPlace;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.foreground, fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.15),
                  ),
                  if (showTime) ...[
                    const SizedBox(height: 1),
                    Text(
                      _eventTime(event),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.mutedForeground,
                        fontSize: 10.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  if (showPlace) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.place_outlined, size: 11, color: t.mutedForeground),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            event.location!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.mutedForeground, fontSize: 10.5),
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

/// A read-only detail card for one of a colleague's events, opened by tapping its block.
/// The block itself may be too short to print the time; this always carries it in full,
/// plus the place when there is one — so a two-line sliver on the grid is still legible.
void _showEventPeek(BuildContext context, GoogleEvent event) {
  final t = context.tokens;
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: t.card,
    showDragHandle: true,
    builder: (context) => _EventPeek(event: event),
  );
}

class _EventPeek extends StatelessWidget {
  const _EventPeek({required this.event});

  final GoogleEvent event;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hasPlace = event.location != null && event.location!.isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
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
            _PeekRow(icon: Icons.schedule, text: '${_dayLabel(event.startsAt)} · ${_eventTime(event)}'),
            if (hasPlace) ...[
              const SizedBox(height: 8),
              _PeekRow(icon: Icons.place_outlined, text: event.location!),
            ],
          ],
        ),
      ),
    );
  }
}

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

/// "09:00 – 10:00", or "All day" for an all-day event.
String _eventTime(GoogleEvent e) =>
    e.allDay ? 'All day' : '${_hm(e.startsAt)} – ${_hm(e.endsAt)}';

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        children: [
          Icon(icon, size: 30, color: t.faint),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: t.mutedForeground, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

/// "Today" / "Tomorrow" / a weekday, to put a loose day beside the time without the
/// sheet needing the Plans tab's full day-headed grouping.
String _dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  if (diff > 1 && diff < 7) return names[d.weekday - 1];
  return '${d.day}/${d.month}';
}
