<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# test

## Purpose

Flutter tests for the app: the main screen as a widget, and one optional
end-to-end test against a real running bridge.

## Key Files

| File | Description |
|------|-------------|
| `map_screen_test.dart` | The map screen: that "no map yet" and "not connected" stay different sentences, that offline avatars are not drawn, and that the room you are standing in is named. |
| `activity_screen_test.dart` | The empty states of the history screen: that the first read shows bones rather than claiming "nothing yet", that the claim is made once a fetch has checked it, and that the one becomes the other by dissolving rather than cutting — pinned on the `SliverFadeTransition`'s own opacity, which is the only part of a cross-fade a test can actually see. The follower card, the party card and the link strip all lived here once and their tests left with them — followers to `map_screen_test.dart`, party to `settings_screen_test.dart`, the strip removed outright. |
| `home_shell_test.dart` | The tab shell — the only test that pumps anything above a single screen. That Activity opens first and **every destination shows its own body**, which is the one thing pinning rail order to `IndexedStack` order; then the three guarantees that made the shell worth writing carefully: the map's `State` survives a round trip (its art cache and pan/zoom live on it), a tab you are not looking at has its tickers muted, and the 4Hz position feed only reaches the map while the map is selected. |
| `activity_feed_screen_test.dart` | The history half of the activity tab. Mostly one thing: that the read-state split is honest — a meeting memo offers mark-all-read (the double-check icon) and a wave does not, because their read state lives in different places in Gather. Also that an unresolvable actor id still renders shortened, that days are grouped, and that a kind nobody has decoded yet is named rather than dropped. |
| `settings_screen_test.dart` | That the four connection states stay four different sentences — in particular that a revoked credential asks you to act rather than to wait — and that unpairing calls through exactly once. Also one case per `PushReach`, because that card used to render "is an address stored" under the word *Unreachable*: it called a sleeping Mac reachable forever and a phone with no bridge address unreachable, and the second one sends you to inspect a computer that is fine. |
| `push_test.dart` | Push registration, entirely about the *outcome*. Every failure here is silent by construction — the phone registers or does not, FCM answers `200` either way — so these pin that "APNs never answered", "the Mac is asleep", "the Mac has no credentials" and "no bridge address" stay four different answers, that the POST is re-attempted every call (it is the reachability probe), and that the FCM token is fetched once rather than waiting on APNs again per resume. |
| `bridge_settings_store_test.dart` | The keychain move and its migration. The migration is the risky half: shipping it without one would unpair every phone that is already paired, which is the same failure it exists to fix, caused deliberately. Also that the `installId` is minted once, and survives an unpair — it names the phone, not the relationship. |
| `sfu_session_test.dart` | The conversation with Gather's media plane: assignment, the node pool, reconciling `consume-try`, and the three things a device cannot be made to do on cue — a router that has not placed somebody yet, a socket that drops and comes back holding nothing, and a node being drained mid-call. The transport underneath is tested against a real socket in `packages/gather_client`; this is about what is *said*. |
| `live_call_test.dart` | The two buttons and the order they force. Driven through a real `SfuSession` over the same rig, so the assertions are about what reached the wire rather than about a mock being called. Two production bugs came out of writing it: turning the camera on dropped the audio producer and never put it back, and a refused `produce` hung the button for twenty seconds. |
| `call_cluster_test.dart` | When the app speaks to the media plane and when it stays quiet — the cluster becoming a subscription, the wider in-range set becoming the allow list, and the asymmetric debounce. `fakeAsync`, because it is entirely about *when*. |
| `call_screen_test.dart` | The video surface with no camera near it, plus the quality requests: one face full-screen asks for the top simulcast layer, a grid asks for thumbnails, and closing the route asks everybody to stop sending detail. |
| `debug_drive/` | The debug drive, in-process through the registry: name validation and all-or-nothing install, `args` parsing, the ok/refused/error mapping (error codes inside −32016..−32000, `FlutterError` reports), op ids/nonce/eviction, `state.dump` fields and **redaction** (boots on secret-shaped credentials), `log.tail` cursors, the outward gate matrix, and `enabled: false`. |
| `tool/drive_cli_test.dart` | The pure half of `tool/drive.dart`: argv grammar, URI-file choice (several device files without `-d` is a usage error, not a guess), the ws URI with its auth code kept, and the exit codes 0/1/2/64/69/75 a calling script switches on, including how a settled op maps onto them. |
| `tool/release_artifact_check_test.dart` | The release guard CI runs before TestFlight and the APKs, on fake binaries: clean with the control passes, `ext.gc.` fails, a missing control fails as proving nothing, a missing file fails, no arguments is 64. A broken grep there would only ever show up as a release that silently passes. |
| `live_bridge_test.dart` | End-to-end against a real bridge, exercising the app's own pairing and client code rather than mocks. **Skipped unless configured**, so `flutter test` stays green on a machine with no Gather on it. |

## For AI Agents

### Working In This Directory

- **Use the debug seams, not fakes.** `AppState.debugApplySnapshot`,
  `debugApplyEvent` and `debugApplyLink` are `@visibleForTesting` for exactly this
  reason — the tests drive the real state object.
- **The media fakes stand in for hardware only, never for our own code.**
  `fake_signalling.dart` (the socket), `fake_mediasoup.dart` (`Device`,
  `Transport`, `Producer`, `Consumer`) and `fake_capture_engine.dart` (the
  camera) are the whole set, wired together by `sfu_rig.dart`. `SfuSession` and
  `LiveCall` themselves are the real thing in both suites — a fake of either
  would test the fake. The mediasoup ones use `implements` plus `noSuchMethod`
  rather than reimplementation, so the members we *do* override are checked
  against the real signatures and a library upgrade breaks here rather than on a
  device.
- **Two seams exist purely so that works**, and both are the same shape as
  `MediaEngine`: `SfuSession(buildDevice:)` injects the mediasoup device, which
  is the only part of that file needing a platform channel, and `CaptureEngine`
  is the narrow interface carrying `MediaStream` so `LiveCall` does not have to
  name `WebrtcMediaEngine`. Keep new native calls behind one of them.
- **Being followed cannot be produced on demand.** It needs a colleague to
  actually follow you around a real space, so without these tests the follower
  card would only ever be seen by accident. That is why it is pinned here.
- Screens must be wrapped in `buildGatherTheme()`; they read `context.tokens` and
  throw without it.
- Test names are sentences stating the guarantee ("an unreachable link says so,
  but not straight away"). Keep that style — they are the readable
  index of what the UI promises.
- **`IndexedStack` keeps the other tabs in the element tree**, so a default
  finder will not see them but `skipOffstage: false` will. That difference is the
  assertion, not an inconvenience: `findsNothing` with the default and
  `findsOneWidget` without it is what "kept but not shown" looks like from a test.
- **State identity is the honest way to test that a tab was preserved.** Comparing
  `tester.state(...)` before and after a round trip catches a rebuild that a text
  finder cannot see, because a fresh `MapScreen` renders identically to the one
  that kept its art cache.

### Running the live test

```sh
node bridge/bin/gather-bridge.js run --port 7830 --token t --log-file /tmp/f.log &
node bridge/bin/gather-bridge.js pair --port 7830   # note the code
GATHER_TEST_PORT=7830 GATHER_TEST_CODE=XXXXXXXX flutter test test/live_bridge_test.dart
```

Without all three environment variables the test skips itself. CI does not run
it.

### Testing Requirements

```sh
flutter analyze && flutter test
```

Both are the release gate — the npm and TestFlight jobs are blocked on them. The
bridge has its own separate suite; see `../bridge/test/AGENTS.md`.

### Common Patterns

- Fixture builders at the top (`snapshotWith`, `stateWith`, a fixed
  `DateTime(2026, 8, 4, 12, 30)`), assertions below.
- `group()` by concern, `testWidgets` for screens, plain `test` for pure logic.
- No mocking package.

## Dependencies

### Internal

`package:gather_companion/...` (the app's own libraries) and
`package:gather_events`. `live_bridge_test.dart` additionally needs the Node
bridge running.

### External

`flutter_test`.

<!-- MANUAL: -->
