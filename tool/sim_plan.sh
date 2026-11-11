#!/usr/bin/env bash
# Run docs/sim_test_plan.md on an iOS simulator through the debug drive.
#
# One `flutter run -t lib/main_harness.dart` per row (TARGET/SCENARIO/PARTICIPANTS
# from the row), the row's assertions made purely through ext.gc.* actions, a
# PASS/FAIL line with the values judged, and that run quit before the next one.
# The judging is tool/sim_plan_check.dart, unit-tested by
# test/tool/sim_plan_check_test.dart; the launcher is tool/sim_plan.dart.
#
# Usage:
#   tool/sim_plan.sh                    # every row, first booted simulator
#   tool/sim_plan.sh --only C4,C5       # some rows
#   tool/sim_plan.sh -d <udid> -p 4     # a given simulator / cast size
#   tool/sim_plan.sh --list             # rows and their claims
#
# Exit: 0 all PASS, 1 any FAIL (or a row that could not run), 64 usage,
# 130/143 interrupted (the row's flutter run and app are stopped first).
# Per-row flutter output: .dart_tool/sim_plan/<row>.log
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
exec dart run tool/sim_plan.dart "$@"
