/// The [DayTimeline] widget at the render level: that it draws free-time markers, an
/// all-day banner, and blocks of every height without overflowing a lane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/day_timeline_layout.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/day_timeline.dart';

void main() {
  DateTime at(int h, [int m = 0]) => DateTime(2026, 6, 15, h, m);

  TimelineItem item(DateTime s, DateTime e, {bool allDay = false, Object key = 0}) =>
      TimelineItem(start: s, end: e, allDay: allDay, key: key);

  Widget wrap(DayTimeline timeline) => MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(body: SingleChildScrollView(child: timeline)),
      );

  testWidgets('an empty day reads "Free for the day"', (tester) async {
    await tester.pumpWidget(wrap(DayTimeline(
      bands: const [],
      allDay: const [],
      blockBuilder: (_, _) => const SizedBox.shrink(),
    )));
    expect(find.text('Free for the day'), findsOneWidget);
  });

  testWidgets('a mid-morning meeting labels the free time before it', (tester) async {
    final timed = [item(at(10, 30), at(11))];
    await tester.pumpWidget(wrap(DayTimeline(
      bands: layoutDay(timed),
      allDay: const [],
      blockBuilder: (_, i) => ColoredBox(color: const Color(0xFF4257DA), child: Text('E${i.key}')),
    )));
    expect(find.text('Free till 10:30'), findsOneWidget);
    expect(find.text('E0'), findsOneWidget);
  });

  testWidgets('an on-the-hour first event still labels the free time before it', (tester) async {
    // Regression: the leading gap used to be pinned to the event's own hour, so a
    // 14:00 start showed no "Free till" at all. It now runs from the day start.
    final timed = [item(at(14), at(15))];
    await tester.pumpWidget(wrap(DayTimeline(
      bands: layoutDay(timed),
      allDay: const [],
      blockBuilder: (_, i) => Text('E${i.key}'),
    )));
    expect(find.text('Free till 14:00'), findsOneWidget);
  });

  testWidgets('the free time after the last event is labelled', (tester) async {
    final timed = [item(at(10), at(11))];
    await tester.pumpWidget(wrap(DayTimeline(
      bands: layoutDay(timed),
      allDay: const [],
      blockBuilder: (_, i) => Text('E${i.key}'),
    )));
    expect(find.text('Free after 11:00'), findsOneWidget);
  });

  testWidgets('a long empty afternoon collapses to a labelled band', (tester) async {
    // 09–10 then nothing until 15–16: a 5h gap, well over the collapse threshold.
    final timed = [item(at(9), at(10), key: 0), item(at(15), at(16), key: 1)];
    await tester.pumpWidget(wrap(DayTimeline(
      bands: layoutDay(timed),
      allDay: const [],
      blockBuilder: (_, i) => Text('E${i.key}'),
    )));
    expect(find.text('5h free'), findsOneWidget);
  });

  testWidgets('an all-day event draws as a banner, outside the grid', (tester) async {
    await tester.pumpWidget(wrap(DayTimeline(
      bands: const [],
      allDay: [item(at(0), at(24), allDay: true)],
      blockBuilder: (_, _) => const Text('Company offsite'),
    )));
    expect(find.text('Company offsite'), findsOneWidget);
  });

  testWidgets('a two-minute block renders without overflowing its lane', (tester) async {
    // The shortest possible block floors to the min height; its content must still fit.
    final timed = [item(at(10), at(10, 2))];
    await tester.pumpWidget(wrap(DayTimeline(
      bands: layoutDay(timed),
      allDay: const [],
      blockBuilder: (_, _) => Container(
        color: const Color(0xFF20242F),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: const Text('Quick hold', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    )));
    expect(tester.takeException(), isNull);
    expect(find.text('Quick hold'), findsOneWidget);
  });

  testWidgets('a double-booking places both blocks', (tester) async {
    final timed = [item(at(10), at(12), key: 0), item(at(11), at(13), key: 1)];
    await tester.pumpWidget(wrap(DayTimeline(
      bands: layoutDay(timed),
      allDay: const [],
      blockBuilder: (_, i) => Text('E${i.key}'),
    )));
    expect(tester.takeException(), isNull);
    expect(find.text('E0'), findsOneWidget);
    expect(find.text('E1'), findsOneWidget);
  });
}
