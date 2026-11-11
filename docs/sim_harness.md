# Simulator mock harness — the whole app, on a bare simulator

**This is the harness to use for driving Gather Companion on the iOS simulator** —
for a human eyeballing a change or an autonomous agent (`idb` + screenshots). It is
a `flutter run` target that boots straight into a **scripted scene** with **no
login, no WebRTC, no camera, no Gather backend** behind it. Nothing reaches the
network and nothing touches real simulator state.

By default it is the **whole app**, so there is one place to test everything rather
than a call-only stub wired halfway. Two targets, chosen with `--dart-define=TARGET`:

- **`app`** (default) — the *whole app*: it boots the real pair→home flow into
  `HomeShell` with a `FakeCollector` standing in for the Gather socket, so the
  **Office is walkable**, people **mill about and talk**, the **Activity feed
  fills**, **Dial warps into a real call**, **Gameboy mode** opens, and the call's
  **door walks your character back to its desk** and into the office — all with no
  network. Tap a tile to walk; `idb`-drive it like any other screen.
- **`call`** — a quick shortcut that boots **straight into the call screen** on a
  scripted multi-party call, for a fast spotlight-only look without walking there.

**The simulator has no camera**, so a real WebRTC stream cannot exist. Both targets
paint **stand-in footage** into the call tiles instead (`lib/harness/demo_footage.dart`):
a moving test card per person — a mix of camera aspects (16:9, 9:16, 4:3, 1:1) so
the layout is seen cropping real shapes, with a **double-tap** (or the **Fit/Fill**
button on the big tile) to toggle cover↔letterbox and pinch-to-zoom. It is wired in
through the `debugCallTileBuilder` seam (`call_screen.dart`), which every
`openCallScreen` reads; it is null in production, where the real `_VideoTile`
renders real streams.

It is the gather equivalent of `beacon_manager`'s `example/lib/main.dart` harness.

## What it is

| File | Role |
|------|------|
| `lib/main_harness.dart` | Entrypoint. `TARGET=app` (default) injects the fakes, `boot()`s, and mounts the real phase switch (booting→pairing→home); `TARGET=call` mounts `CallScreen` directly. Sets `debugCallTileBuilder` so both targets get stand-in footage. |
| `lib/harness/demo_footage.dart` | `demoFootageTile` + `DemoFootage` — the stand-in "video": a moving test card fit to cover a tile, with a Fit/Fill toggle and pinch-zoom, since the simulator has no camera. |
| `lib/harness/scripted_call.dart` | `ScriptedCall implements Call` — a drivable fake: `emit(CallState)` and `speak(bool)`, every hardware/SFU method a recorded no-op. |
| `lib/harness/fake_collector.dart` | `FakeCollector implements Collector` — the presence-plane fake. Holds a mutable roster; `move`/`teleport` advance my tile and **re-emit `rosters`** (the server's half of a step), so the real `Walk`/`PartyMode` drive my avatar against it. `placePerson`/`stepPerson`/`publish`/`wave` are the scenario's levers. |
| `lib/harness/harness_data.dart` | The fake cast, the call roster builders (`CallParticipant.srcId == RosterRow.userAccountId`, one `clusterId`), **and** the schematic office — `schematicOffice()` (plain grid, a few rooms, no sprite art) with start tiles and map-plane row builders. |
| `lib/harness/call_scenarios.dart` | `scenarioFrame()` + `CallScenarioDriver` (call); `AppScenarioDriver` (app: mills the cast about and lands waves). |
| `test/harness/*_test.dart` | Unit tests for the scenarios, the driver and the fake collector. |

The harness entrypoint and fakes are separate files, but they ride production seams,
one of which this change adds: the `Collector` interface in `gather_client`, with
`AppState`, `Walk`, `PartyMode` and `DirectCollector` routed through it. The call
path also rides `AppState`'s `@visibleForTesting` seams; the app path rides the
`buildCollector`/`buildCall`/`buildActivityFeed` constructor seams plus in-memory
credential and bridge stores, so nothing reads, writes or clears real simulator
state and no fetch reaches Gather. Tiles and avatars are drawn, never streamed — no
texture, no sprite art is fetched.

## Running it

```sh
# list booted simulators
xcrun simctl list devices booted

# the whole app (default) — boots into the Office, walkable, feed alive, Dial
# warps into a real call, Gameboy mode opens, the call door walks you to your desk
flutter run -t lib/main_harness.dart -d <sim-udid>

# …or pick a scenario / cast size explicitly
flutter run -t lib/main_harness.dart -d <sim-udid> \
  --dart-define=SCENARIO=office --dart-define=PARTICIPANTS=4

# the call screen only (quick spotlight look, no walking there)
flutter run -t lib/main_harness.dart -d <sim-udid> \
  --dart-define=TARGET=call --dart-define=SCENARIO=roundrobin --dart-define=PARTICIPANTS=4
```

- `TARGET` — `app` (default) or `call`.
- `SCENARIO` — a call scenario or an app scenario name (see below).
- `PARTICIPANTS` — how many of the cast to seat, 1–8 (default `4`).

The `app` target needs no `GATHER_PAIR`: a credential-store stub reports "paired"
so `boot()` reaches `HomeShell`. Nothing on the credential is used — no fetch runs.

### Call scenarios (`TARGET=call`)

| `SCENARIO` | What it exercises |
|------------|-------------------|
| `solo` | Just me. Spotlight has nobody to follow — the empty baseline. |
| `pair` | Me + 1, talking in 2.5s bursts. |
| `group` | N people, nobody talking. Manual-mode grid at rest. |
| `roundrobin` | Each person holds the floor 3s in turn. **Auto mode should follow, one promotion per turn, no jump.** |
| `debate` | Two speakers: one holds, the other talks over without stealing (sticky), then the first stops and the second earns it. |
| `briefnoise` | Blips shorter than the 1.5s dwell. **Auto mode must stay on the overview** — the cough / chair-scrape rejection test. |
| `churn` | People join and leave mid-call. Tiles and the strip track it; the spotlight target survives or re-floors. |

The dwell the auto spotlight gates on is **1.5s** (`SpotlightDirector.dwell`);
scenario timings are chosen around it.

> **Spotlight note.** The big-view auto mode lives on `feature/call-spotlight`
> (worktree `../gather_companion-spotlight`). The harness files only use public
> seams, so they build on any branch — but to *exercise spotlight* run from that
> branch. On launch the screen opens in **Manual**; tap the header toggle to
> **Auto** to see the scenario drive the big view.

### App scenarios (`TARGET=app`)

| `SCENARIO` | What it exercises |
|------------|-------------------|
| `office` | People drift around the floor; somebody waves every few seconds. The Office is alive and the Activity tab fills. |
| `still` | Nobody moves. The resting floor — one frame to look at. |

What to check on the `app` target:

- **Activity** opens first: seeded history plus live waves arriving every ~5s, with
  an unread badge.
- **Office**: tap it in the rail. The schematic floor draws with ghost avatars —
  "You" and the seated cast, who mill about. **Tap an empty tile → "Go here" → your
  avatar walks there** (the real `Walk` stepping against `FakeCollector`, which
  echoes each step back on the roster). The call control bar sits above the rail.
- **The call**, from either door: **Warp** someone on the Dial tab, or walk within
  `FakeCollector.kCallRange` (3) tiles of a colleague in the Office. Either forms a
  cluster, and `AppScenarioDriver` drives the injected `ScriptedCall` — so the call
  screen opens with "You" + their face and a rotating speaking ring, and the Office
  shows the **"In a call with …"** banner (tap it to reach the faces). Whoever you
  are talking to stops milling until you walk away, so the call holds. This is the
  whole in-call screen reached through the app's own paths, where `TARGET=call`
  mounts it directly.
- **Settings** renders.

> **Walking.** The D-pad is shelved in production (`kShowDPad = false`) — you walk by
> tapping a destination tile, exactly as in the real app. That path runs through the
> same `Walk` → `Collector.move`/route plumbing, so it is genuinely exercised here.

## Driving it with `idb` (autonomous taps + screenshots)

Same loop as `beacon_manager` — describe the accessibility tree, tap by
coordinate, screenshot to verify.

**One-time install** (from `beacon_manager/AGENTS.md`):

```sh
# client — MUST be system python 3.9, not 3.14 (fb-idb 1.1.7 calls
# asyncio.get_event_loop(), a hard error on 3.14). Lands in ~/Library/Python/3.9/bin.
/usr/bin/python3 -m pip install --user fb-idb

# companion (third-party tap — trust the source when brew prompts)
brew tap facebook/fb
brew install idb-companion
```

**Invocation gotcha:** if `asdf` is on PATH its `idb` shim dies with *"No version
is set for command idb"*, and its `python3` shim resolves to 3.14 (which fb-idb
1.1.7 cannot run). Call the real binary directly:

```sh
IDB=~/Library/Python/3.9/bin/idb
```

**The loop:**

```sh
SIM=<sim-udid>
$IDB ui describe-all --udid $SIM                 # dump AXLabels + frames
$IDB ui tap --udid $SIM <X> <Y>                  # tap in LOGICAL points
xcrun simctl io $SIM screenshot /tmp/shot.png    # verify (pixels)
```

Verified end-to-end on an iPhone 17 Pro sim: `--dart-define=SCENARIO=roundrobin`
boots the call with four avatar tiles + a live speaking ring; tapping **Auto**
promotes the active speaker into the big view with the strip below.

**Coordinate units:** `idb ui tap` takes **logical points**; `simctl` screenshots
are **pixels** (×3 on a 3× device, so `point = px / 3`). Read coordinates straight
from `describe-all` frames to skip the math.

### Targets on the call screen

These widgets carry stable keys/labels (see `call_screen.dart`), so `describe-all`
finds them:

- **Mode toggle** — the `Manual` / `Auto` segmented pill in the header
  (`_ModeToggle`, segment labels `"Manual"` / `"Auto"`). Tap `Auto` to hand the
  big view to the scenario.
- **A face** — grid tiles key `ValueKey(<tile.id>)`; in the big view the strip
  tiles key `ValueKey('strip-<tile.id>')` and the enlarged face
  `ValueKey('big-<tile.id>')`. Tapping a face enlarges it (manual); tapping in
  auto switches to manual and watches that face.
- **`Everyone`** — the return button (`_OverviewButton`, label `"Everyone"`) back
  to the grid.

### What to check

- `roundrobin` + Auto: the big view follows each talker, promotes once per turn,
  doesn't jump between speakers.
- `debate` + Auto: the holder keeps the floor while talked over; handover only
  after they stop and the other clears the dwell. No thrash.
- `briefnoise` + Auto: the big view never appears — every blip is under the dwell.
- Manual: tap the toggle to `Manual`, tap a strip/grid face → it enlarges; tap
  `Everyone` → back to the grid.

## Driving features headless (the debug drive)

The `idb` loop above answers "does it *look* right" by tapping coordinates and
reading pixels. Most questions an agent asks are not visual — "is my avatar on the
tile I sent it to", "am I in the huddle", "is the mic actually on", "what did the
media plane log in the last ten seconds" — and answering those through screenshots
pays for the whole navigation path on every check and breaks whenever the layout
moves. The **debug drive** answers them as JSON instead: every action is a Dart VM
service extension named `ext.gc.<feature>.<action>` that calls (or reads) one
existing public method on `AppState`. It rides the VM service channel that
`flutter run` already opens, so the app gains no server, no port and no runtime
dependency.

It exists **only in debug builds**. `lib/main.dart` and `lib/main_harness.dart`
install it inside `if (kDebugMode) { … }`; because that guard is a compile-time
constant, the release compiler strips every handler and every `ext.gc.` name, and
`tool/release_artifact_check.sh` greps the release `App.framework/App` and
`libapp.so` in CI to prove it. Profile and TestFlight builds have no drive, by
design — on a physical iPhone the VM service only exists while a debug app runs
under `flutter run`. The design and the phase plan are in
`docs/debug-drive-plan.md`; the code is `lib/src/debug_drive/` (see its
`AGENTS.md`).

**What Phases 1–2 expose** (ask the build itself with `drive.list` rather than
trusting this list):

| Action | Returns |
|--------|---------|
| `drive.list` | every registered action, sorted, with its `outward` flag, plus `boot` (`"harness"` or `"live"`) |
| `state.dump` | phase, link, collector health, me (id, tile, room), `spaceId`/`spaceName`, `testSpace`, roster counts, call summary (mic/camera/screen, participants, `inHuddle`), settings, `boot`. **No tokens, cookies or credentials, ever** |
| `log.tail {since?, max?}` | `{lines:[{seq,line}], next}` from a 2000-line in-memory ring fed by `mediaLog` — the same lines that land in `media.log`, without a `devicectl copy` |
| `op.status {id}` / `op.result {id}` | the state of a long-running action (see *Ops* below) |
| `media.snapshot {windowMs?}` | per-stream flow verdicts over a short series it takes itself (default 2000 ms, max 3000), plus the last raw sample (counters per consumer/producer, per-transport ICE/DTLS, expected streams, errors). See *Media* below |
| `media.watch {durationMs?, intervalMs?, maxGapMs?, stallAfterMs?}` | an **op**: samples every `intervalMs` (default 1000, min 250) for `durationMs` (default 10000, max 120000) and answers a per-stream summary — `continuous`, gaps, longest gap, avg kbps / fps, loss % — plus a compact timeline |
| `media.render {windowMs?, firstFrameWithinMs?}` | every mounted video tile (what its renderer is bound to, first frame yes/no, size, slot) and a cross-check of the tiles against the flow verdicts |
| `sfu.debug` | the media session's own picture: own node, node pool, `peerNode` cache, send/recv transports and states, producers, consumers (`producerId` vs what the peer announces now), pending consumes, subscribed / denied / producer-gone / unreachable sets, heal timers. No tokens |

Every answer is one of three shapes, kept apart on purpose so an agent can tell
"the app said no" from "the drive broke": `{"ok":true,"data":…}`; a successful
`{"ok":false,"reason":"…"}` for an expected refusal (no call, not in a space,
outside the test space); or an RPC error — `invalidParams` for unreadable input,
an extension error carrying `{error,type}` for a handler that threw (also reported
through `FlutterError.reportError`, so it shows in the `flutter run` console).
`boot` is in `drive.list` and `state.dump` so a scripted harness reading is never
mistaken for the live wire.

### Media: is the call actually flowing (Phase 2)

Every call bug this app has had looked healthy from the signalling: a consume
that never retried, a send transport acking produces into a dead node, a stale
peer-node cache. The packet counters are the only witness, so `media.*` reads
them (`getStats` per consumer and per producer, each row attributed to its own
track — camera bytes never count as mic bytes) and turns each interval into one
word per stream. Streams are keyed `in:<srcId>|<tag>` (receiving) and
`out:<tag>` (sending), tags as the SFU spells them: `audio`, `video`, `screen`.

| Verdict | Means |
|---|---|
| `flowing` | packets/bytes rose; video: `framesDecoded` (out: `framesEncoded`) rose; audio: energy rose |
| `silent` | audio packets rose but `totalAudioEnergy` did not — the peer is sending silence (muted at the device, a quiet room). Opus DTX makes this normal: **not a failure** |
| `stalled` | the consumer/producer exists and is not paused, but its counters have been flat for ≥ `stallAfterMs` (default 2 s). The grace intervals before that keep their last verdict |
| `paused` | consumer or producer paused (wire mute); flat counters expected |
| `missing` | expected — subscribed, and the peer announced a producer for the tag — but there is no consumer. Consume-not-allowed and a stale peer node land here |
| `not_measured` | `getStats` threw or timed out (2 s per call), or there is no baseline yet. **Never folded into `stalled`** |

In a `media.watch` summary, `continuous` means no gap longer than `maxGapMs`,
where a gap is a run of `stalled`, `missing` or `not_measured`. `silent` counts as
flowing for continuity (DTX); `not_measured` breaks it (continuity is a claim
that needs evidence); `paused` is reported separately as `pausedMs` and is never
a gap. "Healthy for 30 s" is one assertion:

```sh
# start the watch and block on its op; --wait prints the final op.result
tool/drive.sh -d $SIM --wait --timeout 60 media.watch '{"durationMs":30000}' \
  | jq '.data.result | {allContinuous, streams: [.streams[] | {key, continuous, longestGapMs, verdicts}]}'
tool/drive.sh -d $SIM media.snapshot | jq '.data.verdicts[] | {key, verdict, detail}'
tool/drive.sh -d $SIM media.render   | jq '{ok: .data.ok, findings: .data.findings}'
tool/drive.sh -d $SIM sfu.debug      | jq '.data | {node, peerNode, producerGone, consumers}'
```

**`media.render`** checks the last hop the counters cannot see: decoded frames
reaching the *right tile*. Each video tile reports to a debug-only
`RenderRegistry` what its renderer is bound to and whether a first frame came out
(written only inside `if (kDebugMode)`, so release strips it). The answer lists
`findings`, each with a `problem`:

| `problem` | Means |
|---|---|
| `flowing_without_tile` | a peer's video (their screen, while they share), or your camera, is `flowing` and no tile shows it |
| `bound_not_present` | a tile shows a stream there is no consumer/producer for — a dead texture or the wrong person |
| `bound_not_flowing` | a tile shows a stream that is `stalled`, `paused` or `missing` — a frozen frame presented as live |
| `duplicate_tiles` | two tiles in one slot on one stream (the spotlighted face, big *and* in the strip, is by design and not flagged) |
| `never_rendered` | a tile bound for ≥ `firstFrameWithinMs` (default 3000) with no first frame since — the black rectangle |
| `stale_binding` | *live only* — the renderer's `srcObject` is not the stream the tile was handed (a missed re-attach) |
| `wrong_stream` | *live only* — the bound stream belongs, by the call's own books, to another `srcId|tag` |
| `unverified` | the tile's stream was `not_measured`; counted in `unverified`, not a failure |

`ok` is true with no findings but `unverified`; with the call screen closed there
are no tiles, and the answer is `screenOpen: false`, `ok: null` — no evidence is
not a pass. Open the call screen first (Dial warp, or walk up to someone).

**`sfu.debug`** is the pair to `media.snapshot`: the counters say what is
happening, this says what the session *believes* — and the bug is the
disagreement. A `missing` stream with its key in `producerGone` is the stale
producer id (#61); one whose `peerNode` points at a node that is `down` is the
dead-node cache (#83); `transports.send.onCurrentNode: false` is the send
transport left on a node we moved off (#67).

**Scripted vs live.** Every reading carries `source`. In the harness it is
`"scripted"`: `ScriptedCall.sampleFlow` synthesises counters from the call state
(each participant's announced tracks as consumers whose counters climb with the
clock, paused when their mute says so) and can be told to misbehave per stream
through `flowFaults` (`stall`, `silence`, `missing`, `unmeasured`), so the verdicts
and summaries can be checked on a bare simulator. Harness tiles (the stand-in
footage) report to the render registry as `scripted` and describe the stream they
stand in for — a peer the script gives no video is reported as showing none, even
though the test card is painted over them. The harness has no `MediaStream`s, so
`stale_binding` and `wrong_stream` are live-only, and `sfu.debug` answers
`{"ok":false,"reason":"no_sfu_session","source":"scripted"}` — there is no SFU
to describe. A live call answers `no_sfu_session` (`source: "live"`) until the
first thing that needs the SFU opens a session. **None of this proves the wire**:
that takes two real endpoints in the test space (plan Phase 3).

A live call also writes a compact verdict line to `media.log` every 5 s while it
has anything to send or hear (`flow: in:<srcId>|audio=flowing out:audio=silent …`),
so a field report carries packet-level evidence; `log.tail` shows it too.

### Starting the app so the drive can be reached

The client needs the VM service URI, auth code included. Have `flutter run` write
it to a file — **do not rely on `flutter attach` discovery**, whose mDNS lookup is
broken on the simulator on macOS 15.4+ (flutter/flutter#166333). One file per
device, under `.dart_tool/`, which `tool/drive.sh` reads:

```sh
# simulator, harness (the default target for agents — no login, no wire)
flutter run -t lib/main_harness.dart -d <sim-udid> \
  --vmservice-out-file=.dart_tool/vm_uri.<sim-udid> \
  --dart-define=TARGET=app --dart-define=SCENARIO=office

# USB iPhone, real entrypoint, live wire — in the test space (see below)
flutter run -d <device-udid> --dart-define-from-file=dart_defines.json \
  --dart-define=DRIVE_TEST_SPACE=<test-space-id> \
  --vmservice-out-file=.dart_tool/vm_uri.<device-udid>
```

`--debug` is the default and the only mode with a drive; `--profile`, which the
device section of `AGENTS.md` recommends for untethered use, has none. The file
is rewritten on every run and left behind when `flutter run` exits — a stale file
is why `drive.sh` answers 69 rather than hanging.

### `tool/drive.sh` — one call per command

```sh
tool/drive.sh [-d <device-id>] [--wait] [--timeout <s>] <action> ['<json args>']
```

Each invocation opens one short-lived VM service connection, calls `getVM`, picks
the isolate that exposes `ext.gc.drive.list` (falling back to the first
non-system isolate), makes the call, prints the result JSON and exits. Nothing is
cached between calls, which is what makes it survive a hot restart: the isolate
id changes, and the next call simply looks it up again. Without `-d` it reads
`.dart_tool/vm_uri`, else the only `vm_uri.<id>` present; two device files and no
`-d` is a usage error, because guessing would drive the wrong phone.

```sh
tool/drive.sh drive.list                                  # what this build exposes
tool/drive.sh -d $SIM state.dump | jq '.data.me'          # where am I
tool/drive.sh -d $SIM log.tail '{"max":50}'               # newest 50 media.log lines
tool/drive.sh -d $SIM log.tail '{"since":1234}'           # only lines after cursor 1234 (pass back data.next)
tool/drive.sh -d $SIM op.result '{"id":"move-3-k2x9qa"}'  # poll an op by hand
tool/drive.sh -d $SIM move.goTo '{"x":12,"y":7}' --wait   # start an op and wait for it (Phase 5 action)
```

The args are **one JSON object, quoted as one shell argument** (zsh does not
word-split, but an unquoted `{…}` is still mangled by globbing). `drive.sh`
checks the JSON before connecting, so a quoting mistake is a usage error, not a
drive failure.

**Ops.** Anything that waits — a walk, a warp into a call, a media watch — never
holds the RPC open. It returns `{"ok":true,"data":{"id":"<kind>-<n>-<nonce>"}}` at
once, and `op.status` / `op.result` report `pending | done | failed` with
`startedAt`/`finishedAt` (and the result, or `error`/`type`). `--wait` does the
polling and prints the final `op.result`. The nonce is drawn once per isolate, so
an id from before a hot restart is answered "from another isolate — re-run the
action" instead of with some new op's result; the drive keeps the last 32 ops, and
an evicted id says so. Phase 1 ships the op machinery but no action that starts
one yet.

**Exit codes** (sysexits-style, so a loop or an agent can switch on them):

| Code | Meaning |
|------|---------|
| 0 | `ok: true` (or the waited-for op finished `done`) |
| 1 | refused: `ok: false` with a `reason` — nothing broke, change the request |
| 2 | RPC error (invalid params, a handler threw, unknown method) or the op `failed` |
| 64 | usage: bad flags, bad JSON, malformed action name, or `--wait` on an action that returned no op id |
| 69 | unavailable: no URI file, nothing listening, or the isolate went away mid-`--wait` (hot restart) — re-run the action |
| 75 | `--wait` timed out (default 300 s); the op may still finish, poll `op.result` again |

### Agent recipe: `dart_mcp_server`

An agent with MCP does not need `drive.sh`: the Dart SDK ships `dart mcp-server`,
whose `vm_service callMethod` passes any method name through, so there is no MCP
code of our own to maintain. Register it once with the **absolute** `dart` path —
the `asdf` shim fails when the server is started outside the repo, where no
`.tool-versions` resolves:

```sh
# resolve the pinned SDK's real binary now, so the MCP config holds a fixed path
claude mcp add dart -- "$(dirname "$(asdf which flutter)")/dart" mcp-server
# → e.g. ~/.asdf/installs/flutter/3.44.5-stable/bin/dart mcp-server
```

Then, per session (and again after any hot restart):

1. **`dtd listDtdUris`** — lists every Dart Tooling Daemon on the machine,
   including stale ones from earlier runs.
2. **`dtd connect`** to the one whose **Workspace Root** is this worktree. Picking
   by root, not by "the first one", is the step that keeps an agent from driving
   another checkout's app.
3. **`vm_service callMethod getVM`** — read the app isolate's id from `isolates`.
   `isolateId` is **required** on every extension call; without it the call fails
   as `-32601 Unknown method`, which reads like "the drive is missing" when it is
   only "you did not say which isolate".
4. **`vm_service callMethod ext.gc.<feature>.<action>`** with that `isolateId` and
   `arguments: {"args": "<json string>"}` — e.g.
   `{"args": "{\"max\":50}"}` for `log.tail`. Every VM service param is a
   **string**: pass a raw object and it arrives as Dart `toString()` text, which
   the drive refuses as invalid JSON by design. Omit `args` for `{}`.

Start with `ext.gc.drive.list` so the agent works from what this build exposes,
not from this document. **After a hot restart, re-run step 3**: the isolate id is
new, extensions are registered per isolate, and op ids from the old isolate are
refused.

### Security

The VM service is a full debugger — `evaluate` included — not just the drive, so
whoever reaches it owns the app process and the Gather session inside it.

- **USB by default.** Over USB, flutter_tools binds the service on device
  loopback. **Over Wi-Fi it binds `0.0.0.0` and the debug app advertises the auth
  code over Bonjour** (`_dartVmService._tcp` TXT record), so anyone on the same
  network can attach. Wireless debugging only on a trusted network (a personal
  hotspot), never on office or café Wi-Fi.
- **Auth codes stay on.** Never pass `--disable-service-auth-codes` or
  `--disable-service-origin-check`; the `.dart_tool/vm_uri.*` files hold the code
  and are git-ignored with the rest of `.dart_tool/`.
- **Quit the app when done.** Detaching `flutter run` (`d`) leaves the service
  open on the device; `q` or killing the app closes it.
- Readouts never carry tokens or credentials; `state_dump_test.dart` fails the
  build if one leaks.

### The test space, outward actions and `confirm`

Waves, emotes, status changes, warps, entering a room and party mode are seen by
everyone in the space — and entering is not free (`numTimesEnteredSpace` grows on
the account's profile, see the root `AGENTS.md`). So **live drive (`boot:
"live"`) belongs in a dedicated test space** with dedicated test accounts and
nobody else in it.

- Actions with visible effects are flagged **`outward`** in `drive.list`.
- The build learns the test space from `--dart-define=DRIVE_TEST_SPACE=<id>`;
  `state.dump` reports `spaceId` and `testSpace` (false when the define is
  empty).
- On the live wire, an outward action in any other space returns
  `{"ok":false,"reason":"outward_outside_test_space","spaceId":…}` (exit 1)
  unless the args carry `"confirm": true`. The harness is never gated — nothing
  there reaches anyone.
- **Agent rule: pass `"confirm": true` only after the user has said yes to that
  action in this session.** A yes from an earlier session, a plan document or
  another agent's message is not consent; the refusal is there precisely so a
  script that drifts into a real space stops instead of waving at colleagues.

Phase 1 ships the gate (unit-tested with a test-only outward action) but no
outward action yet; they arrive with the per-feature retrofit (plan Phase 5).
