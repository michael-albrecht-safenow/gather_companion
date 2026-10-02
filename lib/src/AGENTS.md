<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# src

## Purpose

Everything the app does that is not drawing: the single state object the UI reads,
the WebSocket client, pairing, persisted settings, local notifications, and the
rules that decide which events are worth a person's attention.

## Key Files

| File | Description |
|------|-------------|
| `app_state.dart` | `AppState extends ChangeNotifier` — the one object the UI reads. Drives the **Gather** connection (`DirectCollector` + `PresenceTracker` + `PartyMode` from `package:gather_client`), and owns the presence snapshot, the link status, and the lifecycle (`boot`, `pair`, `unpair`, `reconnect`, `_attach`/`_detach`). Events are not stored: `_onFold` hands each one to `Notifier` and drops it. It does hold **Gather's** activity feed (`activity`, `unreadActivityCount`, `refreshActivity`, `markActivityRead`), which is not the same thing and is not a local log: it is fetched over REST, it is Gather's own record, and it is full after a weekend when a locally-built one would be empty. Live waves are prepended provisionally and cleared by the next fetch rather than merged into it — the REST list is authoritative by then, and matching a socket event to a row whose id we never saw would have to guess. No socket to the computer: the bridge is reached only by an opportunistic `POST /push/register`. Carries a second `Listenable`, **`positions`**, which ticks on every roster: movement is not a presence event, so `notifyListeners` never fires for it, and the map would otherwise freeze — while waking the whole tree at 4Hz would rebuild the feed on a stranger's footstep. `HomeShell` merges it in only while the map is the selected tab, so it still has no listeners when nobody is looking at the office. |
| `map_person.dart` | `MapPerson` — somebody to draw on the map. Separate from `PlayerRef` on purpose: that model has no coordinates, because proximity is exactly the thing this app refuses to treat as meaning something. |
| `map_motion.dart` | `MapMotion` — where bodies are *between* the tiles the wire reports, plus the ticker that drives it. Gather's positions are whole tiles and the roster is coalesced at 250ms, so drawn literally the office teleports one tile at a time; this is `PlayerEntityV2.preUpdate` transcribed — linear at `1e3/7` ms a tile, snapping past eight (`snapBeyond`). A `Listenable` the painter merges into its `repaint`, so a footstep never rebuilds the widget tree, and its ticker stops itself when nobody is moving, talking or teleporting. **Teleports are told, not guessed** (`noteTeleport`): party mode's own hops arrive as fact and pin their destination for `teleportPin`, because the coalesced, component-wise roster that follows a hop can otherwise be drawn as a walk — a body gliding slowly across the office. Anybody else's jump past `snapBeyond` gets the same effect, inferred. |
| `link_status.dart` | `LinkState` / `LinkStatus` — how good our connection to **Gather** is. Carries `needsPairing`, the one state that asks the user to act rather than wait. |
| `credentials.dart` | `GatherCredentialStore` — the Gather refresh token, in the platform keychain. Not `SharedPreferences`: this is the user's whole Gather identity and backups include plists. |
| `pairing.dart` | `PairPayload` parsing (`HOST:PORT:CODE`), `normaliseCode()`, `parseAddress()`, and `claimPairing()` — the one unauthenticated call in the API. |
| `settings.dart` | `BridgeSettings` — host, port, token, plus `httpUri()` construction; and `BridgeSettingsStore`, which keeps them **in the keychain beside the Gather session**, with a one-shot migration out of `SharedPreferences`. Moved there for *durability*, not secrecy: iOS wipes a preferences plist on reinstall and leaves keychain items alone, so the old split left phones with a working Gather session and no bridge address — push registration bails without one, so the phone silently stopped handing over its FCM token while the bridge went on pushing to the previous install's dead token, which FCM accepts with a 200. Do not move it back without reading that header. Also mints the stable `installId` the bridge keys its device list on. |
| `notifications.dart` | `Notifier` — local notifications for the two events worth interrupting someone for, with permission requested *after* pairing rather than at launch. |
| `push.dart` | `PushRegistrar`, `PushReach`, `PushRegistration` — the other half of notifications, and the **only** thing the app still asks the computer for. Fetches the APNs token *before* the FCM one, because `getToken()` is meaningless until APNs has answered. `register()` returns a six-state outcome rather than `void`: it used to discard everything, which is why a fortnight of pushes went nowhere with no error anywhere. The `POST /push/register` **is** the reachability probe — idempotent by design, and its reply says whether the bridge can actually send — so there is no `/health` ping and nothing polls. Re-posted on attach, on resume, and on token rotation. |
| `media/media_engine.dart` | `MediaEngine`, `LocalMediaState`, `MediaFailure` — the seam between call logic and hardware. **Imports no `flutter_webrtc`**, which is what lets the call logic be tested on a machine with no camera. Talks in state and track ids, never native objects. |
| `media/webrtc_media_engine.dart` | `WebrtcMediaEngine` — the only file in the app that imports `flutter_webrtc`. `getUserMedia`, camera switching, teardown. Exposes `localStream` concretely for the renderer, deliberately off the interface. Mute goes to the **audio device** (`Helper.setMicrophoneMuted` in `voiceProcessing` mode), not to `track.enabled`: disabling the track stops the frames while the capture session runs on, leaving iOS's orange microphone indicator lit for the whole mute. The file's header explains the trade in full, including the platform mute tone it accepts to get muted-talker detection. |
| `media/mediasoup_ice.dart` | Three lines that re-export `RTCIceServer` / `RTCIceTransportPolicy` / `RTCIceCredentialType` from `mediasfu_mediasoup_client`'s unexported `src/handlers/`. The **only** `implementation_imports` ignore in the app, deliberately kept to one file: those types are the declared parameters of every API that accepts TURN servers, so the real choice is this or no TURN. Read the header before touching it. |
| `media/call.dart` | `Call`, `CallState` — the two buttons a person actually presses, and the seam `AppState` holds so it can drive a microphone without importing `flutter_webrtc`. Mute is deliberately *two* things: a device mute, which is what makes iOS drop its recording indicator, and a `produce-pause`, which is what makes a colleague's client draw the crossed-out microphone. Doing only one of them lies in one direction or the other. |
| `media/live_call.dart` | `LiveCall` — `Call` with a capture session and an SFU behind it. Two rules worth knowing before editing. The capture holds **exactly** the tracks in use, so turning the camera on for the first time *restarts* it: the alternative, capturing both and disabling the video track, keeps the camera session running and the indicator lit, which is the same lie `webrtc_media_engine.dart` refuses about the microphone. And the SFU is connected on the **first publish**, not at join — a companion app is in a pocket far more often than it is used to talk. Producers are paused rather than closed on mute, so unmuting is instant. Every call is serialised, because two taps could otherwise interleave a capture restart with a publish and produce on a dead track. |
| `media/sfu_session.dart` | `SfuSession` — the media plane's client half, both directions. Sending: router `get-addr` → node connect → `get-rtp-capabilities` → `Device.load()` → send transport → `produce`, VP8 with Gather's own three simulcast encodings (only `r0` active; the server flips the rest via `set-max-spatial-layer`). Receiving: `consume-request` to subscribe, then **reconciliation** against the full-state `producer-idMap` each `consume-try` carries — never delta handling, because the announcement is the whole truth about one peer. Holds a **pool** of node sockets, not one: peers are spread across SFUs and `get-addr` is asked per person. Owns the mediasoup `Device`; `sfu_signalling.dart` in `gather_client` owns the sockets beneath it. **Not exercised against the live SFU yet**, and it carries one uncaptured assumption — the `transport-create` *response* shape — named in the file. |
| `media/call.dart` | `Call`, `CallState`, `CallParticipant` — what the two buttons mean, with **no `MediaStream` anywhere on it**. That is what lets call state be read everywhere without dragging the plugin along; the screen that draws video asks `LiveCall` for the native streams directly. |
| `media/live_call.dart` | `LiveCall` — [MediaEngine] and [SfuSession] driven together: capture, publish, subscribe, and the capture *restart* that adding a camera mid-call requires (a track cannot join a session that is already open, and leaving the camera captured-but-disabled would keep iOS's indicator lit). |
| `media/os_call.dart` | `OsCall` — the seam between "there is a call" and "the OS knows there is a call" (CallKit on iOS, a future `ConnectionService` on Android). Imports no platform channel, so `AppState` stays testable; `defaultOsCall()` picks `IosCallKit` on iOS and `NoopOsCall` everywhere else (Android for now, and tests). |
| `media/os_call_callkit.dart` | `IosCallKit` — the thin `MethodChannel('gather/os_call')` to `ios/Runner/CallKitController.swift`. A hand-written bridge, not a plugin: the CallKit plugins are PushKit-incoming-call-shaped (this app's calls are app-initiated off a held socket) and CocoaPods-first (this project is SPM-only on purpose). Channel failures are swallowed — a call the OS does not know about beats a crash. |

## The OS-call engage model

A Gather call connects on **proximity** (`Call.setListeningTo` with a non-empty
set), with nobody pressing anything. CallKit must *not* hear about that, or the
Recents log fills up as the phone drifts past conversations in a pocket. So the OS
is told a call is running only on deliberate **engagement**, which `AppState` owns:

- **Engage** (→ `OsCall.reportStarted`) on the first of two doors — `setMicOn(true)`
  succeeding, or `openCallScreen` (`AppState.engageCall`). Guarded by `_engaged`
  so both doors report **one** call, not two. Muting does not disengage: a muted
  call is still a call.
- **Disengage** (→ `OsCall.reportEnded`) on every teardown — `AppState.leaveCall`
  (the in-app Leave), the connection dropping, or unpairing.
- The OS's own buttons come back the other way: `onEndRequested` → `leaveCall`,
  `onMuteRequested` → `setMicOn`. The in-app Leave and CallKit's End share one
  path so the two can never disagree about whether a call is up.

On iOS, CallKit owns the `AVAudioSession` route (the system call sheet is the
picker), so `WebrtcMediaEngine` is built with `manageAudioRoute: false` there — it
sets the call category but forces no route and installs no headset listener — and
the in-app speaker button is hidden. Android keeps routing itself. See
`os_call_engage_test.dart` for the seam and `ios/Runner/AGENTS.md` for the native half.

## For AI Agents

### Working In This Directory

- **Events are not kept anywhere.** There was an on-phone `EventLogStore` and a
  `relevance.dart` classifier behind a scrolling activity feed. Both are gone. Once
  the app held its own Gather socket the log could only record what happened while
  the app was open — the one window in which the user was already looking — so it
  was empty exactly when it would have been useful. What it was for is push
  notifications, which do not need it: `_onFold` calls `Notifier.consider` and lets
  the event go. Do not reintroduce a store without solving the closed-app case
  first.
- **`_detach()` must stay synchronous.** It was once `async` with `_client = null`
  after an `await`, so the null landed a microtask after `_attach()` had installed
  the replacement and quietly wiped it. Disposal can finish in the background; the
  bookkeeping cannot.
- **`whenLive()` plus a 450 ms floor** is what makes pull-to-refresh feel like an
  action. A local bridge answers in ~50 ms and an indicator that vanishes inside
  two frames reads as a rendering fault. The floor is outside the null check on
  purpose, so the gesture feels the same with or without a socket.
- **Pairing refuses rather than guesses.** The alphabet excludes `0`, `1`, `I`,
  `L`, `O`; characters outside it are dropped, which then fails the length check.
  There is no sound way to know whether a reported `O` meant `Q` or `D`, and
  pairing on a misread code is worse than asking someone to look again.
- The `SocketException` copy in `claimPairing` leads with the local-network
  permission prompt on purpose: the *first* connection to a private address is
  what raises that prompt, and that attempt fails while it is still open. "Check
  your Wi-Fi" would be the wrong first thing to say.
- `notifications.dart` deliberately requests no permission during `init()`. A
  permission sheet before the user has even paired is asking for a "no".

### Testing Requirements

```sh
flutter test                            # everything
```

Adding an event type means adding a case to the switch in `notifications.dart`,
which decides its title and body — that is now the only place an event is phrased,
and the only place one is judged worth interrupting someone for.

Use the `@visibleForTesting` seams on `AppState` — `debugApplySnapshot`,
`debugApplyEvent`, `debugApplyLink` — rather than standing up a fake bridge.

### Common Patterns

- Sealed-class pattern matching with guards (`when notifyOnFollow`) and
  destructuring in `case` clauses.
- Failures degrade rather than throw: `recentHistory()` returns `const []` on any
  error because priming is a nicety, and a failed notification must never break
  the log.
- Every non-obvious decision carries a doc comment naming the symptom it fixes.

## Dependencies

### Internal

`package:gather_events` for every model; `../theme` is *not* imported here (this
layer stays free of widgets entirely.

### External

`flutter_secure_storage`, `shared_preferences` (the migration path only),
`firebase_messaging`, `flutter_local_notifications`, `dart:io` (`HttpClient`).

<!-- MANUAL: -->
