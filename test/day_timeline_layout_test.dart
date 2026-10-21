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

    test('no leading free band when the first event sits on the hour', () {
      final bands = layoutDay([item(10, 11)]);
      // 10:00 start == window top, so the lead gap is zero-length and omitted.
      expect(bands.whereType<FreeBand>(), isEmpty);
      expect(bands.single, isA<BusyBand>());
    });

    test('leading gap present when the first event is mid-hour', () {
      final bands = layoutDay([
        TimelineItem(start: at(10, 30), end: at(11), key: 'a'),
      ]);
      final lead = bands.first as FreeBand;
      expect(lead.start, at(10)); // hour top
      expect(lead.end, at(10, 30));
      expect(lead.collapsed, isFalse); // 30 min < 90 min threshold
    });

    test('a long gap between clusters is collapsed, a short one is not', () {
      // 09–10, then nothing until 14–15: a 4h gap, well over the 90-min default.
      final bands = layoutDay([item(9, 10), item(14, 15)]);
      final gaps = bands.whereType<FreeBand>().toList();
      expect(gaps, hasLength(1));
      expect(gaps.single.start, at(10));
      expect(gaps.single.end, at(14));
      expect(gaps.single.collapsed, isTrue);
    });

    test('a short gap between clusters stays proportional', () {
      // 09–10 then 10:30–11: a 30-min gap, under threshold.
      final bands = layoutDay([
        item(9, 10),
        TimelineItem(start: at(10, 30), end: at(11), key: 'b'),
      ]);
      final gap = bands.whereType<FreeBand>().single;
      expect(gap.collapsed, isFalse);
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

    test('no trailing free band after the last event', () {
      final bands = layoutDay([item(10, 11)]);
      expect(bands.last, isA<BusyBand>());
    });
  });
}
