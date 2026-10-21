/// The colleague-peek sheet at the widget level: that a seeded calendar draws as a
/// timeline (the same shape the Plans tab uses), and that the no-calendar and
/// could-not-load outcomes still read as their honest hints rather than a blank.
///
/// Reaching the real sheet on a device needs a live Google account, so these drive it
/// through [AppState.debugPeopleCalendars] — the same harness seam the simulator uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/google_calendar.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/person_calendar_sheet.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  // A couple of events today, so the sheet has a timeline to draw with visible free time.
  GoogleEvent ev(String id, String title, int startHour, int endHour, {String? location}) {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    return GoogleEvent(
      id: id,
      title: title,
      startsAt: day.add(Duration(hours: startHour)),
      endsAt: day.add(Duration(hours: endHour)),
      location: location,
    );
  }

  Future<void> openSheet(WidgetTester tester, AppState state, String label) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showPersonCalendar(context, state, label),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a seeded colleague calendar draws as a timeline', (tester) async {
    final state = AppState()
      ..debugPeopleCalendars = {
        'Ada': PersonCalendar.ok([
          ev('a1', 'Sprint planning', 9, 10, location: 'Focus'),
          ev('a2', 'Interview', 14, 15),
        ]),
      };

    await openSheet(tester, state, 'Ada');

    expect(find.text("Ada's plans"), findsOneWidget);
    expect(find.text('Sprint planning'), findsOneWidget);
    // A gap between the 10:00 and 14:00 events is free time the list never showed.
    expect(find.textContaining('free'), findsWidgets);
  });

  testWidgets('a colleague who shared nothing reads as no calendar', (tester) async {
    final state = AppState()..debugPeopleCalendars = {'Mira': PersonCalendar.noCalendar};

    await openSheet(tester, state, 'Mira');

    expect(find.textContaining('has not shared a calendar'), findsOneWidget);
  });

  testWidgets('a calendar that could not load says so, not "free"', (tester) async {
    final state = AppState()..debugPeopleCalendars = {'Dot': PersonCalendar.unavailable};

    await openSheet(tester, state, 'Dot');

    expect(find.textContaining('Couldn’t load'), findsOneWidget);
  });
}
