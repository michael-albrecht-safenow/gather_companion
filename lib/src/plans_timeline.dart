/// What the Plans tab shows and what its editor saves, decided without a widget
/// (plan task 4.3).
///
/// The Plans screen (`lib/ui/calendar_screen.dart`) used to work all of this out
/// inside `build` and its sheet's State: which entries are upcoming and which are
/// past, which days get a section (a clear day must read "Free for the day", not
/// vanish), how a meeting across midnight is clipped onto each day it touches,
/// what the editor opens on, and — the one that cost a bug — what an edited plan
/// keeps when its pinned room will not resolve off the live map. None of that is
/// drawing. It is arithmetic on instants and a rule about not wiping a saved
/// place, and a rule that lives in a widget can only be checked by pumping one and
/// reading text off the glass. So it lives here, the screen turns its output into
/// pixels, and the debug drive's `plans.state` reads the very same days the
/// timeline draws instead of a second reckoning of them.
///
/// The overlap/lane/free-gap maths was already out of the widget, in
/// `day_timeline_layout.dart`; [planDays] hands each day to [layoutDay] unchanged.
///
/// What stays in the screen is presentation: the minute ticker that rebuilds as
/// the clock moves, the busy spinners, the snackbars, the pickers, and every
/// label's wording.
library;

import 'package:gather_client/gather_client.dart' show SpaceRoom;

import 'calendar.dart';
import 'day_timeline_layout.dart';
import 'google_calendar.dart';

/// One entry on the merged Plans timeline: a plan this phone owns, or a Google
/// event it only mirrors. One timeline, two sources, merged and sorted together so a
/// 10am standup from Google and an 11am plan made here sit in one day in order.
sealed class PlanEntry {
  const PlanEntry();

  DateTime get startsAt;
  DateTime get endsAt;
  bool get allDay;

  /// Whether the entry is on at [now]: started (inclusive) and not yet ended.
  bool liveAt(DateTime now) => isLiveAt(startsAt, endsAt, now);
}

/// A [PlannedMeeting] — writable here, never all-day.
final class OwnPlanEntry extends PlanEntry {
  const OwnPlanEntry(this.meeting);

  final PlannedMeeting meeting;

  @override
  DateTime get startsAt => meeting.startsAt;
  @override
  DateTime get endsAt => meeting.endsAt;
  @override
  bool get allDay => false;
}

/// A read-only [GoogleEvent].
final class GoogleEntry extends PlanEntry {
  const GoogleEntry(this.event);

  final GoogleEvent event;

  @override
  DateTime get startsAt => event.startsAt;
  @override
  DateTime get endsAt => event.endsAt;
  @override
  bool get allDay => event.allDay;
}

/// Whether something running [start]–[end] is on at [now]: the start counts, the end
/// does not — the live ring and "Go to meeting" appear at the start and clear at the
/// end.
bool isLiveAt(DateTime start, DateTime end, DateTime now) => !start.isAfter(now) && end.isAfter(now);

/// The Plans list split at [now]: every entry ([all], plans first then Google, the
/// order they were merged in), the [upcoming] ones by start, and the [past] ones —
/// ended before [now] — most recent first, because that is the one worth seeing first.
/// An entry ending exactly at [now] is still upcoming.
({List<PlanEntry> all, List<PlanEntry> upcoming, List<PlanEntry> past}) splitPlans(
  List<PlannedMeeting> plans,
  List<GoogleEvent> events,
  DateTime now,
) {
  final all = <PlanEntry>[
    for (final m in plans) OwnPlanEntry(m),
    for (final e in events) GoogleEntry(e),
  ];
  final upcoming = [for (final e in all) if (!e.endsAt.isBefore(now)) e]
    ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  final past = [for (final e in all) if (e.endsAt.isBefore(now)) e]
    ..sort((a, b) => b.startsAt.compareTo(a.startsAt));
  return (all: all, upcoming: upcoming, past: past);
}

/// How far the timeline fills empty days: today plus this many.
const int kPlansHorizonDays = 14;

/// One day section of the timeline. [timed] and [allDay] carry each entry clipped to
/// the day, keyed by its index in the `upcoming` list [planDays] was given; [bands] is
/// [layoutDay] of [timed] — busy clusters and the free gaps between them. No bands is
/// "free for the day".
class PlanDay {
  const PlanDay({required this.day, required this.timed, required this.allDay, required this.bands});

  /// Local midnight.
  final DateTime day;
  final List<TimelineItem> timed;
  final List<TimelineItem> allDay;
  final List<Band> bands;
}

/// The day sections for [upcoming] (sorted by start, as [splitPlans] gives them).
///
/// Every day from today to the horizon ([kPlansHorizonDays]) gets a section, so a
/// clear day shows as "Free for the day" rather than a silent gap — plus every day a
/// real entry touches beyond the horizon. Capping the empty-day fill keeps a lone
/// far-future meeting from painting a fortnight of blank days, while still giving it
/// its own section so it stays visible and editable (the only way to reach its edit
/// is its block). Stepping by civil date, not +24h, keeps the days right across a
/// daylight-saving change. An entry across midnight, or a multi-day all-day event,
/// appears on each day it covers, clipped to the day's edges.
///
/// Nothing upcoming is no sections at all: the screen then shows only the past list.
/// [minItemDuration] is passed to [layoutDay] — the least time a block occupies on
/// screen ([kTimelineMinSlot]).
List<PlanDay> planDays(
  List<PlanEntry> upcoming,
  DateTime now, {
  Duration minItemDuration = kTimelineMinSlot,
}) {
  if (upcoming.isEmpty) return const [];
  final today = DateTime(now.year, now.month, now.day);
  final horizon = DateTime(today.year, today.month, today.day + kPlansHorizonDays);

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

  return [
    for (final day in ordered) _planDay(upcoming, day, minItemDuration),
  ];
}

PlanDay _planDay(List<PlanEntry> upcoming, DateTime day, Duration minItemDuration) {
  final dayStart = day;
  final dayEnd = DateTime(day.year, day.month, day.day + 1);
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
  return PlanDay(
    day: day,
    timed: timed,
    allDay: allDay,
    bands: layoutDay(timed, minItemDuration: minItemDuration),
  );
}

// ---- the editor ------------------------------------------------------------

/// The next round half-hour after [now]: the overwhelmingly common thing to want, so
/// it is what a new meeting's pickers open on.
DateTime defaultPlanStart(DateTime now) =>
    DateTime(now.year, now.month, now.day, now.hour).add(Duration(minutes: now.minute < 30 ? 30 : 60));

/// The length the editor opens on: 30 minutes for a new meeting, the meeting's own
/// (clamped to 5 min – 8 h) for an edit.
int initialPlanMinutes(PlannedMeeting? existing) =>
    existing == null ? 30 : existing.endsAt.difference(existing.startsAt).inMinutes.clamp(5, 480);

/// The date picker's range for a meeting starting at [start]: usually yesterday to a
/// year out, widened to take in [start] when an edited meeting sits outside it —
/// `showDatePicker` asserts its initial date is within the range, and would crash on
/// an old one rather than show it.
({DateTime first, DateTime last}) planDateWindow(DateTime start, DateTime now) {
  final low = now.subtract(const Duration(days: 1));
  final high = now.add(const Duration(days: 365));
  return (first: start.isBefore(low) ? start : low, last: start.isAfter(high) ? start : high);
}

/// The room in [rooms] with [stableId], or null for none chosen or none that
/// resolves.
SpaceRoom? resolvePlanRoom(List<SpaceRoom> rooms, String? stableId) {
  if (stableId == null) return null;
  for (final room in rooms) {
    if (room.stableId == stableId) return room;
  }
  return null;
}

/// The [PlannedMeeting] the editor saves.
///
/// [room] is [roomStableId] resolved off the live map now ([resolvePlanRoom]), so its
/// label and [liveFloorId] travel with the plan — the map may be gone by the time the
/// meeting is walked to.
///
/// The rule that matters: a chosen room the live map cannot resolve right now (the
/// map is gone, or the room is on a floor not loaded) must not silently wipe the
/// place an edited meeting already carried. Clearing the place is reserved for the
/// user explicitly picking "No place" — [roomStableId] null. So when the picker still
/// names the id [existing] was saved with but it will not resolve, the stored room,
/// floor and fallback coordinates are kept untouched.
///
/// [title] is used as given; the editor refuses an empty one before calling this.
PlannedMeeting composePlannedMeeting({
  required PlannedMeeting? existing,
  required String newId,
  required String title,
  required DateTime start,
  required int durationMinutes,
  required String? roomStableId,
  required SpaceRoom? room,
  required String? liveFloorId,
  required int remindMinutes,
}) {
  final keepSaved = room == null && roomStableId != null && existing != null && existing.roomStableId == roomStableId;
  return PlannedMeeting(
    id: existing?.id ?? newId,
    title: title,
    startsAt: start,
    endsAt: start.add(Duration(minutes: durationMinutes)),
    roomStableId: keepSaved ? existing.roomStableId : room?.stableId,
    roomName: keepSaved ? existing.roomName : room?.name,
    floorId: keepSaved ? existing.floorId : (room == null ? null : liveFloorId),
    x: keepSaved ? existing.x : null,
    y: keepSaved ? existing.y : null,
    remindMinutesBefore: remindMinutes,
    deviceEventId: existing?.deviceEventId,
  );
}
