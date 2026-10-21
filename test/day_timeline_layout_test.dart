import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/day_timeline_layout.dart';

/// A 2026-06-15 instant builder, kept terse so the tests read as timetables.
DateTime at(int hour, [int minute = 0]) => DateTime(2026, 6, 15, hour, minute);

TimelineItem item(int startHour, int endHour, {Object? key, bool allDay = false}) =>
    TimelineItem(
      start: at(startHour),
      end: at(endHour),
      key: key ?? '$startHour-$endHour',
      allDay: allDay,
    );

void main() {
  group('packLanes', () {
    test('a lone event is full width', () {
      final packed = packLanes([item(10, 11)]);
      expect(packed.single.column, 0);
      expect(packed.single.columnCount, 1);
    });

    test('back-to-back events share one lane', () {
      final packed = packLanes([item(10, 11), item(11, 12)]);
      expect(packed.every((p) => p.columnCount == 1), isTrue);
      expect(packed.map((p) => p.column), [0, 0]);
    });

    test('back-to-back short events split into side-by-side lanes under a min slot', () {
      // Two 15-min events at 10:00 and 10:15 do not overlap in time, so by default they
      // pack into one lane. But the widget floors each to a minimum rendered height, so
      // stacked they would collide on screen. A min slot longer than the 15-min gap makes
      // the 10:00 event hold its lane until 10:28, pushing the 10:15 into its own.
      TimelineItem short(int h, int m, String k) => TimelineItem(
            start: DateTime(2026, 6, 15, h, m),
            end: DateTime(2026, 6, 15, h, m).add(const Duration(minutes: 15)),
            key: k,
          );
      final items = [short(10, 0, 'a'), short(10, 15, 'b')];

      expect(packLanes(items).every((p) => p.columnCount == 1), isTrue);

      final packed = packLanes(items, minItemDuration: const Duration(minutes: 28));
      expect(packed.every((p) => p.columnCount == 2), isTrue);
      expect(packed.map((p) => p.column), [0, 1]);
    });

    test('two overlapping events take two lanes', () {
      final packed = packLanes([item(10, 12), item(11, 13)]);
      expect(packed.every((p) => p.columnCount == 2), isTrue);
      expect(packed.map((p) => p.column), [0, 1]);
    });

    test('triple-booking takes three lanes', () {
      final packed = packLanes([item(10, 13), item(10, 13), item(10, 13)]);
      expect(packed.every((p) => p.columnCount == 3), isTrue);
      expect(packed.map((p) => p.column).toSet(), {0, 1, 2});
    });

    test('a freed lane is reused by a later non-overlapping event', () {
      // 10–11 and 10–12 need two lanes; 11:30–12:30 overlaps only the 10–12, so it can
      // take the lane the 10–11 vacated — width stays 2, not 3.
      final packed = packLanes([item(10, 11), item(10, 12), item(11, 12)]);
      expect(packed.every((p) => p.columnCount == 2), isTrue);
    });
  });

  group('layoutDay', () {
    test('empty day yields no bands', () {
      expect(layoutDay(const []), isEmpty);
    });

    test('all-day items are excluded', () {
      expect(layoutDay([item(0, 24, allDay: true)]), isEmpty);
    });

    test('a leading free band runs from the day start even on the hour', () {
      final bands = layoutDay([item(10, 11)]);
      // The lead gap is the whole morning (00:00 → 10:00), so "Free till 10:00" shows
      // however the first event aligns — an on-the-hour start no longer swallows it.
      final lead = bands.first as FreeBand;
      expect(lead.start, at(0));
      expect(lead.end, at(10));
      expect(lead.collapsed, isTrue); // 10h > 90 min, so it collapses to a faded band
      expect(bands.whereType<BusyBand>(), hasLength(1));
    });

    test('a short leading gap before an early event stays proportional', () {
      final bands = layoutDay([
        TimelineItem(start: at(0, 30), end: at(1), key: 'a'),
      ]);
      final lead = bands.first as FreeBand;
      expect(lead.start, at(0));
      expect(lead.end, at(0, 30));
      expect(lead.collapsed, isFalse); // 30 min < 90 min threshold
    });

    test('a long gap between clusters is collapsed, a short one is not', () {
      // 09–10, then nothing until 14–15: a 4h gap, well over the 90-min default.
      final bands = layoutDay([item(9, 10), item(14, 15)]);
      // Three gaps now: the leading one (day start → 09:00), the one between clusters,
      // and the trailing one (15:00 → day end).
      final gaps = bands.whereType<FreeBand>().toList();
      expect(gaps, hasLength(3));
      final between = gaps[1];
      expect(between.start, at(10));
      expect(between.end, at(14));
      expect(between.collapsed, isTrue);
    });

    test('a short gap between clusters stays proportional', () {
      // 09–10 then 10:30–11: a 30-min gap, under threshold.
      final bands = layoutDay([
        item(9, 10),
        TimelineItem(start: at(10, 30), end: at(11), key: 'b'),
      ]);
      // The between-cluster gap is the middle free band: the first is the leading one
      // (day start → 09:00), the last is the trailing one (11:00 → day end).
      final between = bands.whereType<FreeBand>().toList()[1];
      expect(between.start, at(10));
      expect(between.end, at(10, 30));
      expect(between.collapsed, isFalse);
    });

    test('touching events form one busy band, not two', () {
      final bands = layoutDay([item(10, 11), item(11, 12)]);
      expect(bands.whereType<BusyBand>(), hasLength(1));
      expect((bands.whereType<BusyBand>().single).items, hasLength(2));
    });

    test('overlapping events land in one band with both lanes', () {
      final bands = layoutDay([item(10, 12), item(11, 13)]);
      final busy = bands.whereType<BusyBand>().single;
      expect(busy.lanes, 2);
      expect(busy.start, at(10));
      expect(busy.end, at(13));
    });

    test('a trailing free band runs from the last event to the day end', () {
      final bands = layoutDay([item(10, 11)]);
      final trailing = bands.last as FreeBand;
      expect(trailing.start, at(11));
      expect(trailing.end, at(24)); // midnight next day == at(24)
      expect(trailing.collapsed, isTrue); // 13h > 90 min
    });
  });
}
