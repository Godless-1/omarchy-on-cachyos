#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove the watchdog ends a nested session when its window closes - and only then.
#
# Hyprland does not exit when its last output goes away: closing the nested
# window leaves it running headless on a synthetic monitor named FALLBACK. A
# live session reports WAYLAND-1, an orphaned one reports FALLBACK, both
# observed directly. Without this the compositors pile up invisibly.
#
# This is code that kills processes, so the cases that must NOT fire matter more
# than the one that must. hyprctl is stubbed on PATH and the runtime directory is
# faked, so the real function runs unmodified and no compositor is involved.
#
#   ./test/test-window-watchdog.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/omarchy-window"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/bin"
# The stub reads its answer from a file the test rewrites mid-run, so a session
# can be made to "lose its window" exactly when we choose. Any dispatch is
# recorded rather than performed.
cat > "$WORK/bin/hyprctl" <<'STUB'
#!/bin/sh
case " $* " in
  *" dispatch "*) echo "dispatch $*" >> "$WD_LOG"; exit 0 ;;
esac
case "$(cat "$WD_STATE" 2>/dev/null)" in
  live)     echo '[{"name":"WAYLAND-1"}]' ;;
  closed)   echo '[{"name":"FALLBACK"}]' ;;
  silent)   exit 1 ;;                       # hyprctl failing to answer
  *)        echo '[]' ;;
esac
STUB
chmod +x "$WORK/bin/hyprctl"
export PATH="$WORK/bin:$PATH"
export WD_LOG="$WORK/dispatch.log" WD_STATE="$WORK/state"

# A process for the watchdog to watch, and a runtime dir laid out like Hyprland's.
start_session() { # start_session <state>; sets FAKE_PID
  : > "$WD_LOG"; echo "$1" > "$WD_STATE"
  rm -rf "$WORK/run"; mkdir -p "$WORK/run/hypr/inst_1"
  sleep 300 >/dev/null 2>&1 &
  FAKE_PID=$!
  PIDS+=("$FAKE_PID")
  echo "$FAKE_PID wayland-9" > "$WORK/run/hypr/inst_1/hyprland.lock"
}

watchdog() { XDG_RUNTIME_DIR="$WORK/run" "$TOOL" --watch-close "$FAKE_PID" >/dev/null 2>&1 & WD=$!; PIDS+=("$WD"); }
exited()   { grep -q 'dispatch exit' "$WD_LOG" 2>/dev/null && echo yes || echo no; }
alive()    { kill -0 "$FAKE_PID" 2>/dev/null && echo yes || echo no; }

is() { local d="$1" want="$2" got="$3"
       if [[ $got == "$want" ]]; then ok "$d"
       else nope "$d"; printf '        wanted: %q\n        got:    %q\n' "$want" "$got"; fi; }

printf '\n\033[1;34m== it must NOT fire while the window is open\033[0m\n'
start_session live; watchdog; sleep 7
is "leaves a live session alone"              "no"  "$(exited)"
is "  and does not kill it"                   "yes" "$(alive)"

printf '\n\033[1;34m== it fires when the window closes\033[0m\n'
echo closed > "$WD_STATE"; sleep 7
is "ends the session once the window is gone" "yes" "$(exited)"
kill "$WD" 2>/dev/null

printf '\n\033[1;34m== it must NOT fire on a hyprctl hiccup\033[0m\n'
start_session live; watchdog; sleep 5
echo silent > "$WD_STATE"; sleep 7
is "a failed query is not a closed window"    "no"  "$(exited)"
is "  the session survives"                   "yes" "$(alive)"
kill "$WD" 2>/dev/null

printf '\n\033[1;34m== it must NOT fire before the window ever appears\033[0m\n'
# During startup there is a moment before the nested output exists. Acting there
# would kill the session as it came up.
start_session closed; watchdog; sleep 8
is "never armed, so never exits"              "no"  "$(exited)"
is "  the starting session survives"          "yes" "$(alive)"
kill "$WD" 2>/dev/null

printf '\n\033[1;34m== it gives up rather than guess\033[0m\n'
start_session live
rm -f "$WORK/run/hypr/inst_1/hyprland.lock"     # no instance claims this pid
XDG_RUNTIME_DIR="$WORK/run" timeout 60 "$TOOL" --watch-close "$FAKE_PID" >/dev/null 2>&1
is "unmatched pid: returns without dispatching" "no"  "$(exited)"
is "  and touches nothing"                      "yes" "$(alive)"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
