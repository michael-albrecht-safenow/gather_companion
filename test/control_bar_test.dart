/// The control bar and the status sheet.
///
/// What is worth pinning here is not the drawing — it is the two rules the bar
/// keeps repeating. A control that cannot do anything is *absent* rather than
/// dimmed, so the conversation button appears with a conversation and goes with
/// it. And every action answers: a refusal reaches the person as a sentence
/// rather than as a tap that did nothing, which is the whole contract
/// `setPartyMode` established and everything here follows.
///
/// The door is the one documented exception to the first rule, so it is tested as
/// an exception: absent when there is no desk and nothing to leave, dim when you
/// are already at your desk with nobody around, and inert rather than quietly
/// failing while it is dim. It is also *one* button — the desk walk and leaving a
/// conversation used to be two, and the tests here hold them together.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/link_status.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/control_bar.dart';

RosterRow _row(
  String id, {
  String? name,
  String? availability,
  String? deskId,
  num x = 5,
  num y = 5,
}) =>
    RosterRow(
      id: id,
      name: name,
      x: x,
      y: y,
      floorId: 'f1',
      connected: true,
      availability: availability,
      deskId: deskId,
    );

/// A floor with one desk on it, at 10,10 and two tiles square.
///
/// `stableId` and not `id`: `SpaceUser.deskId` points at the area's
/// `MapEntityIdentifier`, and a test that matched on `id` would pass against a
/// reading of the roster that finds nobody's desk in production.
SpaceMap _floorWithADesk() => SpaceMap(
      floorId: 'f1',
      width: 20,
      height: 20,
      blocked: const {},
      rooms: const [
        SpaceRoom(
          id: 'area-1',
          stableId: 'desk-1',
          name: null,
          type: 'Desk',
          x: 10,
          y: 10,
          width: 2,
          height: 2,
          walled: false,
        ),
      ],
    );

void main() {
  Widget wrap(AppState state) => MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(
          // The bar puts failures in a snack bar, which needs a Scaffold to land
          // in — the real one is the shell's.
          body: Align(
            alignment: Alignment.bottomCenter,
            // The shell wraps the bar in exactly this, because it lives outside
            // the `IndexedStack` and so has no listener of its own.
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) => ControlBar(state: state),
            ),
          ),
        ),
      );

  /// A paired app that knows which avatar is ours, which is what the bar draws
  /// itself from.
  AppState connected({String? availability}) => AppState()
    ..debugApplyLink(const LinkStatus(LinkState.live))
    ..debugApplyRoster(Roster(
      selfId: 'me',
      rows: [_row('me', name: 'Jonas', availability: availability)],
    ));

  testWidgets('the bar carries you, your hardware and the room', (tester) async {
    await tester.pumpWidget(wrap(connected()));

    expect(find.byTooltip('Your status'), findsOneWidget);
    // Both start off, and off is what the label says — nothing here claims to be
    // carrying audio before anybody has asked it to.
    expect(find.byTooltip('Unmute'), findsOneWidget);
    expect(find.byTooltip('Turn the camera on'), findsOneWidget);
    expect(find.byTooltip('React'), findsOneWidget);
  });

  testWidgets('a muted microphone is grey, not red', (tester) async {
    await tester.pumpWidget(wrap(connected()));
    final t = tester.element(find.byTooltip('Unmute')).tokens;

    for (final off in ['Unmute', 'Turn the camera on']) {
      final icon = tester.widget<Icon>(
        find.descendant(of: find.byTooltip(off), matching: find.byType(Icon)),
      );
      expect(
        icon.color,
        t.mutedForeground,
        reason: '$off: the crossed-out glyph is the state — see the header',
      );
    }
  });

  testWidgets('the camera flip is only there once there is a camera to flip',
      (tester) async {
    await tester.pumpWidget(wrap(connected()));

    expect(
      find.byTooltip('Switch camera'),
      findsNothing,
      reason: 'absent rather than dimmed, like everything else here',
    );
  });

  testWidgets('leaving the conversation is the door, red wherever the bar is drawn',
      (tester) async {
    final state = connected()..debugHuddle = ['Ada'];
    Icon leaveIcon() => tester
        .widget<Icon>(find.descendant(of: find.byTooltip('Leave the conversation'), matching: find.byType(Icon)));
    Color? leaveColour() => leaveIcon().color;

    // Over the map as well as on the faces, and the same glyph the desk walk has
    // — it is the same button. This used to be a second button beside the desk's,
    // which made three ways out across the two screens.
    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();
    final t = tester.element(find.byTooltip('Leave the conversation')).tokens;
    expect(leaveColour(), t.danger);
    expect(leaveIcon().icon, Icons.logout_rounded);
    expect(find.byIcon(Icons.logout_rounded), findsOneWidget, reason: 'one door, not two');

    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: ControlBar(state: state, onCallScreen: true))),
    ));
    await tester.pumpAndSettle();
    expect(leaveColour(), t.danger);
  });

  testWidgets('the camera flip lives on the call screen, not over the map',
      (tester) async {
    final state = connected()
      ..debugCall = const CallState(
        media: LocalMediaState(capturing: true, videoEnabled: true, videoTrackId: 'v1'),
      );

    await tester.pumpWidget(wrap(state));
    expect(find.byTooltip('Turn the camera off'), findsOneWidget, reason: 'the camera is on');
    expect(find.byTooltip('Switch camera'), findsNothing);

    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: ControlBar(state: state, onCallScreen: true))),
    ));
    expect(find.byTooltip('Switch camera'), findsOneWidget);
  });

  testWidgets('leaving the conversation appears with one and goes with it',
      (tester) async {
    // The rosters differ by who is in them rather than only by the seam, because
    // that is what actually happens: a conversation starts when somebody walks up
    // to you, and `debugApplyRoster` deliberately stays silent for a roster the
    // tracker finds nothing in.
    final state = connected();
    await tester.pumpWidget(wrap(state));
    expect(find.byTooltip('Leave the conversation'), findsNothing);

    state.debugHuddle = ['Ada'];
    state.debugApplyRoster(Roster(
      selfId: 'me',
      rows: [_row('me', name: 'Jonas'), _row('ada', name: 'Ada')],
    ));
    await tester.pump();
    expect(find.byTooltip('Leave the conversation'), findsOneWidget);

    state.debugHuddle = const [];
    state.debugApplyRoster(Roster(selfId: 'me', rows: [_row('me', name: 'Jonas')]));
    await tester.pump();
    expect(find.byTooltip('Leave the conversation'), findsNothing);
  });

  testWidgets('your own camera has a button until there is a call to see instead',
      (tester) async {
    // In a call the banner across the top of the shell is the way to the faces, so
    // the bar stops carrying a second door to the same room.
    final state = connected()
      ..debugCall = const CallState(
        media: LocalMediaState(capturing: true, videoEnabled: true, videoTrackId: 'v1'),
      );
    await tester.pumpWidget(wrap(state));
    expect(find.byTooltip('See your camera'), findsOneWidget);

    state.debugHuddle = ['Ada'];
    state.debugApplyRoster(Roster(
      selfId: 'me',
      rows: [_row('me', name: 'Jonas'), _row('ada', name: 'Ada')],
    ));
    await tester.pump();
    expect(find.byTooltip('See your camera'), findsNothing);
  });

  group('the audio route', () {
    CallState outputting(AudioOutput out) => CallState(
          media: LocalMediaState(
            capturing: true,
            audioEnabled: true,
            audioTrackId: 'a1',
            audioOutput: out,
          ),
        );

    testWidgets('is absent until there is sound to route', (tester) async {
      await tester.pumpWidget(wrap(connected()));

      // Nobody in the call and no hardware live — nothing to send anywhere, so
      // the button is absent rather than dimmed, like the rest of the bar.
      for (final label in [
        'Use the speaker',
        'Use the earpiece',
        'On Bluetooth — tap for the speaker',
        'On headphones — tap for the speaker',
      ]) {
        expect(find.byTooltip(label), findsNothing, reason: label);
      }
    });

    testWidgets('on the loudspeaker it offers the earpiece, wearing the brand',
        (tester) async {
      final state = connected()..debugCall = outputting(AudioOutput.speaker);
      await tester.pumpWidget(wrap(state));

      final button = find.byTooltip('Use the earpiece');
      expect(button, findsOneWidget);
      final icon =
          tester.widget<Icon>(find.descendant(of: button, matching: find.byType(Icon)));
      expect(icon.icon, Icons.volume_up_rounded);
      expect(icon.color, tester.element(button).tokens.brand,
          reason: 'the loudspeaker is the broadcasting state, like a live mic');
    });

    testWidgets('on the earpiece it offers the speaker, in resting grey',
        (tester) async {
      final state = connected()..debugCall = outputting(AudioOutput.earpiece);
      await tester.pumpWidget(wrap(state));

      final button = find.byTooltip('Use the speaker');
      expect(button, findsOneWidget);
      final icon =
          tester.widget<Icon>(find.descendant(of: button, matching: find.byType(Icon)));
      expect(icon.icon, Icons.phone_in_talk_rounded);
      expect(icon.color, tester.element(button).tokens.mutedForeground);
    });

    testWidgets('a headset owns the glyph, and a tap still reaches AppState',
        (tester) async {
      final state = connected()..debugCall = outputting(AudioOutput.bluetooth);
      await tester.pumpWidget(wrap(state));

      final button = find.byTooltip('On Bluetooth — tap for the speaker');
      expect(button, findsOneWidget);
      expect(
        tester.widget<Icon>(find.descendant(of: button, matching: find.byType(Icon))).icon,
        Icons.bluetooth_audio_rounded,
      );

      // The refusal is the proof it is wired to `AppState`, not only to the
      // widget: there is no socket here, so the route cannot be set.
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Not connected to Gather.'), findsOneWidget);
    });
  });

  group('back to my desk', () {
    /// Paired, on a floor with a desk, standing wherever [at] says.
    AppState atDesk({String? deskId, required int x, required int y}) => AppState()
      ..debugApplyLink(const LinkStatus(LinkState.live))
      ..debugMap = _floorWithADesk()
      ..debugApplyRoster(Roster(
        selfId: 'me',
        rows: [_row('me', name: 'Jonas', deskId: deskId, x: x, y: y)],
      ));

    testWidgets('is absent for somebody Gather has given no desk', (tester) async {
      await tester.pumpWidget(wrap(atDesk(x: 5, y: 5)));

      expect(
        find.byIcon(Icons.logout_rounded),
        findsNothing,
        reason: 'dimming it would tell them they are sitting at a desk they '
            'have never had',
      );
    });

    testWidgets('reads leave while you are in a conversation at your own desk',
        (tester) async {
      // Somebody walked up to you. The door is not dim — there is something to
      // leave — and it says so rather than claiming you are away from your desk.
      final state = atDesk(deskId: 'desk-1', x: 11, y: 10)..debugHuddle = ['Ada'];
      await tester.pumpWidget(wrap(state));
      await tester.pumpAndSettle();

      final button = find.byTooltip('Leave the conversation');
      expect(button, findsOneWidget);
      expect(find.byTooltip('You are at your desk'), findsNothing);
      expect(
        tester.widget<Icon>(find.descendant(of: button, matching: find.byType(Icon))).color,
        tester.element(button).tokens.danger,
      );
    });

    testWidgets('is red and walks you back when you are away from it',
        (tester) async {
      final state = atDesk(deskId: 'desk-1', x: 5, y: 5);
      await tester.pumpWidget(wrap(state));

      final button = find.byTooltip('Back to my desk');
      expect(button, findsOneWidget);
      expect(
        tester
            .widget<Icon>(
                find.descendant(of: button, matching: find.byType(Icon)))
            .color,
        tester.element(button).tokens.danger,
      );

      // The refusal is the proof it is wired to `AppState` and not only to the
      // widget: there is no socket here, so the walk cannot start.
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Not connected to Gather.'), findsOneWidget);
    });

    testWidgets('is dim and does nothing once you are sitting at it',
        (tester) async {
      // 11,10 rather than 10,10: anywhere inside the desk's rectangle counts,
      // which is what `currentMapArea === desk` means.
      await tester.pumpWidget(wrap(atDesk(deskId: 'desk-1', x: 11, y: 10)));

      final button = find.byTooltip('You are at your desk');
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(
        find.text('Not connected to Gather.'),
        findsNothing,
        reason: 'a dimmed control is inert, not merely quiet about failing',
      );
    });
  });

  group('the reaction tray', () {
    testWidgets('opens on the button and holds Gather\'s eight', (tester) async {
      await tester.pumpWidget(wrap(connected()));
      expect(find.text('👋'), findsNothing);

      await tester.tap(find.byTooltip('React'));
      await tester.pumpAndSettle();

      for (final emote in ['👋', '❤️', '🎉', '👍️', '🤣', '👏', '💯', '🔥']) {
        expect(find.text(emote), findsOneWidget, reason: 'the bar is missing $emote');
      }
    });

    testWidgets('opening it does not change how wide the dock is', (tester) async {
      // Measured the way the dock measures — an `IntrinsicWidth` over a floor of
      // [kRailMinWidth], which is `_Dock` in home_shell.dart — because that is
      // where the bug was: eight 40-point reactions measured 328 against a floor
      // of 320, so the island grew by eight points as the tray opened and shrank
      // back as a reaction was picked, under the thumb reaching for it.
      //
      // Not asserted through the whole shell. There the navigation labels are
      // wider than the tray under the test font and the island is set by them, so
      // a shell-level test would pass against the bug and prove nothing.
      final state = connected();
      await tester.pumpWidget(MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: IntrinsicWidth(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: kRailMinWidth),
                child: ListenableBuilder(
                  listenable: state,
                  builder: (context, _) => ControlBar(state: state),
                ),
              ),
            ),
          ),
        ),
      ));

      final shut = tester.getSize(find.byType(ControlBar)).width;
      expect(shut, kRailMinWidth, reason: 'the controls alone sit on the floor');

      await tester.tap(find.byTooltip('React'));
      await tester.pumpAndSettle();

      expect(find.text('👋'), findsOneWidget, reason: 'the tray really did open');
      expect(tester.getSize(find.byType(ControlBar)).width, shut);
    });

    testWidgets('picking one keeps the tray open and says so when it cannot send',
        (tester) async {
      // No collector, so the send is refused — which is exactly what proves the
      // button is wired to `AppState` rather than only to `setState`.
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('React'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('🎉'));
      await tester.pumpAndSettle();

      expect(find.text('🎉'), findsOneWidget, reason: 'open for the next one');
      expect(find.text('Not connected to Gather.'), findsOneWidget);
    });

    testWidgets('only the React button closes it again', (tester) async {
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('React'));
      await tester.pumpAndSettle();

      for (final emote in ['👏', '👏', '🔥']) {
        await tester.tap(find.text(emote));
        await tester.pumpAndSettle();
        expect(find.text('🎉'), findsOneWidget, reason: 'still open after $emote');
      }

      // Every send here is refused, and the refusal's snack bar lands over the
      // bar in a window this small.
      tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('React'));
      await tester.pumpAndSettle();
      expect(find.text('🎉'), findsNothing);
    });
  });

  group('the raise-hand button', () {
    testWidgets('is absent until there is a meeting to raise it in',
        (tester) async {
      // Standing alone over the map — a hand is a meeting gesture, and like the
      // door and the camera flip, the control for it is absent, not dimmed, when
      // there is nothing to do with it.
      await tester.pumpWidget(wrap(connected()));
      expect(find.byTooltip('Raise hand'), findsNothing);
      expect(find.byTooltip('Lower hand'), findsNothing);
    });

    testWidgets('appears in a meeting and toggles the hand', (tester) async {
      final state = connected()..debugHuddle = ['Ada'];
      await tester.pumpWidget(wrap(state));

      expect(find.byTooltip('Raise hand'), findsOneWidget);
      expect(state.myHandRaised, isFalse);

      await tester.tap(find.byTooltip('Raise hand'));
      await tester.pumpAndSettle();

      // The state flipped and the label with it — the one button is both raise and
      // lower, the way React is the one button that opens and shuts the tray.
      expect(state.myHandRaised, isTrue);
      expect(find.byTooltip('Lower hand'), findsOneWidget);
      expect(find.byTooltip('Raise hand'), findsNothing);

      await tester.tap(find.byTooltip('Lower hand'));
      await tester.pumpAndSettle();
      expect(state.myHandRaised, isFalse);
      expect(find.byTooltip('Raise hand'), findsOneWidget);
    });
  });

  group('the status sheet', () {
    testWidgets('opens off the avatar and offers the three you can set',
        (tester) async {
      await tester.pumpWidget(wrap(connected(availability: 'Busy')));

      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();

      expect(find.text('Jonas'), findsOneWidget);
      // Three choices, and the current one named again underneath the name.
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Busy'), findsNWidgets(2));
      expect(find.text('Away'), findsOneWidget);
      expect(find.text('Update your status'), findsOneWidget);
    });

    testWidgets('picking a state reports a refusal rather than swallowing it',
        (tester) async {
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Away'));
      await tester.pumpAndSettle();

      expect(find.text('Not connected to Gather.'), findsOneWidget);
    });

    testWidgets('follows the roster while it is open, not only when tapped',
        (tester) async {
      // The sheet is its own route. It used to redraw only when something inside it
      // was pressed, so the patch confirming a new state landed unseen and the
      // chip lit up on the *next* tap.
      final state = connected(availability: 'Active');
      await tester.pumpWidget(wrap(state));
      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();
      expect(find.text('Busy'), findsOneWidget);

      state.debugApplyRoster(Roster(
        selfId: 'me',
        rows: [_row('me', name: 'Jonas', availability: 'Busy')],
      ));
      await tester.pumpAndSettle();
      expect(find.text('Busy'), findsNWidgets(2), reason: 'named under the name as well');
    });

    testWidgets('busy is orange, and not the red of something gone wrong',
        (tester) async {
      const t = GatherTokens.dark;
      expect(availabilityColor(t, 'Busy'), t.busy);
      expect(t.busy, isNot(t.danger));
      expect(t.busy, isNot(availabilityColor(t, 'Focused')));
    });

    testWidgets('the sheet is painted all the way down behind the keyboard', (tester) async {
      // The keyboard's height used to be a margin under the sheet, which left a
      // see-through strip: the map showed behind the keyboard.
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();

      tester.view.viewInsets = const FakeViewPadding(bottom: 900);
      await tester.pumpAndSettle();

      final t = tester.element(find.text('Update your status')).tokens;
      final sheet = find.byWidgetPredicate(
        (widget) => widget is Container && widget.decoration is BoxDecoration && (widget.decoration! as BoxDecoration).color == t.popover,
      );
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(tester.getRect(sheet).bottom, screen.height);
      expect(
        tester.getRect(find.text('Update your status')).bottom,
        lessThan(screen.height - 900 / tester.view.devicePixelRatio),
        reason: 'and the field itself still sits above the keyboard',
      );
    });

    testWidgets('the emoji plate sits the same distance from the top, bottom and left of the field',
        (tester) async {
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();

      final field = tester.getRect(find.byType(InputDecorator));
      final plate = tester.getRect(find.descendant(
        of: find.bySemanticsLabel('Pick an emoji'),
        matching: find.byType(Material),
      ).first);
      final left = plate.left - field.left;
      expect(left, greaterThan(0));
      expect(plate.top - field.top, closeTo(left, 0.5));
      expect(field.bottom - plate.bottom, closeTo(left, 0.5));
    });

    testWidgets('the emoji opens as a row in the sheet and closes behind a pick',
        (tester) async {
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();
      expect(find.text('🎧'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Pick an emoji'));
      await tester.pumpAndSettle();
      expect(find.text('🎧'), findsOneWidget);
      expect(find.byType(PopupMenuItem<String?>), findsNothing);

      await tester.tap(find.text('🌴'));
      await tester.pumpAndSettle();
      expect(find.text('🎧'), findsNothing, reason: 'the row closes behind a pick');
      expect(find.text('🌴'), findsOneWidget, reason: 'and the pick sits in the field');
    });

    testWidgets('there is nothing to clear until something has been set',
        (tester) async {
      await tester.pumpWidget(wrap(connected()));
      await tester.tap(find.byTooltip('Your status'));
      await tester.pumpAndSettle();

      expect(find.text('Clear it'), findsNothing);
    });
  });

  testWidgets('leaving from the faces closes them and heads for the desk',
      (tester) async {
    final state = connected()..debugHuddle = ['Ada'];
    final pops = <String>[];

    // A route over a route, because the call screen is pushed over the shell and
    // the whole point of this button is that it takes you back.
    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: Align(
                    alignment: Alignment.bottomCenter,
                    child: ControlBar(state: state, onCallScreen: true),
                  ),
                ),
              )).then((_) => pops.add('popped')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Leave the conversation'), findsOneWidget);

    await tester.tap(find.byTooltip('Leave the conversation'));
    await tester.pumpAndSettle();

    // Back to the office, because the walk to the desk is the thing you now want
    // to watch — and the map is what follows it. Staying on a call screen that
    // is about to empty would hide the only part of this with anything to see.
    expect(pops, ['popped']);
    expect(find.byTooltip('Leave the conversation'), findsNothing);
  });

  testWidgets('the same door over the map leaves without popping anything',
      (tester) async {
    // No navigator to pop and none wanted: over the office the walk home is
    // already on screen. Without a desk there is no walk either, so the leave is
    // all the door does — and it is refused here, because there is no socket.
    final state = connected()..debugHuddle = ['Ada'];
    await tester.pumpWidget(wrap(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Leave the conversation'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Leave the conversation'), findsOneWidget);
    expect(find.text('Not connected to Gather.'), findsOneWidget);
  });

  group('the camera riding along', () {
    test('a fresh desk walk is claimed once and only once', () {
      final state = AppState()..debugRequestFollow();
      addTearDown(state.dispose);

      expect(state.takeFollowRequest(), isTrue);
      // Two maps must not both ride the same walk, and a request left lying
      // around is one that fires on the next mount.
      expect(state.takeFollowRequest(), isFalse);
    });

    test('nothing pending is nothing to follow', () {
      final state = AppState();
      addTearDown(state.dispose);

      expect(state.takeFollowRequest(), isFalse);
    });

    test('a walk that finished long ago is not chased', () {
      final state = AppState()..debugRequestFollow(ago: const Duration(minutes: 10));
      addTearDown(state.dispose);

      // Opening the map later should show you the office, not jerk the camera
      // onto a desk you walked to before lunch.
      expect(state.takeFollowRequest(), isFalse);
    });
  });
}
