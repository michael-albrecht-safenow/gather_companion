# Debug drive: research and implementation plan (2026-11-10)

**Status:** plan only. Nothing here is built yet. Tracking epic: #102. Research findings are marked
*sourced* (read in docs or source), *verified* (observed on this repo), or
*to confirm* (expected, checked in Phase 0).

## Why

Today an agent checks this app in one of two ways:

- **On the simulator:** the `idb describe-all → tap → screenshot` loop
  (`docs/sim_harness.md`, `docs/sim_test_plan.md`). Every check pays for the
  whole navigation path, coordinate taps break when the layout changes, and
  "is the spotlight on Bob" gets answered by looking at pixels.
- **On a device:** a person taps, then `devicectl copy` pulls `media.log`,
  and somebody reads it afterwards. Most call bugs so far (consume-not-allowed,
  a stale peerNode, send transport stalls, audio-only deafness) were found
  from a log, after a real call had already gone wrong.

The debug drive gives the app a **JSON API into its running business logic**
in debug builds, over the VM service channel that `flutter run` already
opens. An agent or a script can then say "warp to the test peer, wait for the
call, and confirm that audio and video from them keep arriving for 30 s". The
answer comes back as numbers and a verdict, with no screenshot and no human.

**The media half is the reason this pays off here.** A video call's wiring
(who is subscribed, which consumer feeds which tile, whether RTP actually
arrives) can't be checked from a screenshot. A black tile and a frozen tile
look the same as a slow one. WebRTC `getStats()` can check it: if bytes,
packets, decoded frames and audio energy keep rising for every expected peer
and track, the wiring is right.

## Research: the mechanism

### Transport: Dart VM service extensions (no new dependency in the app)

- `dart:developer` `registerExtension('ext.gc.<feature>.<action>', handler)`
  ships with the SDK. *Sourced.*
- Params arrive as `Map<String,String>`, so nested input goes JSON-encoded
  into one `args` param. `ServiceExtensionResponse.result()` takes a JSON
  object encoded as a string. `error()` accepts only `invalidParams`
  (−32602) or a code from −32016 to −32000; anything else throws. *Sourced.*
- Extensions are registered per isolate. After a hot restart the isolate id
  changes, so clients look it up again (`getVM`). *Sourced.*
- `flutter run --machine` forwards any `ext.*` call via
  `app.callServiceExtension`. `package:vm_service` can call it directly with
  the DDS URI (auth code included) plus an `isolateId`, which is required:
  without it the call fails as `-32601 Unknown method`, which is misleading.
  *Sourced; to confirm on Flutter 3.44.5.*
- URI discovery: `flutter run --vmservice-out-file=<file>` writes the URI.
  Prefer it over `flutter attach`, whose mDNS discovery is broken on the
  simulator on macOS 15.4+ (flutter/flutter#166333). *Sourced.*
- Physical iPhone: the VM service exists only while a debug app runs under
  `flutter run`/`attach`. iOS blocks JIT otherwise, so profile and
  TestFlight builds can't get the drive. That is intended. *Sourced.*

### Agent bridge: `dart_mcp_server` (no MCP code of our own)

- The Dart team's `dart mcp-server` ships with the SDK and exposes `dtd` and
  `vm_service callMethod`, which pass any method name through. *Sourced.*
- Agent sequence: `dtd listDtdUris` → `dtd connect` (pick the DTD whose
  Workspace Root is this repo, since stale DTDs from old runs show up too)
  → `vm_service callMethod getVM` (read the isolate id) → `vm_service
  callMethod ext.gc.*` with `arguments: {"args": "<json string>"}`.
  Every param must be a JSON **string**; a raw object arrives as Dart
  `toString()` text. *Sourced; to confirm in Phase 0.*
- Register it with `claude mcp add` using the absolute `dart` path, because
  the asdf shim fails outside the repo.
- Considered and not chosen for business logic: Marionette (UI driving,
  pre-1.0, forces an `ext.flutter.` prefix), Maestro and Patrol (UI flows
  and native dialogs, can't call Dart), `flutter_driver` `requestData`
  (maintenance mode), an in-app HTTP debug server (no auth by default,
  LAN-exposed, must be compiled out by hand). Any of these can still cover
  the *UI* layer later.

### Release safety

- Only a **compile-time constant** guard removes the handlers from release
  builds: `if (kDebugMode) installDebugDrive(...)`. With a constant guard the
  AOT compiler strips the extension names, the handler bodies and the
  classes they pull in. A handler behind a runtime bool ships in release.
  *Sourced; checked on this app in Phase 0.2.*
- So a CI check greps the release binaries: `LC_ALL=C grep -aq 'ext\.gc\.'`
  must not match `App.framework/App` (iOS) or `libapp.so` (Android). A known
  release string must match (the control), or the check proves nothing.
  `publish.yml` already builds both, so both halves can gate the release.

### Security posture

- VM service auth codes stay on. Never pass `--disable-service-auth-codes`
  or `--disable-service-origin-check`.
- **iOS over Wi-Fi exposes the VM service on the LAN.** For a wireless
  device, flutter_tools binds the service on `0.0.0.0`, and the debug app
  publishes the auth code over Bonjour (`_dartVmService._tcp` TXT record).
  Anyone on the same network can then use the full VM service, `evaluate`
  included. Over USB it binds device loopback. *Sourced.* So: **USB by
  default**, Wi-Fi only on a trusted network (personal hotspot), and quit
  the app when done, because detaching `flutter run` leaves the service open.
- Readouts redact tokens and credentials.

### Where the logic already lives

- `AppState` (`lib/src/app_state.dart`) is a single `ChangeNotifier` that
  holds almost every action: `goTo`, `warpToPerson`, `warpToMeeting`,
  `goToRoom`, `goToMyDesk`, `setMicOn`, `setCameraOn`, `setHandRaised`,
  `setAvailability`, `sendEmote`, `addMeeting`, `reconnect`, and so on.
  *Verified.* Most handlers are thin wrappers, with no extraction needed.
- There is one `AppState` for the app's lifetime; the `Call` is per call and
  is reached through `AppState.callHandle` at call time. No late-binding slot
  is needed for v1.
- The harness (`lib/main_harness.dart`, `TARGET=app`) runs the real
  `AppState` against `FakeCollector` + `ScriptedCall`. That makes it the
  natural headless target on the simulator. Handlers register in both
  entrypoints, and `state.dump` reports `boot: "harness" | "live"`, so a
  scripted result is never mistaken for the live wire.
- Fault levers already exist: `SfuSession.debugSilentMove` (#67 class),
  `AppState.debugNoteConnectivity`, `debugNoteCollectorStatus`. *Verified.*
- Logic still in widgets (audit of timers/async in `lib/ui/`): the spotlight
  dwell timer in `CallScreen` State (`call_screen.dart:224`), the check
  sequence in `media_check_screen.dart`, and some of `calendar_screen.dart`.
  Phase 4.

### Media stats, what's available

- `mediasfu_mediasoup_client` `Consumer.getStats()` and `Producer.getStats()`
  exist (`third_party/mediasfu_mediasoup_client/lib/src/consumer.dart:153`).
  The app already reads producer stats for the mic level
  (`sfu_session.dart:996`) and an outbound report (`:960`). *Verified.*
- **Row attribution trap** (`sfu_session.dart` `_reportOutboundRtp`): a
  producer's `getStats()` returns rows for the whole peer connection. A
  silent mic once looked healthy (2026-09-17) because the number being read
  was the camera's. Filter by `kind` + `trackIdentifier`/`mid`/`ssrc`, and
  never attribute `candidate-pair`/`transport` bytes to one track.
- `RTCVideoRenderer` has `onFirstFrameRendered`, `videoWidth`/`videoHeight`
  (`third_party/flutter_webrtc/lib/src/native/rtc_video_renderer_impl.dart`).
  *Verified.* That is enough to check the render side of the wiring.

## Design

```
agent (dart_mcp_server) / tool/drive.sh / integration_test
   │  VM service (DDS, auth-coded URI, USB loopback by default)
   ▼
app isolate ── ext.gc.* ──► DebugDrive registry (lib/src/debug_drive/)
                               │
          ┌────────────────────┼─────────────────────────┐
          ▼                    ▼                         ▼
      AppState            Call (LiveCall)          harness levers
   (presence, walk,     └► SfuSession              (FakeCollector,
    status, plans)          └► getStats on          ScriptedCall,
                               producers/consumers  main_harness only)
```

- **One handler = one existing public method**, or a new read-only readout.
  No second code path. A handler that has to reach into a widget is the
  signal that logic is in the wrong layer, so extract it (Phase 4).
- **Registry:** validates every name of an install first (lowerCamelCase
  segments), rejects duplicates (`registerExtension` throws on one), and
  registers nothing on a partial set, because a partial channel looks like a
  missing feature. `drive.list` returns every action, so an agent asks what
  this build exposes instead of guessing.
- **Long operations use start/poll:** a walk, a warp that waits for the
  call, a 30 s media watch. The action returns an op id
  `<kind>-<n>-<nonce>`; `op.status` / `op.result` poll it. The nonce is drawn
  once per isolate, so after a hot restart an old id is answered as "from
  another isolate" rather than with a new op's result. 32 ops retained,
  oldest finished evicted first. An op failure is recorded and reported via
  `FlutterError.reportError` even when nobody polls.
- **Results:** `{ok:true,data}`; bad input → `invalidParams`; failure →
  `extensionError` with `{error,type}` plus `FlutterError.reportError`.
  An expected refusal (no call, not in a space, room locked) is a successful
  `{ok:false, reason}` and not an RPC error, so an agent can tell "the app
  said no" from "the drive broke".
- **Readouts carry their context** (the repo's honesty rule). An empty media
  snapshot always says *why* it is empty: `no_call`, `not_subscribed`,
  `consumer_missing`, `paused`, `not_measured`. It never returns just `[]`.

### Test space and outward actions

Waves, emotes, status changes, warps, entering a room and party mode are seen
by everyone in the space. So:

- **Live drive runs in a dedicated test space** with dedicated test
  accounts (one for the phone under test, one or more for the second
  endpoint). Nobody else is in it. That is the default for Phase 3 and for
  every agent run against `boot: "live"`.
- Actions with visible effects are flagged `outward` in `drive.list`.
  `state.dump` reports the current `spaceId`, and the drive knows the test
  space id from a build define (`--dart-define=DRIVE_TEST_SPACE=<id>`).
  An outward action in any other space returns
  `{ok:false, reason:"outward_outside_test_space"}` unless the call passes
  `{"confirm":true}`. The agent rule in `AGENTS.md`: only pass `confirm`
  after the user has said yes in this session.
- Entering is not free: `numTimesEnteredSpace` increments per entering
  connection on the account's profile (root `AGENTS.md`). On test accounts
  that does not matter. Loops that rebuild or reconnect (`call.rebuild`,
  `fault.*`) are documented as such anyway.

### Media flow probe (the main payoff)

Each sample reads `getStats()` per **consumer** (inbound, one per peer × tag)
and per **producer** (outbound), and keeps only that track's rows.

| Direction | Row | Fields | Means |
|---|---|---|---|
| inbound audio | `inbound-rtp` kind=audio | `packetsReceived`, `bytesReceived`, `packetsLost`, `jitter`, `totalAudioEnergy`, `concealedSamples`/`totalSamplesReceived` | RTP arrives; there is sound in it; how much playout is concealment |
| inbound video | `inbound-rtp` kind=video | `bytesReceived`, `framesReceived`, `framesDecoded`, `framesDropped`, `frameWidth/Height`, `framesPerSecond`, `freezeCount`, `totalFreezesDuration` | Frames arrive *and* decode, at what size and rate |
| outbound audio | `media-source` kind=audio + `outbound-rtp` | `audioLevel`, `totalAudioEnergy`, `packetsSent`, `bytesSent` | The mic hears something; the sender sends |
| outbound video | `outbound-rtp` kind=video | `framesEncoded`, `bytesSent`, `qualityLimitationReason`, `frameWidth/Height` | The camera encodes and sends |
| transport | `candidate-pair` (selected), `transport` | `state`, `currentRoundTripTime`, `bytesReceived` | ICE/DTLS alive. Per peer connection only, never per track |

**Verdict per stream, from deltas between samples:**

| Verdict | Rule (per interval) |
|---|---|
| `flowing` | packets/bytes rise; video: `framesDecoded` rises; audio: energy rises |
| `silent` | audio packets rise but `totalAudioEnergy` is flat: the peer sends silence (muted at the device or a quiet room). Opus DTX makes this normal, so it is **not** a failure on its own |
| `stalled` | the consumer exists and is not paused, but counters are flat for ≥ N s (default 2 s) |
| `paused` | consumer or producer paused (wire mute), counters flat as expected |
| `missing` | the peer is in the conversation (`listeningTo`/`watching`) and has a producer for the tag, but there is no consumer |
| `not_measured` | `getStats` threw or timed out. Never folded into `stalled` |

A **watch** (`media.watch {durationMs, intervalMs, maxGapMs, peers?}`) is an
op. Its result is the timeline plus a summary per stream: `continuous` (no
gap longer than `maxGapMs`), `gaps: [{from,to}]`, the longest gap, average
bitrate/fps, and loss %. "Is the call healthy for 30 s" then becomes a single
assertion: every expected stream is `continuous`.

**Render-side wiring check.** Decoded frames prove the SFU → decoder path,
not that the *right tile* shows them. A debug-only `RenderRegistry` takes a
report from each `_VideoTile` (`call_screen.dart`): which `srcId|tag` its
`RTCVideoRenderer.srcObject` is bound to, `videoWidth/Height`, and
`onFirstFrameRendered`. `media.render` returns the tiles. The probe then
cross-checks them: every stream that is `flowing` and wanted on screen has
exactly one tile bound to it and that tile has rendered a frame. A tile
bound to the wrong `srcId` or one that never rendered is a wiring bug,
caught without a screenshot. The registry is written only inside
`if (kDebugMode)`, so release strips it.

**Harness and tests.** `Call` gains `Future<MediaFlowSample> sampleFlow()`.
`LiveCall` implements it via `SfuSession`; `ScriptedCall` and
`test/fake_call.dart` return scripted samples, so the handlers and verdict
logic are unit-tested without WebRTC. Harness results are marked
`source: "scripted"`. The real proof needs two real endpoints in the test
space (Phase 3).

**Reuse for field diagnosis.** The same sampler can write a 5 s summary line
per stream into `media.log` while in a call. Known issue classes then map to
verdicts: consume-not-allowed / stale peerNode → `missing`; a dead SFU node
→ `stalled` with transport alive; a send stall → outbound `stalled` after
produce-ack.

### Feature set (handlers)

Namespace `ext.gc.<feature>.<action>`. **(O)** = outward.

| Feature | Actions | Calls |
|---|---|---|
| `drive` | `list` (actions + `outward` flag + boot mode) | registry |
| `op` | `status`, `result` | `DriveOps` |
| `state` | `dump`: phase, `isConfigured`, `link`, collector status, me (id, tile, room), space id/name, test-space flag, roster size, call summary, settings, `boot` | `AppState` getters (tokens redacted) |
| `log` | `tail {since}`: media.log lines after a cursor | `media_log.dart` |
| `presence` | `roster`, `followers`, `directory`, `map.people` | `AppState.peopleOnMap`, `directory`, `followers` |
| `move` | `goTo {x,y}` (op, settles on arrival or refusal), `warpToTile`, `warpToPerson {name\|id}` (O), `goToRoom` (O), `goToMyDesk`, `stop` | `AppState.goTo`, `warpTo*`, `goToRoom`, `goToMyDesk`, `stopWalking` |
| `call` | `state`, `setMic`, `setCamera`, `setScreen`, `setSpeaker`, `switchCamera`, `leave` (O), `rebuild`, `pullSessionOver`, `spotlight` (after 4.1) | `AppState.setMicOn` …, `leaveHuddle`, `callHandle.rebuild` |
| `media` | `snapshot`, `watch` (op), `render` | `Call.sampleFlow`, `RenderRegistry` |
| `sfu` | `debug`: node, peerNode cache, transports (ICE/DTLS state), consumers (paused, producerId), pending consumes | read-only `SfuSession.debugSnapshot()` (new) |
| `fault` | `silentMove {addr}`, `offline {on}`, `collectorStatus {…}` | `SfuSession.debugSilentMove`, `AppState.debugNoteConnectivity`, `debugNoteCollectorStatus` |
| `status` | `setAvailability` (O), `setCustom` (O), `clearCustom` (O), `emote` (O), `hand {raised}` (O) | `AppState` |
| `activity` | `list`, `refresh`, `markRead` | `AppState.activity`, `refreshActivity` |
| `plans` | `list`, `add`, `update`, `delete`, `google.status` | `AppState.plannedMeetings` … |
| `ui` | `gameboy {on,theme}`, `sfx {on}`, `party {on}` (O) | `AppState.setGameboyMode` … |
| `harness` | `placePerson`, `stepPerson`, `wave`, `call.emit`, `call.speak`, `scenario {name}` (**main_harness only**) | `FakeCollector`, `ScriptedCall`, `AppScenarioDriver` |

`harness.*` lets an agent script a scene instead of waiting for the timed
scenarios. For example: "seat Bob 2 tiles away → expect the call to form →
`harness.call.speak bob` → `call.spotlight` reports Bob".

## Phases and tasks

Estimates are judgement, not measured.

### Phase 0: confirm on this repo (≈ 0.5 d) — #103

- **0.1** Echo spike on Flutter 3.44.5: `ext.gc.spike.echo` on the simulator
  harness and on the iPhone over USB, through `dart_mcp_server` and a bare
  `vm_service` script. Confirm string-only params, `isolateId` required,
  the isolate change on hot restart, and a ~1 MB payload. Throwaway
  worktree, not merged.
- **0.2** Tree-shake check on this app: `flutter build ios --release
  --no-codesign` and `flutter build apk --release` with a const-guarded
  handler and an unguarded control. Grep `App.framework/App` and
  `libapp.so`.
- **0.3** Set up the test space and test accounts (needs the user: Gather
  admin rights to create a space, and a mailbox for each test account's
  email OTP). Record the space id for `DRIVE_TEST_SPACE`.

### Phase 1: registry, tooling, guard (≈ 1.5 d) — #104

- **1.1** `lib/src/debug_drive/`: `DebugDrive` registry, `DriveResult`
  (`ok` / `refused` / error mapping), `DriveOps` (32, nonce'd ids),
  `drive.list`, `op.*`.
- **1.2** `installDebugDrive({required bool enabled, required AppState app,
  HarnessLevers? harness})`, called from `main.dart` **and**
  `main_harness.dart` inside `if (kDebugMode)`. A unit test covers
  `enabled: false`, since `kDebugMode` is always true under `flutter test`.
- **1.3** `state.dump` + `log.tail` + handler tests through the registry
  (plain `flutter test`, using the existing `debugApply*` seams).
- **1.4** `outward` metadata + the test-space gate (`DRIVE_TEST_SPACE`,
  `outward_outside_test_space`, `confirm`) + the agent rule in `AGENTS.md`.
- **1.5** `tool/drive.sh` / `tool/drive.dart`: one short-lived `vm_service`
  call per command, URI from `.dart_tool/vm_uri.<device>` (written by
  `flutter run --vmservice-out-file`), `getVM` on every call, `--wait` op
  polling, sysexits-style exit codes. Add `vm_service` as a dev_dependency
  (already in `pubspec.lock` transitively).
- **1.6** Release guard: `tool/release_artifact_check.sh` (`ext.gc.` absent +
  control string present) in `publish.yml`, after the iOS export and after
  `flutter build apk`.
- **1.7** Docs: a "Driving features headless" section in
  `docs/sim_harness.md` (dart_mcp_server registration, the 4-call sequence,
  params as JSON strings, re-read the isolate after a hot restart, USB by
  default), pointer in root `AGENTS.md`.

### Phase 2: media flow probe (≈ 2–3 d) — #105

- **2.1** `MediaFlowSample` model + `Call.sampleFlow()` on the interface;
  scripted implementations in `ScriptedCall` and `test/fake_call.dart`.
- **2.2** `SfuSession.flowStats()`: `getStats` per consumer and producer,
  rows attributed by track/ssrc/mid, a timeout per call, `not_measured` on
  failure. **Unit test with a mixed-PC stats fixture** (camera bytes must
  not count as mic bytes).
- **2.3** `FlowVerdict`: pure Dart over two samples plus the expected-stream
  set (from `listeningTo`, `watching` and the peer's announced producers).
  Table tests for every verdict, including DTX silence.
- **2.4** `media.snapshot`, `media.watch` (op), and the summary
  (`continuous`, gaps, averages). Default interval 1 s, with a
  `_sampling`-style reentrancy guard like the voice poll's.
- **2.5** `RenderRegistry` + `media.render` + the flowing-but-unrendered and
  wrong-binding cross-check. Widget test with `debugCallTileBuilder`.
- **2.6** `sfu.debug` read-only snapshot.
- **2.7** Optional: a periodic flow summary into `media.log` while in a call.

### Phase 3: two-endpoint verification in the test space (≈ 1 d) — #106

The second endpoint is still to be decided; see *Open question* below.

- **3.1** Phone over USB + second endpoint, both in the test space.
  `move.warpToPerson` → `op.result` → `media.watch 30s` → every expected
  stream `continuous`. Save the raw JSON as evidence, and say which verdicts
  were observed live and which were scripted.
- **3.2** Negative checks: the peer mutes (expect `paused`/`silent`, not
  `stalled`); the peer turns its camera off (the video stream leaves the
  expected set); `fault.offline` → `stalled`, then recovery;
  `fault.silentMove` → outbound `stalled`, then the send-heal recovery
  (#67).
- **3.3** Record what was verified, where, and what is still inferred in
  `docs/sim_harness.md` → *Verified so far*.

### Phase 4: move the remaining widget logic down (≈ 1–2 d) — #107

- **4.1** Spotlight dwell: move `_dwellTimer` out of `CallScreen` State into
  a `SpotlightController` next to `SpotlightDirector`, so `call.spotlight`
  (`{mode, target, since}`) is readable, and `docs/sim_test_plan.md` C1–C7
  become drive assertions instead of screenshots.
- **4.2** `media_check_screen.dart`: extract a `MediaCheckController` that
  owns the check sequence and readouts; the widget keeps only the renderers
  and their lifetimes. Then add `mediaCheck.*`.
- **4.3** Look at `calendar_screen.dart` (11 private async functions) and the
  `gameboy_shell.dart` button mapping, and move what is a decision rather
  than presentation. Toast and tap-window timers in `map_screen` and
  `gameboy_shell` are presentation and stay.

### Phase 5: retrofit the remaining features (≈ 1–3 h each) — #108

`presence`, `move`, `status`, `activity`, `plans`, `ui`, `harness.*`, one PR
per feature with handler tests. Then add the rule to `AGENTS.md`: **a PR that
adds or changes a feature ships its drive action and a handler test.**

### Phase 6: convert the simulator test plan — #109

Rewrite the `docs/sim_test_plan.md` rows as drive scripts (`tool/drive.sh`
or an `integration_test` that calls the handlers in-process). Keep `idb` +
screenshots for what is visual by nature: layout, the Gameboy skin, and
comparing against design mocks.

## Open question: can a simulator be the second endpoint?

If an iOS simulator can run the real app and join a call as an audio-only
participant (Mac microphone, no camera), Phase 3 runs unattended
(phone ↔ simulator) with no second person. Investigation in progress; the
findings go in here.

## Risks

- **The session must stay open on a physical iPhone.** No drive outside
  `flutter run`/`attach` in debug, by design.
- **iOS over Wi-Fi is LAN-exposed** (see *Security posture*). A call test
  often runs on Wi-Fi anyway, so use a trusted network only.
- **`getStats` cost.** Each call crosses the platform channel, and the
  voice poll already runs at 200 ms. Keep `media.watch` at ≥ 1 s.
- **Debug builds are slower** (the interpreter on device). Give timing
  verdicts (`maxGapMs`) headroom, and don't ship debug-tuned numbers as
  product thresholds.
- **Per-feature maintenance.** Every new or changed feature needs a handler
  and a handler test. That is a deliberate cost.
