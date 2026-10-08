/// The call surface, without a camera anywhere near it.
///
/// Every test here swaps [CallScreen.buildTile] for an inert stand-in.
/// `RTCVideoRenderer.initialize()` needs a `MethodChannel` that does not exist
/// under `flutter test`, so the real tile cannot be built — but everything worth
/// asserting about this screen is layout, naming and the empty states, none of
/// which is pixels.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gather_client/gather_client.dart';
import 'package:gather_companion/src/app_state.dart';
import 'package:gather_companion/src/media/call.dart';
import 'package:gather_companion/src/media/media_engine.dart';
import 'package:gather_companion/src/media/spotlight_director.dart';
import 'package:gather_companion/src/reactions.dart';
import 'package:gather_companion/theme/gather_theme.dart';
import 'package:gather_companion/ui/call_screen.dart';
import 'package:gather_companion/ui/person_avatar.dart';

import 'fake_call.dart';

void main() {
  /// A tile that draws its label and nothing else.
  Widget inertTile(BuildContext context, CallTile tile) => TileFrame(tile: tile);

  Future<void> show(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildGatherTheme(),
      home: CallScreen(state: state, buildTile: inertTile),
    ));
    await tester.pump();
  }

  AppState stateWith(CallState call, {List<RosterRow> rows = const []}) {
    final state = AppState()..debugCall = call;
    if (rows.isNotEmpty) {
      state.debugApplyRoster(Roster(selfId: 'me', rows: rows));
    }
    return state;
  }

  group('the banner says who you are with', () {
    test('in every size of call, named or not', () {
      String both(List<String?> people) {
        final (:title, :subtitle) = callBannerText(people);
        return '$title / $subtitle';
      }

      expect(both(['Ada Lovelace']), 'In a call with Ada / Tap to see Ada');
      expect(both([null]), 'In a call with someone / Tap to see them');
      expect(both(['Ada Lovelace', 'Grace Hopper']), 'In a call with Ada and Grace / Tap to see everyone');
      expect(both(['Ada', null]), 'In a call with Ada and someone else / Tap to see everyone');
      expect(both([null, 'Ada']), 'In a call with Ada and someone else / Tap to see everyone',
          reason: 'the named lead, whatever order the wire sent them in');
      expect(both([null, null]), 'In a call with 2 people / Tap to see everyone');
      expect(both(['Ada', 'Grace', 'Katherine']), 'In a call with Ada and 2 others / Tap to see everyone');
      expect(both([null, 'Grace', null, 'Dorothy', 'Mary']), 'In a call with Grace and 4 others / Tap to see everyone');
      expect(both([null, null, null]), 'In a call with 3 people / Tap to see everyone');
    });

    Future<void> banner(WidgetTester tester, AppState state) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildGatherTheme(),
        home: Scaffold(body: CallBanner(state: state)),
      ));
      await tester.pump();
    }

    RosterRow person(String id, String? name, {String? cluster = 'c1', String? account}) =>
        RosterRow(id: id, name: name, clusterId: cluster, userAccountId: account);

    const me = RosterRow(id: 'me', name: 'Jonas', clusterId: 'c1');
    const alone = RosterRow(id: 'me', name: 'Jonas', clusterId: 'solo');

    /// A state as Gather and the SFU would leave it — no seams for who is in the
    /// conversation, so the banner is read off the same roster the app reads.
    AppState configured({CallState call = const CallState(), required List<RosterRow> rows}) =>
        AppState()
          ..debugCall = call
          ..debugApplyRoster(Roster(selfId: 'me', rows: rows));

    /// The cluster debounce is a real timer once anybody carries an account id.
    Future<void> settle(WidgetTester tester) => tester.pump(const Duration(seconds: 2));

    testWidgets('leads with a call glyph in a circle, not with faces', (tester) async {
      await banner(tester, configured(rows: [me, person('ada', 'Ada'), person('grace', 'Grace')]));

      expect(find.byIcon(Icons.call_rounded), findsOneWidget);
      expect(find.byType(PersonAvatar), findsNothing);
      final mark = tester.widget<Container>(
        find.ancestor(of: find.byIcon(Icons.call_rounded), matching: find.byType(Container)).first,
      );
      expect((mark.decoration! as BoxDecoration).shape, BoxShape.circle);
    });

    testWidgets('one person, from the conversation alone', (tester) async {
      final state = configured(rows: [me, person('ada', 'Ada Lovelace')]);
      expect(state.inCall, isTrue);
      await banner(tester, state);

      expect(find.text('In a call with Ada'), findsOneWidget);
      expect(find.text('Tap to see Ada'), findsOneWidget);
    });

    testWidgets('two and more, from the conversation alone', (tester) async {
      await banner(tester, configured(rows: [me, person('ada', 'Ada'), person('grace', 'Grace')]));
      expect(find.text('In a call with Ada and Grace'), findsOneWidget);

      await banner(tester, configured(rows: [
        me,
        person('ada', 'Ada'),
        person('grace', 'Grace'),
        person('kat', 'Katherine'),
        person('dot', 'Dorothy'),
        // Standing in another conversation, so not in this call.
        person('mary', 'Mary', cluster: 'c2'),
      ]));
      expect(find.text('In a call with Ada and 3 others'), findsOneWidget);
    });

    testWidgets('one person, from the media plane alone', (tester) async {
      // Somebody the SFU is sending while the cluster has already let go — the
      // half second at the end of a conversation.
      final state = configured(
        call: const CallState(participants: [CallParticipant(srcId: 'acc-ada', hasAudio: true)]),
        rows: [alone, person('ada', 'Ada', cluster: null, account: 'acc-ada')],
      );
      expect(state.inCall, isTrue);
      await banner(tester, state);
      await settle(tester);

      expect(find.text('In a call with Ada'), findsOneWidget);
    });

    testWidgets('several people, from the media plane alone', (tester) async {
      await banner(
        tester,
        configured(
          call: const CallState(participants: [
            CallParticipant(srcId: 'acc-ada', hasAudio: true),
            CallParticipant(srcId: 'acc-grace', hasVideo: true),
            CallParticipant(srcId: 'acc-kat'),
          ]),
          rows: [
            alone,
            person('ada', 'Ada', cluster: null, account: 'acc-ada'),
            person('grace', 'Grace', cluster: null, account: 'acc-grace'),
            person('kat', 'Katherine', cluster: null, account: 'acc-kat'),
          ],
        ),
      );
      await settle(tester);

      expect(find.text('In a call with Ada and 2 others'), findsOneWidget);
    });

    testWidgets('somebody on both planes is counted once', (tester) async {
      await banner(
        tester,
        configured(
          call: const CallState(participants: [CallParticipant(srcId: 'acc-ada', hasAudio: true)]),
          rows: [
            me,
            person('ada', 'Ada', account: 'acc-ada'),
            // In the conversation with everything off, so never a participant.
            person('grace', 'Grace', account: 'acc-grace'),
          ],
        ),
      );
      await settle(tester);

      expect(find.text('In a call with Ada and Grace'), findsOneWidget);
    });

    testWidgets('somebody the roster cannot name yet', (tester) async {
      await banner(
        tester,
        configured(
          call: const CallState(participants: [CallParticipant(srcId: 'acc-new', hasAudio: true)]),
          rows: [alone],
        ),
      );
      expect(find.text('In a call with someone'), findsOneWidget);
      expect(find.text('Tap to see them'), findsOneWidget);

      await banner(
        tester,
        configured(
          call: const CallState(participants: [CallParticipant(srcId: 'acc-new', hasAudio: true)]),
          rows: [me, person('ada', 'Ada')],
        ),
      );
      expect(find.text('In a call with Ada and someone else'), findsOneWidget);
    });

    testWidgets('it follows the call as people come and go', (tester) async {
      final state = configured(rows: [me, person('ada', 'Ada')]);
      await banner(tester, state);
      expect(find.text('In a call with Ada'), findsOneWidget);

      state.debugApplyRoster(Roster(selfId: 'me', rows: [me, person('ada', 'Ada'), person('grace', 'Grace')]));
      await tester.pump();
      expect(find.text('In a call with Ada and Grace'), findsOneWidget);

      state.debugApplyRoster(Roster(selfId: 'me', rows: [me, person('grace', 'Grace')]));
      await tester.pump();
      expect(find.text('In a call with Grace'), findsOneWidget);

      state.debugApplyRoster(const Roster(selfId: 'me', rows: [alone]));
      expect(state.inCall, isFalse, reason: 'and there is no call left to have a banner for');
    });

    testWidgets('the screen it opens shows the same people', (tester) async {
      // Somebody in the conversation with nothing published gets a tile, rather
      // than the screen saying "Nobody else here" under a banner that named them.
      await show(tester, configured(rows: [me, person('ada', 'Ada')]));

      expect(find.text('Ada'), findsOneWidget);
      expect(find.text('1 other person'), findsOneWidget);
      expect(find.textContaining('Nobody is in this conversation yet'), findsNothing);
    });
  });

  testWidgets('the first face starts directly under the header, however many there are',
      (tester) async {
    for (final count in [1, 2, 3]) {
      await show(
        tester,
        stateWith(
          CallState(participants: [
            for (var i = 0; i < count; i++) CallParticipant(srcId: 'account-$i', hasAudio: true),
          ]),
          rows: [
            for (var i = 0; i < count; i++) RosterRow(id: 'space-$i', name: 'Person $i', userAccountId: 'account-$i'),
          ],
        ),
      );

      final header = tester.getRect(find.byTooltip('Back'));
      final headerBottom = tester.getBottomLeft(find.ancestor(of: find.byTooltip('Back'), matching: find.byType(Padding)).first).dy;
      final first = tester.getRect(find.byType(TileFrame).first);
      expect(first.top, headerBottom, reason: '$count on screen');
      expect(first.top, greaterThan(header.bottom));
    }
  });

  testWidgets('the mute pip is exactly as tall as the name beside it', (tester) async {
    await show(
      tester,
      stateWith(
        const CallState(participants: [
          CallParticipant(srcId: 'account-1', hasAudio: true, audioPaused: true),
        ]),
        rows: const [RosterRow(id: 'space-1', name: 'Mira', userAccountId: 'account-1')],
      ),
    );

    Rect plate(Finder inside) =>
        tester.getRect(find.ancestor(of: inside, matching: find.byType(DecoratedBox)).first);
    final name = plate(find.text('Mira'));
    final muted = plate(find.byIcon(Icons.mic_off));
    expect(muted.height, name.height);
    expect(muted.top, name.top);
  });

  testWidgets('an empty call says so rather than showing a blank screen',
      (tester) async {
    await show(tester, stateWith(const CallState()));

    expect(find.textContaining('Nobody is in this conversation yet'), findsOneWidget);
    expect(find.text('Nobody else here'), findsOneWidget);
  });

  testWidgets('somebody the roster knows gets their name on the tile',
      (tester) async {
    await show(
      tester,
      stateWith(
        const CallState(participants: [
          CallParticipant(srcId: 'account-1', hasAudio: true),
        ]),
        rows: const [
          RosterRow(id: 'space-1', name: 'Mira', userAccountId: 'account-1'),
        ],
      ),
    );

    expect(find.text('Mira'), findsOneWidget);
    expect(find.text('1 other person'), findsOneWidget);
  });

  testWidgets('somebody the roster cannot place is still in the call',
      (tester) async {
    // The two planes are keyed differently and a row can arrive without its
    // `userAccountId`. Dropping the tile would be the wrong repair: we can hear
    // them, so they are demonstrably there.
    await show(
      tester,
      stateWith(const CallState(participants: [
        CallParticipant(srcId: 'account-unknown', hasAudio: true),
      ])),
    );

    expect(find.text('Someone'), findsOneWidget);
    expect(find.text('1 other person'), findsOneWidget);
  });

  testWidgets('a muted person is present, not absent', (tester) async {
    await show(
      tester,
      stateWith(
        const CallState(participants: [
          CallParticipant(srcId: 'account-1', hasAudio: true, audioPaused: true),
        ]),
        rows: const [
          RosterRow(id: 'space-1', name: 'Mira', userAccountId: 'account-1'),
        ],
      ),
    );

    expect(find.text('Mira'), findsOneWidget);
    expect(find.byIcon(Icons.mic_off), findsOneWidget);
  });

  testWidgets('the self tile appears only once the hardware is open',
      (tester) async {
    await show(tester, stateWith(const CallState()));
    expect(find.text('You'), findsNothing);

    await show(
      tester,
      stateWith(const CallState(media: LocalMediaState(capturing: true))),
    );
    expect(find.text('You'), findsOneWidget);
    // Still nobody else — the header counts the room, not the tiles.
    expect(find.text('Nobody else here'), findsOneWidget);
  });

  testWidgets('more than two people go to a grid', (tester) async {
    await show(
      tester,
      stateWith(const CallState(participants: [
        CallParticipant(srcId: 'a', hasAudio: true),
        CallParticipant(srcId: 'b', hasAudio: true),
        CallParticipant(srcId: 'c', hasAudio: true),
      ])),
    );

    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('3 other people'), findsOneWidget);
  });

  testWidgets('a face filling the screen is asked for at full size',
      (tester) async {
    final call = FakeCall();
    final state = stateWith(const CallState(participants: [
      CallParticipant(srcId: 'account-1', hasVideo: true),
    ]))
      ..debugAttachCall(call);
    await show(tester, state);

    // Nobody sends more than their smallest layer until a consumer asks, so
    // without this the one face on a phone screen stays a thumbnail.
    expect(call.watching.last.srcIds, ['account-1']);
    expect(call.watching.last.quality, VideoQuality.full);
  });

  testWidgets('a grid of four asks for thumbnails', (tester) async {
    final call = FakeCall();
    final state = stateWith(const CallState(
      media: LocalMediaState(capturing: true),
      participants: [
        CallParticipant(srcId: 'a', hasVideo: true),
        CallParticipant(srcId: 'b', hasVideo: true),
        CallParticipant(srcId: 'c', hasVideo: true),
      ],
    ))
      ..debugAttachCall(call);
    await show(tester, state);

    // Four tiles counting our own, so nobody is bigger than a quarter of a
    // phone. Asking for full frames here would spend three uplinks on detail
    // that lands in a hundred-pixel box.
    expect(call.watching.last.quality, VideoQuality.thumbnail);
    expect(call.watching.last.srcIds, ['a', 'b', 'c']);
  });

  testWidgets('closing the screen tells everybody to stop sending detail',
      (tester) async {
    final call = FakeCall();
    final state = stateWith(const CallState(participants: [
      CallParticipant(srcId: 'account-1', hasVideo: true),
    ]))
      ..debugAttachCall(call);
    await show(tester, state);
    expect(call.watching.last.quality, VideoQuality.full);

    // The map draws no video, so once this route is gone nobody is looking at
    // anything — and until it is said, a colleague keeps encoding a big layer
    // for a screen that no longer exists.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(call.watching.last.srcIds, isEmpty);
    expect(call.watching.last.quality, VideoQuality.thumbnail);
  });

  test('a screen share is what the tile shows, when there is one', () {
    final state = AppState()
      ..debugCall = const CallState(participants: [
        CallParticipant(
          srcId: 'account-1',
          hasVideo: true,
          sharingScreen: true,
        ),
      ]);

    final tile = tilesFor(state).single;
    expect(tile.sharingScreen, isTrue);
    // No live call behind this state, so there is no stream to pick — the point
    // is that the tile carries the flag the layout reads.
    expect(tile.stream, isNull);
  });

  group('reactions and the speaking ring', () {
    const me = RosterRow(id: 'me', name: 'Jonas', clusterId: 'c1', connected: true);
    const luca = RosterRow(
      id: 'luca',
      name: 'Luca',
      clusterId: 'c1',
      userAccountId: 'account-luca',
      connected: true,
      speaking: true,
    );

    test('somebody talking is drawn talking, and nobody else is', () {
      final state = stateWith(
        const CallState(participants: [CallParticipant(srcId: 'account-luca', hasAudio: true)]),
        rows: [me, luca],
      );

      final tile = tilesFor(state).single;
      expect(tile.label, 'Luca');
      expect(tile.speaking, isTrue, reason: "off the roster's own `speaking`");
    });

    testWidgets('our own tile speaks from our own microphone', (tester) async {
      final call = FakeCall();
      final state = stateWith(
        const CallState(media: LocalMediaState(capturing: true, audioEnabled: true)),
        rows: [me],
      )..debugAttachCall(call);
      addTearDown(state.dispose);

      expect(tilesFor(state).single.speaking, isFalse);

      call.speak(true);
      await tester.pump();

      // Not from the roster. Gather echoes `speaking` back within a beat, and a
      // beat of lag on your *own* face reads as the app being slow.
      final self = tilesFor(state).single;
      expect(self.isSelf, isTrue);
      expect(self.speaking, isTrue);
    });

    testWidgets('the ring is painted over the video, not behind it', (tester) async {
      Future<BoxDecoration> ringOf(bool speaking) async {
        await tester.pumpWidget(MaterialApp(
          theme: buildGatherTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 150,
                child: TileFrame(
                  tile: CallTile(
                    id: 'luca',
                    label: 'Luca',
                    isSelf: false,
                    videoLive: true,
                    muted: false,
                    sharingScreen: false,
                    speaking: speaking,
                  ),
                  // Stands in for the platform view: opaque, and filling the
                  // tile, which is exactly what hid the ring.
                  video: const ColoredBox(color: Color(0xFFFFFFFF)),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final box = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer).first);
        return box.foregroundDecoration! as BoxDecoration;
      }

      final t = buildGatherTheme().extension<GatherTokens>()!;

      // In the *foreground*. A background decoration is painted before the
      // child, and the child here is a full-bleed video — so the ring was drawn
      // and then covered, on every tile with a camera on.
      expect((await ringOf(true)).border!.top.color, t.ok);
      expect((await ringOf(true)).border!.top.width, 3);

      final quiet = await ringOf(false);
      expect(quiet.border!.top.color, t.border);
      expect(quiet.border!.top.width, 1);
    });

    testWidgets('reactions land on the tile of whoever sent them', (tester) async {
      final state = stateWith(
        const CallState(participants: [CallParticipant(srcId: 'account-luca', hasAudio: true)]),
        rows: [me, luca],
      );
      addTearDown(state.dispose);

      state.reactions.note('luca', '🎉');
      await tester.pump(const Duration(milliseconds: 300));
      state.reactions.note('luca', '🔥');

      // Both, in press order. A second tap adds to what is in the air rather
      // than replacing it — three claps are three claps.
      expect([for (final f in tilesFor(state).single.reactions) f.emote], ['🎉', '🔥']);

      await tester.pump(reactionLinger);
      expect(tilesFor(state).single.reactions, isEmpty,
          reason: 'nothing on the wire ever says a reaction ended');
    });

    testWidgets('it is drawn over the face, and only while it lasts',
        (tester) async {
      final state = stateWith(
        const CallState(participants: [CallParticipant(srcId: 'account-luca', hasAudio: true)]),
        rows: [me, luca],
      );
      addTearDown(state.dispose);
      await show(tester, state);

      expect(find.text('🎉'), findsNothing);

      state.reactions.note('luca', '🎉');
      await tester.pump();
      expect(find.text('🎉'), findsOneWidget);

      // A second press while the first is still climbing draws a second emoji,
      // and leaves the first where it was.
      await tester.pump(const Duration(milliseconds: 400));
      state.reactions.note('luca', '🎉');
      await tester.pump();
      expect(find.text('🎉'), findsNWidgets(2));

      // The screen listens to the store as well as to the state — the expiry
      // arrives on a timer, with no roster and no tap behind it, so a screen
      // rebuilding only on `AppState` would leave the emoji up for good.
      await tester.pump(reactionLinger);
      await tester.pump();
      expect(find.text('🎉'), findsNothing);
    });
  });

  group('the spotlight — manual and automatic', () {
    // A shared cluster, so a change in who is talking actually reaches the
    // screen: [AppState] only republishes a speaking change for members of your
    // own conversation — the auto machine is deaf without it.
    const me = RosterRow(id: 'me', name: 'Jonas', clusterId: 'c1', connected: true);

    RosterRow person(String i, {bool speaking = false}) => RosterRow(
          id: 'space-$i',
          name: 'Person $i',
          clusterId: 'c1',
          userAccountId: 'account-$i',
          speaking: speaking,
        );

    CallState threeFaces() => const CallState(participants: [
          CallParticipant(srcId: 'account-0', hasVideo: true),
          CallParticipant(srcId: 'account-1', hasVideo: true),
          CallParticipant(srcId: 'account-2', hasVideo: true),
        ]);

    /// The screen with a zero dwell, so the auto machine promotes on the sample
    /// rather than after a hold `tester.pump` cannot advance. `linger` defaults
    /// high so a silent big view stays up across a pump — `DateTime.now()` does
    /// not advance under `tester.pump`, so a real timeout cannot be driven from
    /// one; pass `Duration.zero` to exercise the immediate fallback to the grid.
    Future<void> showAuto(
      WidgetTester tester,
      AppState state, {
      Duration linger = const Duration(seconds: 5),
    }) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildGatherTheme(),
        home: CallScreen(
          state: state,
          buildTile: inertTile,
          director: SpotlightDirector(dwell: Duration.zero, linger: linger),
        ),
      ));
      await tester.pump();
    }

    testWidgets('the mode toggle is there, and starts on manual grid', (tester) async {
      final state = stateWith(threeFaces(), rows: [me, person('0'), person('1'), person('2')]);
      addTearDown(state.dispose);
      await show(tester, state);

      expect(find.text('Manual'), findsOneWidget);
      expect(find.text('Auto'), findsOneWidget);
      // Nothing enlarged yet.
      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('Everyone'), findsNothing);
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });

    testWidgets('tapping a face enlarges it, and the return button goes back', (tester) async {
      final call = FakeCall();
      final state = stateWith(threeFaces(), rows: [me, person('0'), person('1'), person('2')])
        ..debugAttachCall(call);
      addTearDown(state.dispose);
      await show(tester, state);

      // By key, not by the label: in the 800×600 test surface a 3:4 grid tile is
      // tall enough that its name plate sits behind the bottom dock, where a tap
      // on the text would miss. The tile's own centre is clear.
      await tester.tap(find.byKey(const ValueKey('space-0')));
      await tester.pump();

      // Big view: Person 0 is drawn twice — once large, once in the strip — and
      // the grid has given way to the return button.
      expect(find.byType(GridView), findsNothing);
      expect(find.text('Everyone'), findsOneWidget);
      expect(find.text('Person 0'), findsNWidgets(2));

      // And that one face is now asked for at full quality, everyone else left
      // on the thumbnail the SFU sends by default.
      expect(call.watching.last.srcIds, ['account-0']);
      expect(call.watching.last.quality, VideoQuality.full);

      await tester.tap(find.text('Everyone'));
      await tester.pump();
      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('Everyone'), findsNothing);
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });

    testWidgets('auto follows the talker, and lingers on them when they stop', (tester) async {
      final call = FakeCall();
      final state = stateWith(
        threeFaces(),
        rows: [me, person('0', speaking: true), person('1'), person('2')],
      )..debugAttachCall(call);
      addTearDown(state.dispose);
      await showAuto(tester, state);

      await tester.tap(find.text('Auto'));
      await tester.pump();

      // The one speaker is enlarged, at full quality.
      expect(find.text('Everyone'), findsOneWidget);
      expect(find.text('Person 0'), findsNWidgets(2));
      expect(call.watching.last.srcIds, ['account-0']);
      expect(call.watching.last.quality, VideoQuality.full);

      // Person 0 stops. Nobody is talking, but inside the linger the big view
      // stays on them rather than flashing back to the grid.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [me, person('0'), person('1'), person('2')]));
      await tester.pump();
      expect(find.text('Everyone'), findsOneWidget, reason: 'still lingering, big view held');
      expect(find.byType(GridView), findsNothing);
      expect(find.text('Person 0'), findsNWidgets(2));
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });

    testWidgets('the lingering big view falls back to the grid once the lull outlasts the linger', (tester) async {
      final call = FakeCall();
      final state = stateWith(
        threeFaces(),
        rows: [me, person('0', speaking: true), person('1'), person('2')],
      )..debugAttachCall(call);
      addTearDown(state.dispose);
      // Zero linger: the first silent sample is already past the timeout, so the
      // fallback fires without a wall clock the test cannot advance.
      await showAuto(tester, state, linger: Duration.zero);

      await tester.tap(find.text('Auto'));
      await tester.pump();
      expect(find.text('Person 0'), findsNWidgets(2));

      // Person 0 stops; with the linger already spent the view drops to the grid.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [me, person('0'), person('1'), person('2')]));
      await tester.pump();
      expect(find.text('Everyone'), findsNothing);
      expect(find.byType(GridView), findsOneWidget);
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });

    testWidgets('a tap in auto pins, and the next speaker overrides it without leaving auto', (tester) async {
      final state = stateWith(
        threeFaces(),
        rows: [me, person('0', speaking: true), person('1'), person('2')],
      );
      addTearDown(state.dispose);
      await showAuto(tester, state);
      await tester.tap(find.text('Auto'));
      await tester.pump();
      expect(find.text('Person 0'), findsNWidgets(2), reason: 'auto enlarged the talker');

      // Pin Person 1 from the strip. The view moves to them at once.
      await tester.tap(find.byKey(const ValueKey('strip-space-1')));
      await tester.pump();
      expect(find.text('Person 1'), findsNWidgets(2));

      // Still auto: when the floor passes to Person 2, the pin gives way.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [me, person('0'), person('1'), person('2', speaking: true)]));
      await tester.pump();
      expect(find.text('Person 2'), findsNWidgets(2), reason: 'auto overrode the pin');
      expect(find.text('Auto'), findsOneWidget, reason: 'and never left auto mode');
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });

    testWidgets('auto never enlarges yourself for talking', (tester) async {
      final call = FakeCall();
      final state = stateWith(
        const CallState(
          media: LocalMediaState(capturing: true, audioEnabled: true),
          participants: [CallParticipant(srcId: 'account-1', hasVideo: true)],
        ),
        rows: [me, person('1')],
      )..debugAttachCall(call);
      addTearDown(state.dispose);
      await showAuto(tester, state);
      await tester.tap(find.text('Auto'));
      await tester.pump();

      // You start talking. The room does not watch you watch it — the view stays
      // on the overview.
      call.speak(true);
      await tester.pump();
      expect(find.text('Everyone'), findsNothing);
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });

    testWidgets('switching from a manual face to auto holds the big view instead of dropping to the grid', (tester) async {
      // Nobody is talking, so auto has nothing of its own to enlarge: the only
      // thing keeping the big view up across the switch is carrying the manual
      // pick over as auto's temporary pin.
      final state = stateWith(threeFaces(), rows: [me, person('0'), person('1'), person('2')]);
      addTearDown(state.dispose);
      await showAuto(tester, state);

      await tester.tap(find.byKey(const ValueKey('space-1')));
      await tester.pump();
      expect(find.text('Person 1'), findsNWidgets(2), reason: 'manually enlarged');

      await tester.tap(find.text('Auto'));
      await tester.pump();
      expect(find.byType(GridView), findsNothing, reason: 'the big view held across the switch');
      expect(find.text('Person 1'), findsNWidgets(2));

      // Still auto: the next speaker to hold the floor takes the pin's place.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [me, person('0'), person('1'), person('2', speaking: true)]));
      await tester.pump();
      expect(find.text('Person 2'), findsNWidgets(2), reason: 'a speaker overrode the carried pin');
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });

    testWidgets('enlarging your own face leaves everyone else on a thumbnail, not the grid split', (tester) async {
      final call = FakeCall();
      final state = stateWith(
        const CallState(
          media: LocalMediaState(capturing: true),
          participants: [CallParticipant(srcId: 'account-1', hasVideo: true)],
        ),
        rows: [me, person('1')],
      )..debugAttachCall(call);
      addTearDown(state.dispose);
      await show(tester, state);

      // Two in the room counting us, so the overview split asks the one remote
      // for the half layer.
      expect(call.watching.last.quality, VideoQuality.half);

      // Enlarge yourself. Your own face has nothing on the media plane to boost,
      // and the remote is now only a strip thumbnail — so the request drops to
      // the low layer rather than staying on the grid's count-based split.
      // The self tile has no map position in this state, so it takes the 'self'
      // fallback id rather than a roster id.
      await tester.tap(find.byKey(const ValueKey('self')));
      await tester.pump();
      expect(call.watching.last.quality, VideoQuality.thumbnail);
      expect(call.watching.last.srcIds, ['account-1']);
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });

    testWidgets('the production dwell timer promotes the held speaker once the clock advances', (tester) async {
      // A real (non-zero) dwell with an injected clock, so the live timer path —
      // schedule on a pending speaker, fire on its deadline — is exercised, not
      // the zero-dwell shortcut the other auto tests take.
      final call = FakeCall();
      var now = DateTime(2026);
      final state = stateWith(threeFaces(), rows: [me, person('0'), person('1'), person('2')])
        ..debugAttachCall(call);
      addTearDown(state.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: buildGatherTheme(),
        home: CallScreen(
          state: state,
          buildTile: inertTile,
          director: SpotlightDirector(
            dwell: const Duration(milliseconds: 1500),
            linger: const Duration(seconds: 5),
          ),
          now: () => now,
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('Auto'));
      await tester.pump();
      expect(find.byType(GridView), findsOneWidget, reason: 'nobody has held the floor yet');

      // Person 0 takes the floor. The dwell has not elapsed, so the view waits —
      // this is the moment the timer is armed.
      state.debugApplyRoster(Roster(selfId: 'me', rows: [me, person('0', speaking: true), person('1'), person('2')]));
      await tester.pump();
      expect(find.byType(GridView), findsOneWidget, reason: 'the floor is not yet held long enough');

      // The dwell elapses: advance the injected clock and let the armed timer fire.
      now = now.add(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.text('Person 0'), findsNWidgets(2), reason: 'the dwell timer promoted the held speaker');
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });
  });

  group('the big view crops or letterboxes', () {
    CallTile tile({required bool sharingScreen}) => CallTile(
          id: 'x',
          label: 'X',
          isSelf: false,
          videoLive: true,
          muted: false,
          sharingScreen: sharingScreen,
        );

    test('a camera face crops by default, a shared screen letterboxes', () {
      expect(bigCropsByDefault(tile(sharingScreen: false)), isTrue,
          reason: 'cover is what a face wants');
      expect(bigCropsByDefault(tile(sharingScreen: true)), isFalse,
          reason: 'a shared screen shows its edges, not a cropped middle');
    });

    testWidgets('the fit button names the result of the tap and reports it', (tester) async {
      var taps = 0;
      Future<void> pumpButton(bool cropOn) => tester.pumpWidget(MaterialApp(
            theme: buildGatherTheme(),
            home: Scaffold(
              body: CropButton(cropOn: cropOn, onTap: () => taps++),
            ),
          ));

      // Cropped now: the button offers the whole frame.
      await pumpButton(true);
      expect(find.text('Fit'), findsOneWidget);
      expect(find.text('Fill'), findsNothing);
      expect(find.byIcon(Icons.fit_screen_outlined), findsOneWidget);

      await tester.tap(find.text('Fit'));
      expect(taps, 1);

      // Letterboxed now: the button offers the crop.
      await pumpButton(false);
      expect(find.text('Fill'), findsOneWidget);
      expect(find.text('Fit'), findsNothing);
      expect(find.byIcon(Icons.crop_outlined), findsOneWidget);

      await tester.tap(find.text('Fill'));
      expect(taps, 2);
    });

    testWidgets('no fit button over a big face with nothing on the wire', (tester) async {
      // The spotlight tiles here are roster-only — `hasVideo` without a stream a
      // platform-free test can make — so there is nothing to fit and the button
      // stays away. The toggle only earns its place once a frame is arriving.
      final state = stateWith(
        const CallState(participants: [
          CallParticipant(srcId: 'account-0', hasVideo: true),
          CallParticipant(srcId: 'account-1', hasVideo: true),
        ]),
        rows: const [
          RosterRow(id: 'me', name: 'Jonas', clusterId: 'c1', connected: true),
          RosterRow(id: 'space-0', name: 'Person 0', clusterId: 'c1', userAccountId: 'account-0'),
          RosterRow(id: 'space-1', name: 'Person 1', clusterId: 'c1', userAccountId: 'account-1'),
        ],
      );
      addTearDown(state.dispose);
      await show(tester, state);

      await tester.tap(find.byKey(const ValueKey('space-0')));
      await tester.pump();

      expect(find.text('Everyone'), findsOneWidget, reason: 'the big view is up');
      expect(find.text('Fit'), findsNothing);
      expect(find.text('Fill'), findsNothing);
      await tester.pump(const Duration(seconds: 2)); // flush the cluster debounce
    });
  });
}
