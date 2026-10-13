# Simulator mock harness — whole app, call & spotlight

A second `flutter run` target that boots straight into a **scripted scene** on the
iOS simulator — no login, no WebRTC, no Gather backend. Two targets, chosen with
`--dart-define=TARGET`:

- **`call`** (default) — straight into the call screen on a scripted multi-party
  call, for the `feature/call-spotlight` big-view auto mode.
- **`app`** — the *whole app*: it boots the real pair→home flow into `HomeShell`
  with a `FakeCollector` standing in for the Gather socket, so the **Office is
  walkable**, **party mode runs**, and the **Activity feed fills** — all with no
  network. Tap a tile to walk; `idb`-drive it like any other screen.

It is the gather equivalent of `beacon_manager`'s `example/lib/main.dart` harness.

## What it is

| File | Role |
|------|------|
| `lib/main_harness.dart` | Entrypoint. `TARGET=call` mounts `CallScreen`; `TARGET=app` injects the fakes, `boot()`s, and mounts the real phase switch (booting→pairing→home). |
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

# the call screen (spotlight)
flutter run -t lib/main_harness.dart -d <sim-udid> \
  --dart-define=TARGET=call --dart-define=SCENARIO=roundrobin --dart-define=PARTICIPANTS=4

# the whole app — boots into the Office, walkable, feed alive
flutter run -t lib/main_harness.dart -d <sim-udid> \
  --dart-define=TARGET=app --dart-define=SCENARIO=office --dart-define=PARTICIPANTS=4
```

- `TARGET` — `call` (default) or `app`.
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
