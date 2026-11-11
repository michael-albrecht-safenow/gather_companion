# In-app test plan — spotlight & office, driven by the debug drive

Run on the iOS simulator through `lib/main_harness.dart` (no network, no WebRTC,
no Gather backend). Each row is one harness launch, and each row's claim is
checked **through the debug drive only** (`ext.gc.*`, see
`docs/debug-drive-plan.md`) — no tap by coordinate, no screenshot. Gates:
`SpotlightDirector.dwell = 1.5s`, `linger = 5s`.

```sh
tool/sim_plan.sh                    # every row, first booted simulator
tool/sim_plan.sh --only C4,C5       # some rows
tool/sim_plan.sh -d <udid> -p 4     # a given simulator / cast size (PARTICIPANTS)
tool/sim_plan.sh --list             # the rows and their claims
```

The runner (`tool/sim_plan.dart`) does one `flutter run -t lib/main_harness.dart
--vmservice-out-file=.dart_tool/vm_uri.<udid>` per row with that row's
`TARGET`/`SCENARIO`/`PARTICIPANTS`, waits for `drive.list`, runs the row, prints
`<id> PASS|FAIL` with the values judged (and one line per failure), then quits
that run. Exit 0 all pass, 1 any fail, 130/143 on ctrl-c/SIGTERM — which still
quits the row's `flutter run` and terminates the app first. Per-row `flutter run` output:
`.dart_tool/sim_plan/<row>.log`. The judging is pure —
`tool/sim_plan_check.dart`, unit-tested by `test/tool/sim_plan_check_test.dart`,
which plays each scenario's speaking schedule through the real
`SpotlightDirector`.

**Scenario names** are the enum values (`roundRobin`, `briefNoise`); the harness
matches them case-insensitively, so `roundrobin` works too — but a typo silently
falls back to `group` / `office`, which is why each row also checks the scene it
got (tile counts, seeded waves).

## How the spotlight rows are judged

A spotlight claim is about a state machine with a clock, so one reading proves
nothing. After `call.spotlight.mode {mode:"auto"}` the runner samples
`call.spotlight` every 200 ms for the row's watch window and keeps the
controller's `transitions` history. Times are the app's own (`since + sinceMs`).

- **The dwell rule** (every auto row that promotes): each `promoted` transition
  to X at *t* must be preceded, for all of `(t − dwell + 450 ms, t)`, by samples
  in which X is in `speaking` **and** the face then on screen is not — "held the
  floor for the dwell" and "a talking target is sticky" in one check, judged
  from the inputs rather than from the director's own `candidate` countdown.
  The 450 ms trim leaves that per-sample rule blind to a dwell short by less
  than about half a second, so every promotion must also land ≥ dwell − 50 ms
  after the flip (which reset the director on the same app clock).
- **Gates:** dwell and linger are the plan's (1.5 s / 5 s), not the readout's
  `dwellMs`/`lingerMs` — a readout reporting anything else fails the row
  rather than being judged on its own clock.
- **Grid flash / dropped linger:** no transition to `null` after the first
  promotion.

## Call target (`TARGET=call`) — spotlight behaviour

| # | Scenario | Watch | Drive steps | Assertion (PASS when all hold) |
|---|----------|-------|-------------|--------------------------------|
| C1 | `solo` | 4 s | `call.spotlight.mode auto`, sample `call.spotlight` | every sample `tiles == [selfId]`; `view` never `spotlight`; `target` always null; `promotions` +0. `state.dump` still answers (no crash). |
| C2 | `pair` | 9 s (2 cycles of 2.5 s on / 1 s off) | auto, sample | one other tile; ≥ 1 promotion, to the other, obeying the dwell rule; every sample after it `view == spotlight` and at least one of those has `speaking == []` (the gap was seen); no drop to grid. |
| C3 | `group` | — | `call.spotlight` at rest, `call.spotlight.pick {id}` on the first other tile, `call.spotlight.overview` | rest: `mode manual`, `view grid`, `target` null, N other tiles, `speaking == []`; pick: `view spotlight`, `target == id`; overview: `view grid`, `target` null, still manual. |
| C4 | `roundRobin` | 15 s (≥ N×3 s) | auto, sample | N others; promotions within `watch/3 − 1 … ⌈watch/3⌉ + 1` (one per turn); successive promotions ≥ 2.5 s apart (the first, anchored to the flip, excepted) — no jump mid-turn; never the same id twice running; every promotion after the first comes `from` a face, and no transition to the grid — face replaces face; the dwell rule. |
| C5 | `debate` | 26 s (two 12 s cycles) | auto, sample | sticky: in overlap samples (`speaking` ⊇ {A,B}) after A was talking alone, `target` stays A — at least one such sample is required, so the claim cannot pass untested — and the newcomer never takes it while A talks; both speakers earn the view in turn; promotions ≤ 2 per whole cycle + 1, i.e. ≤ 5 in 26 s (no thrash); no drop to grid; the dwell rule (B only after holding the floor alone for the dwell). |
| C6 | `briefNoise` | 6 s | auto, sample | `promotions` +0; every sample `view == grid` over a recording spanning ≥ 5 s; at least one sample with a non-empty `speaking` (blips were seen). |
| C7 | `churn` | 10 s (a full 8 s leave/rejoin cycle) | auto, sample | other-tile counts span `N−2 … N` (join/leave tracked); every sample's `target` is null or one of `tiles` (no stale tile, re-floors cleanly when the holder leaves); every `speaking` id has a tile; `state.dump` still answers. Evidence includes `holderLeft`. |

## App target (`TARGET=app`) — whole-app presence

| # | Scenario | Drive steps | Assertion |
|---|----------|-------------|-----------|
| A1 | `office` | wait for `state.dump` `phase home` + `roster.peopleOnMap == N`; `activity.list`; `presence.map.people` twice 2 s apart; wait out 8 s; `activity.list`; `move.goTo {x,y}` (op) to a tile nobody stands on; `state.dump` | `min(N,4)` `seed-wave-*` items; ≥ 1 new (live) wave and `unread > 0` (the badge); N people on the map and ≥ 1 tile changed between readings (milling); the walk settles `atRequested: true` (not `timeout`) and `state.dump` puts `me.tile` there — the real `Walk` against `FakeCollector`, minus the tap. |
| A2 | `still` | same wait; `activity.list` + `presence.map.people`, 7 s apart | `min(N,4)` seeded waves, no new item (no live churn); N people on the map, no tile changed. |

`harness.*` levers (`harness.placePerson`, `harness.call.speak`, …) are not
needed by any row: every claim above is about the scripted scene as launched.
They are the tool when a row has to *force* a moment — use them rather than
waiting for the random office babble.

## Visual by nature — still `idb` + screenshots

What the drive cannot say, because the claim is about pixels or navigation, not
state:

- **Layout:** big view vs strip vs grid geometry, the "You" tile at the head of
  the strip, the speaking ring drawn, the "In a call with …" banner.
- **Navigation:** that the app opens on the Activity tab and the Office is one
  tap in the rail (the tab is widget state; nothing in `AppState` holds it).
- **The schematic floor** drawing (rooms, ghost avatars) on the Office.
- **The Gameboy skin** (`--dart-define=GAMEBOY=true`, `GBTHEME=…`) — the
  mapping is drivable (`gameboy.mapping`), the plastic is not.
- **Design-mock comparison** (see the memory note on comparing the sim to the
  `~/Downloads` mocks).

Method for those:

- `flutter run -t lib/main_harness.dart -d <udid> --dart-define=TARGET=… --dart-define=SCENARIO=… --dart-define=PARTICIPANTS=4`
- `idb ui describe-all` → tap by frame (logical points); `~/Library/Python/3.9/bin/idb`, see `docs/sim_harness.md`.
- `xcrun simctl io <udid> screenshot` (pixels, ÷3 on a 3× device).
