#!/usr/bin/env bash
# Call one debug-drive action (ext.gc.*) on a running debug build of the app.
#
# The drive is a JSON API into the app's business logic over the VM service that
# `flutter run` already opens (see docs/debug-drive-plan.md). This is the shell
# door to it: no MCP, one short-lived connection per call, so it composes in
# loops and scripts and its exit code says what happened.
#
# Start the app so it writes its VM service URI where this script looks:
#   flutter run -t lib/main_harness.dart -d <udid> \
#     --vmservice-out-file=.dart_tool/vm_uri.<udid> --dart-define=TARGET=app ...
#
# Usage:
#   tool/drive.sh [-d <device-id>] [--wait] [--timeout <s>] <action> ['<json args>']
#   tool/drive.sh drive.list                         # what this build exposes
#   tool/drive.sh -d <udid> state.dump
#   tool/drive.sh -d <udid> move.goTo '{"x":12,"y":7}' --wait
#   tool/drive.sh op.result '{"id":"move-3-k2x9qa"}'
#
# Exit codes: 0 ok, 1 refused ({"ok":false}), 2 RPC error or failed op,
# 64 usage (incl. --wait on an action that returned no op id),
# 69 unavailable (no URI file, app gone, isolate replaced), 75 --wait timed out.
#
# Runs from the repo root wherever it is called from, because the URI files live
# in the repo's .dart_tool/. The URI carries the VM service auth code: USB by
# default, and quit the app when done — a detached `flutter run` leaves the
# service open (see "Security posture" in the plan).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
exec dart run tool/drive.dart "$@"
