/// The Warp Dial's planned-meeting line: inferring a shared invite from members whose
/// calendars agree on an end, and rendering the remaining time adaptively — a countdown
/// under the hour, a bare end time over it, and overtime once the invite is spent.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/google_calendar.dart';

GoogleEvent _event(DateTime start, DateTime end, {bool allDay = false}) =>
    GoogleEvent(
      id: '${start.toIso8601String()}-${end.toIso8601String()}',
      title: 'Busy',
      startsAt: start,
      endsAt: end,
      allDay: allDay,
    );

void main() {
  final now = DateTime(2026, 10, 16, 14, 30);
  DateTime at(int h, int m) => DateTime(2026, 10, 16, h, m);

  group('plannedMeetingEnd', () {
    test('two members sharing an active end date the meeting', () {
      final end = plannedMeetingEnd([
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 0), at(15, 0))],
      ], now);
      expect(end, at(15, 0));
    });

    test('a lone member is not a planned meeting', () {
      final end = plannedMeetingEnd([
        [_event(at(14, 0), at(15, 0))],
        const [],
      ], now);
      expect(end, isNull);
    });

    test('members with nothing in common are not a planned meeting', () {
      // Both busy, but until different times — no shared invite.
      final end = plannedMeetingEnd([
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 15), at(16, 0))],
      ], now);
      expect(end, isNull);
    });

    test('a member double-booked on the same end votes once, not twice', () {
      // One member carries the 15:00 end on two rows; alone that must not clear the
      // two-member bar.
      final end = plannedMeetingEnd([
        [_event(at(14, 0), at(15, 0)), _event(at(13, 0), at(15, 0))],
      ], now);
      expect(end, isNull);
    });

    test('all-day events never form a meeting', () {
      final end = plannedMeetingEnd([
        [_event(at(0, 0), at(23, 59), allDay: true)],
        [_event(at(0, 0), at(23, 59), allDay: true)],
      ], now);
      expect(end, isNull);
    });

    test('a running invite outranks a spent one even with fewer members', () {
      // Three members just finished a 14:00 block; two of them are now in a 14:30
      // one that is still running. The live invite wins.
      final end = plannedMeetingEnd([
        [_event(at(13, 30), at(14, 20)), _event(at(14, 25), at(15, 15))],
        [_event(at(13, 30), at(14, 20)), _event(at(14, 25), at(15, 15))],
        [_event(at(13, 30), at(14, 20))],
      ], now);
      expect(end, at(15, 15));
    });

    test('overtime: a just-ended shared invite still dates the meeting', () {
      final overtimeNow = at(15, 5);
      final end = plannedMeetingEnd([
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 0), at(15, 0))],
      ], overtimeNow);
      expect(end, at(15, 0));
    });

    test('an invite spent beyond the grace window drops out', () {
      final longAfter = at(15, 45);
      final end = plannedMeetingEnd([
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 0), at(15, 0))],
      ], longAfter);
      expect(end, isNull);
    });

    test('among spent invites the most recent end wins over the vote count', () {
      // At 15:20 both 15:00 and 15:15 are over but inside the grace. 15:00 has three
      // votes, 15:15 only two — yet the overtime line is about the invite that only
      // just finished, so the later end takes it (`+5min over`, not `+20min over`).
      final overtimeNow = at(15, 20);
      final end = plannedMeetingEnd([
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 30), at(15, 15))],
        [_event(at(14, 30), at(15, 15))],
      ], overtimeNow);
      expect(end, at(15, 15));
    });

    test('a running invite still beats a more-shared spent one', () {
      // Guard the running-vs-spent order against the spent tie-break change: the
      // two-vote running invite outranks the three-vote spent one.
      final nowish = at(15, 5);
      final end = plannedMeetingEnd([
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 0), at(15, 0))],
        [_event(at(14, 30), at(15, 30))],
        [_event(at(14, 30), at(15, 30))],
      ], nowish);
      expect(end, at(15, 30));
    });
  });

  group('meetingTimeLabel', () {
    test('under an hour left counts down in minutes', () {
      expect(meetingTimeLabel(at(15, 5), now), 'free in 35min');
    });

    test('an hour or more left shows the bare end time', () {
      expect(meetingTimeLabel(at(15, 45), now), '15:45');
    });

    test('exactly an hour left crosses to the end time', () {
      expect(meetingTimeLabel(at(15, 30), now), '15:30');
    });

    test('a sub-minute remainder never reads zero', () {
      expect(meetingTimeLabel(now.add(const Duration(seconds: 20)), now), 'free in 1min');
    });

    test('past the end counts overtime up', () {
      expect(meetingTimeLabel(at(14, 25), now), '+5min over');
    });

    test('the flip to overtime never shows +0min', () {
      expect(meetingTimeLabel(now, now), '+1min over');
    });
  });
}
