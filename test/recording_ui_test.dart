/// Recording in the call UI: the button that starts it and the light that says it
/// is running.
///
/// Two rules the rest of the bar already keeps, applied to recording. A control
/// that cannot do anything is *absent* rather than dimmed — no meeting behind the
/// huddle, no button. And the record itself is server-side, so the button sends a
/// request and the light follows the wire; nothing flips locally on the press.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/harness/fake_collector.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/control_bar.dart';

RosterRow _row(String id, {String? name}) => RosterRow(
      id: id,
      name: name,
      x: 5,
      y: 5,
      floorId: 'f1',
      connected: true,
    );

void main() {
  /// An app in a huddle with a collector behind it, so the recording button has a
  /// meeting to address. [meetingId] null stands for a casual huddle with no
  /// meeting, [recording] for one already in flight.
  ({AppState state, FakeCollector collector}) inMeeting({
    String? meetingId = 'm-1',
    bool recording = false,
  }) {
    final collector = FakeCollector()..fakeMeetingId = meetingId;
    if (recording) collector.fakeRecording = true;
    final state = AppState()
      ..debugAttachCollector(collector)
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', name: 'Jonas')]))
      ..debugHuddle = ['ada'];
    addTearDown(state.dispose);
    return (state: state, collector: collector);
  }

  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) => ControlBar(state: state, onCallScreen: true),
            ),
          ),
        ),
      );

  testWidgets('no meeting behind the huddle, no record button', (tester) async {
    final (:state, :collector) = inMeeting(meetingId: null);
    await tester.pumpWidget(wrap(state));

    expect(
      find.byTooltip('Record the meeting'),
      findsNothing,
      reason: 'absent rather than dimmed, like the camera flip',
    );
    expect(state.canRecord, isFalse);
  });

  testWidgets('with a meeting, the button is there and tapping it asks to record',
      (tester) async {
    final (:state, :collector) = inMeeting();
    await tester.pumpWidget(wrap(state));

    expect(find.byTooltip('Record the meeting'), findsOneWidget);
    // Resting grey while it is off — the glyph is the state, as with mute.
    final t = tester.element(find.byTooltip('Record the meeting')).tokens;
    final icon = tester.widget<Icon>(find.descendant(
        of: find.byTooltip('Record the meeting'), matching: find.byType(Icon)));
    expect(icon.color, t.mutedForeground);

    await tester.tap(find.byTooltip('Record the meeting'));
    await tester.pumpAndSettle();

    expect(collector.recordingCalls, [true], reason: 'a start request went');
  });

  testWidgets('while recording the button says stop and wears the danger red',
      (tester) async {
    final (:state, :collector) = inMeeting(recording: true);
    await tester.pumpWidget(wrap(state));

    expect(find.byTooltip('Stop recording'), findsOneWidget);
    expect(find.byTooltip('Record the meeting'), findsNothing);

    final t = tester.element(find.byTooltip('Stop recording')).tokens;
    final icon = tester.widget<Icon>(find.descendant(
        of: find.byTooltip('Stop recording'), matching: find.byType(Icon)));
    expect(icon.color, t.danger);

    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pumpAndSettle();
    expect(collector.recordingCalls, [false], reason: 'a stop request went');
  });

  testWidgets('a refusal reaches the person as a sentence, not a dead tap',
      (tester) async {
    final (:state, :collector) = inMeeting();
    collector.failRecording = true;
    await tester.pumpWidget(wrap(state));

    await tester.tap(find.byTooltip('Record the meeting'));
    await tester.pumpAndSettle();

    expect(find.text('not allowed to record'), findsOneWidget);
  });

  group('AppState recording logic', () {
    test('canRecord needs both a call and a meeting', () {
      final (:state, collector: _) = inMeeting(meetingId: null);
      expect(state.inCall, isTrue);
      expect(state.canRecord, isFalse);
    });

    test('toggling with no meeting returns an error rather than sending', () async {
      final (:state, :collector) = inMeeting(meetingId: null);
      final error = await state.toggleRecording();
      expect(error, 'No meeting to record.');
      expect(collector.recordingCalls, isEmpty);
    });

    test('recording reflects the collector', () {
      final (:state, collector: _) = inMeeting(recording: true);
      expect(state.recording, isTrue);
    });
  });
}
