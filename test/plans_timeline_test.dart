/// The Plans tab's decisions, without a widget: which entries are upcoming and
/// which past, which days get a section and what each holds, and what the editor
/// opens on and saves — in particular that an unresolvable pinned room never wipes
/// the place an edited meeting already carried.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart' show SpaceRoom;
import 'package:gather_companion/src/calendar.dart';
import 'package:gather_companion/src/day_timeline_layout.dart';
import 'package:gather_companion/src/google_calendar.dart';
import 'package:gather_companion/src/plans_timeline.dart';

void main() {
  final now = DateTime(2025, 6, 17, 9, 0); // a Tuesday, mid-morning

  PlannedMeeting plan(String id, DateTime start, Duration length, {String? room}) => PlannedMeeting(
        id: id,
        title: id,
        startsAt: start,
        endsAt: start.add(length),
        roomStableId: room == null ? null : 'stable-$room',
        roomName: room,
      );

  GoogleEvent google(String id, DateTime start, DateTime end, {bool allDay = false}) =>
      GoogleEvent(id: id, title: id, startsAt: start, endsAt: end, allDay: allDay);

  SpaceRoom room(String stableId, String name) => SpaceRoom(
        id: 'area-$stableId',
        name: name,
        type: 'room',
        x: 0,
        y: 0,
        width: 4,
        height: 4,
        walled: true,
        stableId: stableId,
      );

  group('splitPlans', () {
    test('merges plans then Google, upcoming by start, past most recent first', () {
      final split = splitPlans(
        [
          plan('late', now.add(const Duration(hours: 3)), const Duration(minutes: 30)),
          plan('old', now.subtract(const Duration(days: 2)), const Duration(minutes: 30)),
        ],
        [
          google('soon', now.add(const Duration(hours: 1)), now.add(const Duration(hours: 2))),
          google('yesterday', now.subtract(const Duration(days: 1)),
              now.subtract(const Duration(days: 1)).add(const Duration(hours: 1))),
        ],
        now,
      );
      String id(PlanEntry e) => switch (e) {
            OwnPlanEntry(:final meeting) => meeting.id,
            GoogleEntry(:final event) => event.id,
          };
      expect(split.all.map(id), ['late', 'old', 'soon', 'yesterday']);
      expect(split.upcoming.map(id), ['soon', 'late']);
      expect(split.past.map(id), ['yesterday', 'old']);
    });

    test('an entry ending exactly now is still upcoming; one ended a moment ago is past', () {
      final split = splitPlans([
        plan('endsNow', now.subtract(const Duration(hours: 1)), const Duration(hours: 1)),
        plan('ended', now.subtract(const Duration(hours: 1)), const Duration(minutes: 59)),
      ], const [], now);
      expect(split.upcoming.single, isA<OwnPlanEntry>());
      expect((split.upcoming.single as OwnPlanEntry).meeting.id, 'endsNow');
      expect((split.past.single as OwnPlanEntry).meeting.id, 'ended');
    });

    test('live counts the start and not the end', () {
      expect(isLiveAt(now, now.add(const Duration(minutes: 1)), now), isTrue);
      expect(isLiveAt(now.subtract(const Duration(minutes: 1)), now, now), isFalse);
      expect(isLiveAt(now.add(const Duration(minutes: 1)), now.add(const Duration(hours: 1)), now), isFalse);
    });
  });

  group('planDays', () {
    test('nothing upcoming is no sections at all', () {
      expect(planDays(const [], now), isEmpty);
    });

    test('fills today to the horizon, a clear day carries no bands ("free for the day")', () {
      final upcoming = splitPlans([plan('a', now.add(const Duration(hours: 1)), const Duration(hours: 1))], const [], now)
          .upcoming;
      final days = planDays(upcoming, now);
      expect(days, hasLength(kPlansHorizonDays + 1));
      expect(days.first.day, DateTime(2025, 6, 17));
      expect(days.last.day, DateTime(2025, 7, 1));
      expect(days.first.bands.whereType<BusyBand>(), hasLength(1));
      expect(days[1].bands, isEmpty, reason: 'tomorrow is free for the day');
      // The free time around today's meeting is what the timeline exists to show.
      expect(days.first.bands.whereType<FreeBand>(), isNotEmpty);
    });

    test('a far-future meeting gets its own section without painting the empty days before it', () {
      final far = DateTime(2025, 7, 20, 10);
      final upcoming = splitPlans([plan('far', far, const Duration(hours: 1))], const [], now).upcoming;
      final days = planDays(upcoming, now);
      expect(days, hasLength(kPlansHorizonDays + 2));
      expect(days.last.day, DateTime(2025, 7, 20));
      expect(days.last.timed.single.key, 0);
    });

    test('a meeting across midnight is clipped onto both days it touches', () {
      final start = DateTime(2025, 6, 17, 23, 0);
      final upcoming = splitPlans([plan('late', start, const Duration(hours: 2))], const [], now).upcoming;
      final days = planDays(upcoming, now);
      final today = days[0].timed.single;
      final tomorrow = days[1].timed.single;
      expect(today.start, start);
      expect(today.end, DateTime(2025, 6, 18));
      expect(tomorrow.start, DateTime(2025, 6, 18));
      expect(tomorrow.end, DateTime(2025, 6, 18, 1));
    });

    test('all-day events sit apart from the grid, on each day they cover', () {
      final upcoming = splitPlans(const [], [
        google('offsite', DateTime(2025, 6, 18), DateTime(2025, 6, 20), allDay: true),
      ], now)
          .upcoming;
      final days = planDays(upcoming, now);
      expect(days[0].allDay, isEmpty);
      expect(days[1].allDay.single.key, 0);
      expect(days[2].allDay.single.key, 0);
      expect(days[3].allDay, isEmpty, reason: 'Google all-day ends are exclusive');
      expect(days[1].bands, isEmpty, reason: 'an all-day banner never enters the grid');
    });

    test('two overlapping meetings share a busy band in two lanes', () {
      final upcoming = splitPlans([
        plan('a', DateTime(2025, 6, 17, 10), const Duration(hours: 1)),
        plan('b', DateTime(2025, 6, 17, 10, 30), const Duration(hours: 1)),
      ], const [], now)
          .upcoming;
      final busy = planDays(upcoming, now).first.bands.whereType<BusyBand>().single;
      expect(busy.lanes, 2);
    });
  });

  group('the editor', () {
    test('a new meeting opens on the next round half-hour', () {
      expect(defaultPlanStart(DateTime(2025, 6, 17, 9, 10)), DateTime(2025, 6, 17, 9, 30));
      expect(defaultPlanStart(DateTime(2025, 6, 17, 9, 30)), DateTime(2025, 6, 17, 10));
      expect(defaultPlanStart(DateTime(2025, 6, 17, 23, 45)), DateTime(2025, 6, 18));
    });

    test('length opens on 30 minutes new, the meeting own length clamped on an edit', () {
      expect(initialPlanMinutes(null), 30);
      expect(initialPlanMinutes(plan('x', now, const Duration(minutes: 45))), 45);
      expect(initialPlanMinutes(plan('x', now, const Duration(minutes: 1))), 5);
      expect(initialPlanMinutes(plan('x', now, const Duration(hours: 12))), 480);
    });

    test('the date window widens to take in an edited meeting outside it', () {
      final usual = planDateWindow(now, now);
      expect(usual.first, now.subtract(const Duration(days: 1)));
      expect(usual.last, now.add(const Duration(days: 365)));
      final old = DateTime(2024, 1, 1);
      expect(planDateWindow(old, now).first, old);
      final far = DateTime(2027, 1, 1);
      expect(planDateWindow(far, now).last, far);
    });

    test('resolves a room by stable id, and null for none or an unknown one', () {
      final rooms = [room('s1', 'Lounge'), room('s2', 'Library')];
      expect(resolvePlanRoom(rooms, 's2')?.name, 'Library');
      expect(resolvePlanRoom(rooms, null), isNull);
      expect(resolvePlanRoom(rooms, 'gone'), isNull);
    });

    PlannedMeeting compose({
      PlannedMeeting? existing,
      String? roomStableId,
      SpaceRoom? resolved,
      String? floor = 'floor-live',
    }) =>
        composePlannedMeeting(
          existing: existing,
          newId: 'new-id',
          title: 'Retro',
          start: now,
          durationMinutes: 45,
          roomStableId: roomStableId,
          room: resolved,
          liveFloorId: floor,
          remindMinutes: 10,
        );

    test('a new meeting takes a fresh id, the resolved room and the live floor', () {
      final m = compose(roomStableId: 's1', resolved: room('s1', 'Lounge'));
      expect(m.id, 'new-id');
      expect(m.endsAt, now.add(const Duration(minutes: 45)));
      expect(m.roomStableId, 's1');
      expect(m.roomName, 'Lounge');
      expect(m.floorId, 'floor-live');
      expect(m.remindMinutesBefore, 10);
      expect(m.x, isNull);
    });

    final saved = PlannedMeeting(
      id: 'm1',
      title: 'Standup',
      startsAt: now,
      endsAt: now.add(const Duration(minutes: 30)),
      roomStableId: 's1',
      roomName: 'Lounge',
      floorId: 'floor-saved',
      x: 3,
      y: 4,
      deviceEventId: 'dev-1',
    );

    test('an edit whose saved room will not resolve keeps the stored place untouched', () {
      final m = compose(existing: saved, roomStableId: 's1', resolved: null);
      expect(m.id, 'm1');
      expect(m.deviceEventId, 'dev-1');
      expect(m.roomStableId, 's1');
      expect(m.roomName, 'Lounge');
      expect(m.floorId, 'floor-saved');
      expect((m.x, m.y), (3, 4));
    });

    test('explicitly picking "No place" clears it', () {
      final m = compose(existing: saved, roomStableId: null, resolved: null);
      expect(m.roomStableId, isNull);
      expect(m.roomName, isNull);
      expect(m.floorId, isNull);
      expect(m.x, isNull);
    });

    test('an unresolvable *different* room is not kept, and the old place goes with it', () {
      final m = compose(existing: saved, roomStableId: 'other', resolved: null);
      expect(m.roomStableId, isNull);
      expect(m.floorId, isNull);
    });

    test('a re-resolved room takes the live map label and floor, dropping fallback coordinates', () {
      final m = compose(existing: saved, roomStableId: 's1', resolved: room('s1', 'Lounge (renamed)'));
      expect(m.roomName, 'Lounge (renamed)');
      expect(m.floorId, 'floor-live');
      expect(m.x, isNull);
    });
  });
}
