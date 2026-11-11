<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-05 | Updated: 2026-08-05 -->

# tool

## Purpose

Developer scripts: three probes that ask Gather questions, the one that draws the
app icon, and the one that ships a build to TestFlight. None is part of the app
or the npm package.

## Key Files

| File | Description |
|------|-------------|
| `probe-connect.mjs` | The direct-connection spike, still the fastest way to ask Gather a question. `adopt` reuses the desktop session; `spaces` lists ids; `connect` opens a read-only game socket. **`map`** dumps the shape of the map models and tries the REST routes (all 404 — the map is only ever on the socket). **`walkable`** builds the collision grid and scores it against the live roster, which is how the rounding rule in `space_map.dart` was settled. `--dump <file>` writes the raw rows so hypotheses can be swept offline instead of over somebody's workspace. |
| `probe-events.mjs` | The instrument that found Gather's event bus. Prints the full model census, dumps the interaction-shaped models whole, then watches **every** delta patch and bus event unfiltered — which is what `probe-connect.mjs` structurally could not do, since it pipes frames through the four-model reader. Read-only observer; never sends `enterSpace`. |
| `probe-sfu.mjs` | The media-plane capture. Attaches to a running desktop client over CDP and records **every** WebSocket it owns — the upgrade request and its headers, both frame directions, and the close — then prints a grammar summary: where the credential lives, what the correlation key is, and the full ordered method vocabulary per socket. Decodes msgpack (the game socket) and Engine.IO/Socket.IO (the router and SFU sockets). Sends nothing to Gather. |
| `probe-sfu-schema.mjs` | The other half of `probe-sfu.mjs`: asks the SFU what it *accepts* rather than recording what the desktop sends. Connects as the instance-B account to the throwaway space and sends each candidate shape of `transport-create`, `set-player-conversation-metadata`, `produce`, printing the ack — or its absence, which is how zod refuses on this socket. Found the `null`-is-silence bug on 2026-09-17. Creates and closes one transport and one producer; no media. |
| `make_icons.mjs` | Draws the icon from constants and writes all fifteen asset-catalogue sizes, the launch mark on alpha, and the squircled `assets/icon.png`. Zero dependencies — the PNG encoder is `node:zlib` plus a CRC table. |
| `upload-testflight.sh` | Uploads `build/ios/ipa/gather_companion.ipa` via `xcrun altool`. **CI runs this exact script**, so the human path and the automated path cannot drift. |
| `drive.sh` / `drive.dart` / `drive_cli.dart` | The shell door to the debug drive (`ext.gc.*`, see `docs/debug-drive-plan.md`). One short-lived `vm_service` connection per call: URI from `.dart_tool/vm_uri.<device>` (written by `flutter run --vmservice-out-file=…`), `getVM` every time (a hot restart changes the isolate id), the isolate exposing `ext.gc.drive.list`. `--wait` polls `op.result`. Exit codes: 0 ok, 1 refused, 2 RPC error/failed op, 64 usage, 69 unavailable, 75 wait timed out. The pure half (`drive_cli.dart`) is tested by `test/tool/drive_cli_test.dart`. `vm_service` is a dev_dependency for this alone. |
| `release_artifact_check.sh` | The release guard: fails if a compiled Dart binary (`App.framework/App`, `libapp.so`) contains `ext.gc.`, *and* if it lacks the control string (`Pair with your computer`, override `RELEASE_CHECK_CONTROL`) — a clean grep of the wrong file proves nothing. **CI runs it** in both the iOS job (before the TestFlight upload) and the Android job (on every APK's `libapp.so`). Renaming the pairing title means updating the control. |
| `icon-preview.png` | Output of `--preview`, committed for review. |

## For AI Agents

### Working In This Directory

**`probe-sfu.mjs`**

- **Attach at the *browser* endpoint** (`/json/version` → `webSocketDebuggerUrl`),
  never at a page endpoint. Gather hosts the app in a `BrowserView` alongside tray
  and accessory renderers, so picking one `type:"page"` target out of `/json`
  misses whichever one owns the socket. The structure came from
  `bridge/lib/cdp.js`, deleted in `80a2ab8`; recover it with
  `git show 80a2ab8^:bridge/lib/cdp.js` if more of it is ever wanted.
- **`Network.enable` only reports frames from that moment on.** A socket opened
  before the attach produces no `webSocketCreated` event and so has no URL — which
  is why `classify()` tolerates `unknown` and why `reload` exists.
- **Capture every socket, not just the SFU's.** If the media credential were
  minted by an unmapped game-socket action, a probe filtered to the SFU host would
  record a token it could not explain.
- **`--raw` writes live credentials.** A capture carries a Firebase ID token, TURN
  credentials, DTLS fingerprints, and ICE candidates naming your LAN and public
  IPs. `.gitignore` covers `*.raw.jsonl`; the redacted transcript is the one to
  read, quote and commit.
- Sends nothing to Gather, but `reload` restarts the renderer — about two seconds,
  the same interruption `resync` used to cost.

```sh
open -a GatherV2 --args --remote-debugging-port=9222
node tool/probe-sfu.mjs watch          # then walk into a call
node tool/probe-sfu.mjs reload         # catch the router socket at startup
```

**`make_icons.mjs`**

- The mark is a ping on a 32×32 pixel grid: you are the white block in the
  centre, and the green marker is somebody who has attached themselves to you.
  Pixel geometry nods at the tile-grid medium while borrowing nothing from
  Gather's own mark.
- The palette constants are copied by hand from `lib/theme/gather_theme.dart`.
  Changing a token there means updating them here and re-running.
- **Catalogue sizes stay full-bleed squares.** iOS applies the squircle itself; a
  pre-rounded tile is masked twice and comes out with chewed corners. Only the
  README copy carries the mask in its pixels, because GitHub strips the CSS that
  would otherwise round it.
- Writes into `ios/Runner/Assets.xcassets/AppIcon.appiconset`. Another platform
  target needs a matching output path added here.

```sh
node tool/make_icons.mjs --preview
```

**`upload-testflight.sh`**

- The App Store Connect **issuer ID lives in `~/.appstoreconnect/issuer_id`**,
  not in the repo — it is account-level and shared with the Superset app.
  `altool` already reads private keys from that directory by convention, so the
  issuer sits next to them. The script fails with instructions if it is missing.
- `KEY_ID` defaults to `9FVGFF4ZJ8` (Gather) and is overridable via `ASC_KEY_ID`,
  which is how CI supplies whatever its secret holds.
- The version and build number are read **out of the IPA's `Info.plist`**, not
  from `pubspec.yaml` — those disagree the moment someone bumps a version without
  rebuilding, and App Store Connect rejects a duplicate build number.
- `--build` runs `flutter build ipa --export-options-plist ios/ExportOptions.plist`
  so a local build is packaged exactly the way CI packages one. Never let it fall
  back to Flutter's generated export options.
- Requires the distribution certificate in the login keychain and the profile in
  `~/Library/MobileDevice/Provisioning Profiles`. See `../ios/AGENTS.md`.

```sh
tool/upload-testflight.sh --build
```

### Testing Requirements

`drive_cli.dart` is covered by `test/tool/drive_cli_test.dart` (part of
`flutter test`). `release_artifact_check.sh` is covered by
`test/tool/release_artifact_check_test.dart`, which runs it on fake binaries —
clean with the control (0), carrying `ext.gc.` (1), missing the control (1), a
missing file (1), no arguments (64). Neither the icon script nor the
uploader has automated tests. Verify by inspection:
`node tool/make_icons.mjs --preview` and then look at `tool/icon-preview.png`;
for the uploader, a real TestFlight build is the only test, so read it carefully
before changing it — CI depends on it.

### Common Patterns

- Zero dependencies, same as the bridge.
- Long header comments explaining why the script exists at all, not just what it
  does.
- `set -euo pipefail` and `mktemp` with a `trap` cleanup in the shell script.

## Dependencies

### Internal

`make_icons.mjs` → `ios/Runner/Assets.xcassets/`, `assets/icon.png`, and the token
values in `lib/theme/gather_theme.dart`.
`upload-testflight.sh` → `ios/ExportOptions.plist`, `build/ios/ipa/`, and is
invoked by `.github/workflows/publish.yml`.

### External

Node 22+ (`node:zlib`). Xcode command line tools (`xcrun altool`, `plutil`,
`unzip`), and Flutter for `--build`.

<!-- MANUAL: -->
