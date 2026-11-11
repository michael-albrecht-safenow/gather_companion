#!/usr/bin/env bash
# Prove a release binary carries no debug drive.
#
# The debug drive (lib/src/debug_drive/) is a set of `ext.gc.*` VM service
# extensions that call straight into AppState: walk, warp, set the mic, read the
# room. It is only safe because a release build does not contain it. Nothing at
# runtime enforces that — there is no VM service in a release build to register
# on, but the handler bodies and the classes they pull in would still ship, and
# the moment someone wires them to another channel they are live.
#
# What removes them is the compile-time guard at the call site,
# `if (kDebugMode) installDebugDrive(...)`: with a constant false the AOT
# compiler drops the call, and tree shaking then drops every method name and
# handler that only it reached. A guard on a runtime bool does not do that, and
# looks identical in review. So this greps the compiled Dart itself —
# `App.framework/App` on iOS, `libapp.so` on Android — for the method prefix.
#
# A grep that finds nothing proves nothing on its own: the wrong file, a
# compressed one, or a string encoding the grep cannot see would all pass. So a
# control string that *is* in release Dart code must be found too, or the check
# fails as inconclusive. The control is the pairing screen's title, which every
# release build shows; override it with RELEASE_CHECK_CONTROL if that text
# changes (and change the default here).
#
# Usage: tool/release_artifact_check.sh <binary> [<binary>...]
# Exit:  0 every binary is clean and has the control; 1 otherwise; 64 usage.
set -euo pipefail

forbidden='ext\.gc\.'
control="${RELEASE_CHECK_CONTROL:-Pair with your computer}"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <binary> [<binary>...]" >&2
  exit 64
fi

failed=0
for binary in "$@"; do
  if [[ ! -f "$binary" ]]; then
    echo "release check: $binary: no such file" >&2
    failed=1
    continue
  fi
  # LC_ALL=C: a binary is not text in any locale, and a UTF-8 locale makes grep
  # stop at the first invalid byte sequence on some platforms.
  if LC_ALL=C grep -aq "$forbidden" "$binary"; then
    echo "release check: $binary contains the debug drive (ext.gc.*) — is installDebugDrive behind a const kDebugMode guard?" >&2
    LC_ALL=C grep -ao "ext\.gc\.[A-Za-z0-9.]*" "$binary" | sort -u | head -20 >&2 || true
    failed=1
  elif ! LC_ALL=C grep -aqF "$control" "$binary"; then
    echo "release check: $binary: control \"$control\" missing — check proves nothing (wrong file, or the control text changed)" >&2
    failed=1
  else
    echo "release check: $binary: clean (no ext.gc., control present)"
  fi
done
exit "$failed"
