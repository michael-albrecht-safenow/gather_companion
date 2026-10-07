<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# ui

## Purpose

The screens. Each file holds one public entry point plus the private
widgets it composes — there is no shared widget library, because nothing has
needed to be shared twice yet.

`home_shell.dart` is the one exception to "one file, one screen": it holds the
three tabs together and is what the app shows once it is paired.

## Key Files

| File | Description |
|------|-------------|
| `home_shell.dart` | `HomeShell` — the three destinations and the rail between them. `_Tab`, `_TabView`, `_Dock`, `_NavItem`. Activity, Office, Settings, left to right, opening on Activity. The shell's `Scaffold` has `resizeToAvoidBottomInset: false` and zeroes `viewInsets` for the tabs: the keyboard opened by the status sheet used to shrink the office's viewport, rescaling the floor and leaving a black strip behind the keyboard. **`_Tab`'s declaration order is the only place that order lives**: the rail and the `IndexedStack` are both built by walking `_Tab.values`, because they were once hand-written as parallel lists and reordering the enum alone silently swapped two tabs' bodies. All three tabs sit in an `IndexedStack` so the map keeps its decoded artwork, its pan and zoom, and its already-played opening shot; each is wrapped in a `TickerMode` so the ones behind are kept without being kept *running*. `AppState.positions` is merged in only while the map is the selected tab. The rail floats over the content rather than docking under it, and the shell adds `kRailInset` to the bottom of every tab's `MediaQuery` padding so each tab's existing `SafeArea(top: false)` clears it without knowing a rail exists. The dock's width never drops below `kRailMinWidth` (320): left to its intrinsic width the nav row alone was a 180-point pill, and the island lurched sideways whenever the office's control row came or went. |
| `activity_screen.dart` | The activity tab: `_History`, which is Gather's *own* activity feed: `_ActivityTile`, `_Glyph`, `_NoHistory`, `_withDayHeaders`. Before the first read answers, `_Skeleton` — bones cut to the real rows' measurements, gated on `AppState.activityFetched` so "nothing yet" is only ever said once it has been checked; a fetched-and-empty feed and a failed fetch stay two different sentences in `_NoHistory`. The bones sit *over* the list rather than in it, so the two cross-fade in the same pixels — one curve and its reverse, so the opacities always sum to one — and so the breath is never restarted by the skeleton moving in the tree. The faces are **not** waited for: holding the rows back until every avatar had decoded was built and then removed, because a list of names with coloured initials is a list you can read and no list at all is not. `_warmFaces` precaches them behind the list instead, which is also what makes the same colleague on four rows one download. Waves, mentions, reactions, thread replies and "your meeting notes are ready", read over REST from `../../packages/gather_client/lib/src/activity_feed.dart` and topped up by `WaveEvent` off the socket, so nothing polls; grouped by day, because the list spans months. Pull-to-refresh reads the feed and nothing else — it used to also drop the socket, whose only visible effect was the link strip announcing the reconnect the pull had caused; the strip is gone and the settings tab owns up to a dead connection instead. Mark-all-read is the double-check icon in the app bar, words in its tooltip. Only the subscription-backed kinds are tappable: a memo can be marked read in Gather and a wave cannot — its read state is a chat cursor — so waves show no dot rather than one the screen could not clear. Was `feed_screen.dart` until the rail gave it a name a person would use, and lost its `_TopBar` when the rail and the settings tab took over what was in it. |
| `settings_screen.dart` | `SettingsScreen` — what the app can tell you about itself, and the one switch it owns. `_SectionLabel`, `_Card`, `_Row`, `_PartyRow`, `_PartySwitch`. The connection and the space it is in, a reconnect, party mode, the mic and camera check, the paired computer and whether it can still wake the app, and unpairing. Party mode moved here from the activity tab — it was the one control on a screen of answers — and traded its spinning gradient card for a row with a hand-drawn switch (brand for on; a `Switch` would bring Material's own track colours). Replaced the `PopupMenuButton` on the feed: a menu can only hold verbs, and most of what belongs here is nouns. The `Notifier` flags are deliberately absent until something persists them. |
| `map_screen.dart` | The office, drawn in Gather's own artwork. `_Where`, `_HeadCount`, `_Followers` (the follower count as the head count's accent-tinted sibling pill, absent at zero — moved here from the activity tab), `_Waiting`, `_Plan`, `_Legend`, `_OfficePainter`, plus the `officePainter()` and `framedOn()` test seams. Floors, walls, furniture and avatars, sorted into one depth order; the old schematic is still underneath for while the art is in flight. Somebody with no outfit — a guest, typically — is drawn on Gather's own default sheet, the grey **ghost** (`assets/avatar-ghost.png`, served by `ArtCache` under `ghostAvatarUrl`), on the same animation table as a dressed body; the coloured pin is only what stands in for the frame or two before that sheet has decoded. The desktop client keeps the ghost as a data URI in its bundle and never swaps it out when `hashOutfit` names nothing, which is why it is an asset here rather than a URL. People walk rather than hop — see `../src/map_motion.dart` — except when they teleport, which is drawn as a teleport: the body dissolves where it stood while a new one fades and grows into place at the destination, two entries in the same depth list so each folds behind the right desk. They are otherwise drawn on the client's own animation table: the walk cycle while they are mid-step, `idle-sit` on a chair, the talking loop while they are speaking. Labels are Gather's own capsules: a name plate above each head with an availability dot, and the ten **team** zones named above themselves — the fourteen meeting rooms are deliberately not written on the floor, since the one you are standing in is already in the app bar. Covers the screen at minimum zoom and cannot be panned off it (`boundaryMargin: EdgeInsets.zero`, and `framedOn` clamps the transforms the screen sets itself); opens centred on you at 3×, pinch/double-tap to 20×. Built by `home_shell.dart` on `Listenable.merge([state, state.positions])` while it is the selected tab; `state` alone leaves it frozen, because walking changes nothing the presence tracker reports. Its body is deliberately not in a `SafeArea` — the floor runs under the home indicator and under the nav rail — while the D-pad, the *Go to* pill and the legend are, which is how they lift clear of the rail without this file knowing about it. **Tapping the floor picks somewhere to go**, and `_GoTo` is the pill that acts on it. The split is Gather's own: on the desktop a single click only highlights and a *double* click moves, so a tap and a button are the two beats of that gesture with a phone's missing hover put back. Which of the two a tap means is `navigatesToTile`, transcribed — the main floor, the lobby and a team's corner select a *tile*, and a meeting room, a desk or a coworking area selects the whole *room*, because "go to the Boardroom" is what somebody means. `_walkableNear` forgives a near miss, and **forgives a hit on furniture too**: a blocked tile hands back the nearest free one rather than selecting nothing, which is what the desktop client does and what tapping a chair depends on. Its box is Gather's own — 2 tiles, widened to 4 — and the zoom may only widen it, never narrow it; a one-ring search meant most of the office's furniture selected nothing at all when zoomed in. **Where the client has a rule, this screen uses the client's rule and not one of its own.** It briefly refused tiles outside the office footprint, reasoning that an unwalkable destination now ends in a teleport and the void is not somewhere anybody means to go; the client has no such restriction — it bounds-checks against the whole grid — and the way out of the void is another tap. An invented restriction is how two clients driving one avatar start disagreeing. `_paintSelection` draws the reticle: four black corner brackets, Gather's own shape (`immersive-tile-highlighter-tl.png`), sized as a *proportion of the tile* with the on-glass figures acting only as ceilings — an earlier version held them to a minimum size on the glass and zoomed out that inflated the mark to over twice the tile it was marking. Static, unlike Gather's, which lerps between tiles and fades after three seconds: `MapMotion`'s ticker stops itself when nobody is moving, and a selection that faded out from under the button still waiting on it would be incoherent. **The double tap is counted by hand**, in `_onTap`, and the `GestureDetector` carries no `onDoubleTap` at all: one that does holds *every* tap until the double-tap window closes, which put a third of a second between the finger and the reticle. The two gestures do not really conflict — selecting is free and instantly reversible, so the first tap simply does it and the second takes it back on its way to zooming. That is not true of the desktop client, where a double click *moves you*, which is exactly why it waits and this does not. **A shut door is refused twice, from both ends.** A tap asks `AppState.canEnter` — `canBeEnteredBy`, minus the two clauses only the server can evaluate — so your own locked desk and the room you are already inside stay selectable, which testing `room.locked` alone got wrong. The other end is `AppState.notices`: Gather refuses a walk into a locked area by publishing an event to you alone and sending no patch, which is a walk that quietly stops making progress, so the screen listens and turns it into the same sentence. `_Kart` is the go-kart, latched: Gather picks a gait from the distance on its own and needs no control for it, but its other door to driving is a held shift key, and a phone has nothing to hold. It means *drive*, not "drive if it is far enough" — see `Walk.boost` for the version of this that was a ceiling and looked broken. `_paintKart` draws the thing itself, on the body's own tile and **over** the legs (`bringToTop`), which is what makes a flat 32×32 sprite read as something being sat in; the sheet is fetched only once somebody is actually driving. The kart plate is square and takes the *Go here* pill's height (`IntrinsicHeight` + `AspectRatio`); sized by their own padding the two came out two points apart. **The desk walk is followed**: `AppState.goToMyDesk` emits on `AppState.followMe`, and `_followFrame` eases the view onto your animated position on its own ticker until you have arrived and the view has caught up — a pan or pinch, or a double tap, lets go. A tapped tile is not followed; it was on screen to be tapped. |
| `control_bar.dart` | `ControlBar` — Gather's own bottom bar, adapted: you (tap for the status sheet), your microphone, your camera, the eight reactions, and **one door** — the way back to your desk and the way out of the conversation you are in, which are one button because they are one intention (and one button on the desktop). Undecorated rows, painted into an island by `DockIsland` — the shell stacks the controls over the navigation in one, and `CallScreen` carries the controls alone in another (`ControlBar(onCallScreen: true)`, cleared by `kControlDockInset`). The people button only exists to see your own camera while you are *not* in a call (`AppState.inCall`); in a call the office's `CallBanner` is the way to the faces. `kControlBarInset` is what the map tab pays for it. Gather's screen-share is deliberately absent — there is nothing on a phone worth sharing. The door never leaves the *space*: the socket this app holds **is** its presence, so a door out of the space would switch the product off. Mic and camera drive a real capture session through `../src/media/call.dart` and publish to the SFU. **The door is `_doorButton`**, `moveSpaceUserToDesk` transcribed with the conversation folded in, and it is situation-specific: in a conversation it reads *Leave the conversation* and does `leaveCluster` **then** the desk walk (leaving alone is not a way out — proximity puts you straight back in), and on the call screen it pops back to the office last so the walk is what you watch; away from your desk it reads *Back to my desk* and walks you there — a walk and not a hop, aimed at the seats first; at your desk with nobody around it is dim. It exists whenever there is a desk to go to *or* a conversation to leave. There used to be a separate `logout` button for the conversation, with a third meaning on the call screen; it went because three buttons for one intention is two too many, and the glyph kept is `logout`, the door with the way out marked on it. Gather's `turnOffAVS()` is the one line not copied — on a desktop the walk is a keystroke, and on a phone a button that silently hangs up the call you are holding is a second action nobody asked for. It carries its own `ListenableBuilder` on `AppState.positions`, because walking is deliberately not a `notifyListeners` and this is the only control here whose answer changes as you walk. |
| `status_sheet.dart` | `showStatusSheet()` — Active / Busy / Away, and the line of text under your name. Both halves read back off the roster and are authoritative. The sheet listens to `AppState` and holds a tapped availability (`_asked`) until the roster agrees — it used to redraw only on a tap, so a new state lit up on the *second* one; the other half of that bug was `AppState._noteMine`, since the presence tracker never reports a change to your own row. The emoji is an inline row of plates (`_EmojiRow`), not a `PopupMenuButton`, which opened as a tall list over the field and the keyboard. The status line was an echo of what this phone last sent until `SpaceUserStatus` was tracked; the join runs from that row's own `spaceUserId`, because `SpaceUser.activeCustomStatusId` and `activeUserGeneratedStatusId` are never set on anybody. What comes back may be one **Gather** wrote from a calendar rather than one you typed. |
| `person_avatar.dart` | `PersonAvatar` — somebody's profile picture over a coloured initial, with an optional availability dot. The one shared widget in this directory, and the bar for adding another is that something is genuinely wanted twice: the control bar draws you, the activity tab draws whoever waved. The initial is drawn first and always, because roughly half a space has no picture (45 of 98 measured) — so a photo that is loading, expired or missing lands on a finished avatar instead of a hole. |
| `dpad.dart` | `DPad` — the pad that walks your own avatar, floating over the lower half of the map. **Currently shelved**: `kShowDPad` is `false`, so the map never mounts it — the pad, its walk plumbing and its tests all stay live, and bringing it back is flipping that one constant. Tapping a tile is what moves you now, and the two share one `Walk`: pressing a direction cancels a route in flight, so the pad coming back does not mean two things steering one avatar. One `Listener` rather than four buttons, so rolling a thumb from one quarter to the next changes direction without the walk ever stopping; the hub in the middle is how you stop without lifting. Each direction owns a full quarter of the disc, split on the same diagonals the hit test uses, so what you aim at is what you get. `../../packages/gather_client/lib/src/walk.dart` does the stepping. |
| `pair_screen.dart` | Camera pairing. `_Header`, `_Viewfinder`, `_CornersPainter`, `_CameraUnavailable`, `_Hint`, `_Command`. Opens the camera immediately and keeps the typed route available throughout. |
| `media_check_screen.dart` | `MediaCheckScreen` — mic, camera and sound, before you need them. Talks to no server; it opens the hardware, draws it and lets go. **Two modes behind a `SegmentedButton`, one framework at a time** (`_CheckMode`): switching unmounts the other child so the two never share the audio session. *Why the split:* on iOS `flutter_webrtc` forces the shared `AVAudioSession` into `videoChat` mode whenever it holds the camera, and `record` has to activate that same session for a live meter — run together they flap the voice-processing IO unit ~hundreds of times/sec and freeze the device (confirmed in device syslog: ~1100 `CategoryChange`, ~2000 VoiceProcessor start/stop in ~100s). An earlier single-screen version that also stood up a *connected* two-`RTCPeerConnection` loopback to fake a level made it worse. **`_DeviceCheck`** (`_DevicePreview`, `_CameraCover`) — the lightest path: the `camera` plugin for the preview, opened **`enableAudio: false`** so it never touches the audio session, and `record` for a live "we can hear you" light (raw PCM → `../src/media/mic_level.dart`'s `micLevel`, judged by the same `VoiceActivity` as the speaking ring). One owner of the camera, one of the audio session, nothing to fight; the camera never waits on the meter (`_startMeter` is best-effort, unawaited); the `CameraController` is dropped on `paused` and reopened on `resumed` because iOS reclaims the camera in the background. **`_MeetingCheck`** (`_MeetingPreview`) — the **pre-branch WebRTC check, restored**: a plain `_engine.startCapture()` with mic/camera/switch and real mute (`setAudioEnabled`), owning an `RTCVideoRenderer` (texture initialised before use, `srcObject` cleared before the engine stops the tracks under it). **No** `prepareAudioSession`, route toggle or test sound — forcing a route on this standalone capture (no SFU transport connected) drove the voice-processing reconfiguration loop that lagged the screen even with only WebRTC active; a real call tolerates the same calls because its transport is live. Mic shows a plain live/muted status, not a level — WebRTC gives no local level without a connection and the loopback that faked one is what froze the screen. Shared leaves: `_Message`, `_MicStatus` (one widget for both modes — device passes a `hearing` level, call-pipeline passes `null` for a plain live/muted line), `_Controls`, `_Toggle`, `_frame`, and `_previewCard` (the failure → starting → off → live ladder both previews walk, each mapping its state onto one `_CheckFailure`); three distinct failure states (starting, permission denied, no camera), because a refused permission is fixed in Settings and a busy camera is not, and neither is a spinner. The code-made chime (`../src/media/test_tone.dart`) is a **Device-mode-only** speaker test: it plays through `audioplayers` with `mixWithOthers` and applies the route per tap (`defaultToSpeaker`). Call mode has **no** test sound — audioplayers would have to reconfigure the `AVAudioSession` the engine owns, which revives the exact category thrash the split exists to kill, so `_Controls` hides the button (`onPlayTone: null`) and leaves the speaker test to Device mode. |
| `call_screen.dart` | `CallScreen` — the faces, everybody the SFU is sending plus your own camera. `CallTile`, `TileFrame`, `_Grid`, `_VideoTile`, `_Header`, `_Nobody`, `_Plate`, and the `tilesFor()` seam. Pushed through `openCallScreen()` — from `CallBanner`, which floats over the office under its app bar while `AppState.inCall`, or from the control bar's camera button outside a call. `CallBanner` is drawn from `tilesFor()` — the screen's own list — so the two cannot disagree: SFU participants first, then `AppState.huddleRows` not already shown, which covers both somebody not negotiated yet and somebody in the conversation with nothing published (who never becomes a participant). `callBannerText()` words it for any size of call, named or not. The banner is the dock's own `t.card` fill and `t.border` — a solid accent shouted over the office, and the selected tab's blue wash made it look selected — and sits 8 points off the app bar and off both sides alike. A tile with no stream gets no `RTCVideoRenderer`, and `_VideoTile.dispose` only detaches a renderer that finished initialising; setting `srcObject` before that throws. The screen carries the control row in a `DockIsland` but never the navigation. **A route rather than a panel on purpose**: an `RTCVideoRenderer` that is off-screen still decodes, so the surface should not exist when nobody is looking at it. One renderer per tile, keyed by person, attached in `initState`/`didUpdateWidget` and **never in `build`** — `srcObject` is a platform call with a side effect and `build` runs for reasons that have nothing to do with the stream. Layout is 1 full / 2 stacked / grid, because two portraits side by side on a phone are two slivers. `buildTile` is the test seam: `RTCVideoRenderer.initialize()` needs a `MethodChannel` that `flutter test` does not have. |
| `type_code_dialog.dart` | `showTypeCode()` — a modal sheet with two fields (code and address), plus `UpperCaseFormatter`. The route when the camera is refused, unavailable, or on desktop. |

## For AI Agents

### Working In This Directory

- **A control that cannot do anything is absent, not dimmed.** The conversation
  button appears when there is a conversation to leave and goes with it; the
  camera flip appears once there is a camera running, and only on the call
  screen, where your own picture is there to flip. This is the same rule the
  D-pad follows for its own visibility, and it is why almost nothing in the
  control bar is ever greyed out — a bar whose buttons keep changing which of
  them work is one you stop trusting.
  - **The desk is the one exception, and it is deliberate.** Being at your own
    desk is the answer to "where am I", it is the state a person opens the bar to
    check, and a button that has vanished cannot tell anybody they have arrived.
    So it is absent only when Gather has given you no desk at all, and dim when
    you are already sitting at it. Do not generalise this to anything else here.
- **Red is where you are, not what is off.** A muted microphone is *not* red: the
  `mic_off` glyph is already a microphone with a line through it, so the shape
  carries the state and painting it red as well spent the bar's one alarming
  colour on the most ordinary thing in a meeting. Off is the same grey every
  resting icon is, `t.brand` marks the two controls that are actually
  broadcasting, and `t.danger` is spent on the door, where it says the one thing
  no glyph can — there is somewhere you are not: in a conversation, or away from
  where the office has you filed. It is the bar's only red, wherever the bar is
  drawn; the desk walk and leaving the conversation used to be two red buttons,
  and folding them into one door settled which red the bar has. The D-pad's
  rule — pressed is a step of opacity, never a different paint — is about a
  control being *pushed* and still holds.
- **Nothing in the dock may have an opinion about its own width except the two
  permanent rows.** The dock is an `IntrinsicWidth`, so a row that measures itself
  moves the island — the reaction tray used to widen it by eight points on the way
  in and let it back down as a reaction was picked, under the thumb reaching for
  it. A transient row answers zero when asked (`_NoWidthOpinion`) and divides what
  it is handed (`Expanded`). Test this against `IntrinsicWidth` + `kRailMinWidth`
  directly and never through the whole shell: under the test font the navigation
  labels are wider than the tray and set the island themselves, so a shell-level
  assertion passes against the bug.
- **Every action answers.** Everything on the control bar and the status sheet
  returns `Future<String?>` — null on success, a sentence on failure — and the
  sentence goes to a `SnackBar`. That is the contract `AppState.setPartyMode`
  set. A tap that silently does nothing is the one outcome not allowed.

- **The history the activity tab shows is Gather's, never the phone's.** The
  app's own `EventLogStore` was deleted and must not come back: it could only
  record what happened while the app was open, which is the one window in which
  the user was already looking, so it was empty exactly when it mattered. That
  was an argument against a log *this app keeps*, not against a history — the
  list under the cards is read from Gather over REST and was there while the
  phone was asleep. `_SectionLabel`, `_EventRow`, `_EmptyFeed` and
  `_BackgroundToggle` are gone for good.
- **The activity tab is a record, not a status board.** The follower card and
  the party switch both started here and both left — party mode to settings,
  the follower answer to the office's app bar (`_Followers` in
  `map_screen.dart`) — because live presence pinned over a history is stale a
  minute later and in the way of the record. The link strip left last — its
  main occasion to appear was the pull-to-refresh reconnect, which is also
  gone. Do not grow cards back above the feed.
- `CustomScrollView` needs `AlwaysScrollableScrollPhysics` or the screen — now
  shorter than the viewport — cannot be over-scrolled, and pull-to-refresh
  silently does nothing.
- **`_PartyRow` (settings) renders the snapshot, never its own memory.** The
  bridge stops party mode by itself — on its 15-minute timer, when it loses
  Gather, when the daemon exits — so a switch holding local state would keep
  glowing through all three. `AppState.partyMode` reads the local party mode
  directly, so a tap is flight, and that override is cleared by the snapshot
  that agrees with it rather than by the HTTP response, because the two race.
  The spinning gradient card this used to be on the activity tab is gone —
  do not bring an animation to the settings screen with it.
- **The follower badge does not hedge, and does not say zero.** Follow state
  comes off the app's own Gather socket, so the badge is authoritative while
  the socket is up — there is no degraded tier left to admit to. It is absent
  when nobody follows rather than reading "0": zero is the permanent normal
  state, and a pill saying so all day is furniture. Same geometry as the head
  count beside it, tinted `brandSoft` at 0.12 fill / 0.3 border.
- `pair_screen.dart` opens the camera without asking first: the screen is only
  ever reached when there is a computer to pair with, so a confirmation tap sits
  in front of the only thing anyone came here for. The instruction goes *under*
  the frame — the person who already ran the command needs the viewfinder, the
  person who has not needs the sentence.
- The scanner is configured for `BarcodeFormat.qrCode` and
  `DetectionSpeed.noDuplicates` only, and `_claiming` gates the detector while a
  claim is in flight. A reader that reacts to every label in the room is noise.
- `mobile_scanner` is mobile-only. Any desktop target must fall back to
  `showTypeCode`, which is a first-class route, not a consolation.
- Colours come from `context.tokens` — never a literal `Color` and never
  `Theme.of(context).colorScheme` directly.
- **Labels are laid out on the glass, not on the map.** The type size is fixed and
  the canvas is scaled down to place it, rather than the size being computed against
  the zoom. Sized against the zoom, a name's `TextPainter` key changed on every frame
  of a pinch and the cache became a cache of one frame — a hundred people re-laid-out
  sixty times a second.
- **The map repaints off `Listenable.merge`, not off `setState`.** The art cache, the
  viewer transform and `MapMotion` all drive the painter directly; a footstep must not
  rebuild the widget tree. `MapMotion`'s ticker stops itself when nobody is moving or
  talking, so an office standing still costs no frames.
- **No arrow on the D-pad is ever greyed out.** An earlier version dimmed the
  directions that led into a wall, using the same rule that decides whether the step
  is sent. It read as a fault: the arrows flickered between live and dead as you
  walked past doorways, and a control that keeps changing which parts of it work is
  one you stop trusting. You find a wall the way you find one in any game — by
  walking into it and stopping.
- **The pad is only shown when it can actually drive something** (`AppState.canWalk`:
  a live collector *and* a tile to judge steps from). A pad that does nothing cannot
  be told apart from a broken one. `debugCanWalk` is the seam, since knowing where you
  are takes a real roster.
- **Pressed is a step of opacity, not a colour.** The brand blue was tried on the held
  quarter and made the pad look like it was reporting something rather than being
  pushed; a heavier dark read as a hole cut in the disc.
- **Selected is a colour, though.** That rule is about a control being *pushed*; a
  nav item is a control that is *in a state*, so `_NavItem` follows the media
  check's toggles instead and uses `t.brand` on a `t.secondary` plate. The plate is
  what stops three loose glyphs on a floating bar reading as decoration.
- **Tabs are kept alive, and that is a cost as well as the point.** Anything with a
  ticker or a subscription behind a tab keeps running unless something stops it —
  `TickerMode` covers clocks, but a new tab holding hardware or a stream must
  handle its own. `MediaCheckScreen` is pushed from settings rather than made a
  tab for exactly this reason: it opens the camera in `initState` and would hold
  it forever behind another tab.
- **A screen inside a tab does not add bottom padding of its own.** The shell has
  already put the rail's height into `MediaQuery.padding.bottom`, so
  `SafeArea(top: false)` or `MediaQuery.paddingOf(context).bottom` is the way to
  clear it. Hard-coding the rail's height in a second place is how the two drift.

### Testing Requirements

```sh
flutter test test/home_shell_test.dart test/activity_screen_test.dart \
             test/settings_screen_test.dart test/map_screen_test.dart test/dpad_test.dart
```

Widget tests drive real screens through `AppState`'s debug seams. Being followed
requires a colleague to actually follow you around a real space, so the follower
card would otherwise never be seen in development — that is why it is pinned by a
test.

Wrap screens in the real theme (`buildGatherTheme()`) in tests; the widgets read
`context.tokens` and will throw without it.

### Common Patterns

- `final t = context.tokens;` as the first line of `build`.
- Private `StatelessWidget`s over helper methods, so Flutter can rebuild them
  independently.
- Copy is written as sentences a person would say, and states limitations
  plainly rather than hiding them.

## Dependencies

### Internal

`../src/app_state.dart`, `../src/pairing.dart`,
`../src/link_status.dart`, `../theme/gather_theme.dart`,
`package:gather_events`.

### External

`mobile_scanner` (pair screen only), `flutter/material`, `flutter/services`.

<!-- MANUAL: -->

### Gameboy mode

**The Gameboy Select menu must always hold every destination the bottom tab bar
holds.** In `gameboy_shell.dart` the handheld replaces the tab bar while the
office is on screen, so its Select menu is the only way to reach the other tabs.
Whenever a tab is added to or removed from `_Tab` (`home_shell.dart`), add or
remove the matching `_menuRow*` row in the Select menu — the one exception is the
map itself, which *is* the office drawn under the shell and so needs no row. A new
tab with no menu row is unreachable in Gameboy mode.
