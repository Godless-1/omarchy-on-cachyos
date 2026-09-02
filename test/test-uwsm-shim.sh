#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove the uwsm-app shim runs the right command in the right environment.
#
# omarchy-window writes this shim into the nested session's PATH so that apps
# Omarchy launches stay in the nested compositor instead of being handed to
# wayland-wm-app-daemon.service, which carries the host session's environment.
#
# It is argument-parsing code standing between a keypress and exec, so a silent
# mistake here runs the wrong string as a command. The shim is extracted from
# omarchy-window itself rather than duplicated, so these tests fail if the real
# one drifts.
#
#   ./test/test-uwsm-shim.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SHIM="$WORK/uwsm-app"

# Lift the shim out of the heredoc in omarchy-window, and point its fallback at
# a marker so delegation is observable.
sed -n "/^cat > \"\$SHIMDIR\/uwsm-app\" <<'SHIM'\$/,/^SHIM\$/p" "$HERE/omarchy-window" \
  | sed '1d;$d' > "$SHIM"
sed -i "s|@REAL_UWSM@|/bin/echo DELEGATED|" "$SHIM"
chmod +x "$SHIM"

if [[ ! -s $SHIM ]]; then
  nope "could not extract the shim from omarchy-window"
  printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"; exit 1
fi

is()  { local d="$1" want="$2" got="$3"
        if [[ $got == "$want" ]]; then ok "$d"
        else nope "$d"; printf '        wanted: %q\n        got:    %q\n' "$want" "$got"; fi; }

printf '\n\033[1;34m== the shim is portable\033[0m\n'
if sh -n "$SHIM" 2>/dev/null; then ok "parses as POSIX sh (it runs under /bin/sh)"
else nope "does not parse as POSIX sh"; fi

printf '\n\033[1;34m== the forms Omarchy actually uses\033[0m\n'
is "runs a plain command"                "hi"                      "$("$SHIM" -- echo hi)"
is "keeps the command's own flags"       "nautilus --new-window"   "$("$SHIM" -- echo nautilus --new-window)"
is "skips uwsm options and their values" "x"                       "$("$SHIM" -s a -- echo x)"
is "splits on the FIRST -- only"         "discord --url -- x"      "$("$SHIM" -- echo discord --url -- x)"
is "passes a terminal invocation whole" \
   "xdg-terminal-exec --app-id=org.omarchy.agent -e claude --permission-mode auto" \
   "$("$SHIM" -- echo xdg-terminal-exec --app-id=org.omarchy.agent -e claude --permission-mode auto)"

printf '\n\033[1;34m== it refuses to guess\033[0m\n'
# Without a "--" anchor, "-s a" is ambiguous: "a" is an option value, not a
# command. Guessing would exec it. Delegating is the only safe answer.
is "delegates a form it cannot parse"    "DELEGATED -s a"          "$("$SHIM" -s a 2>&1)"
is "launches nothing for ping"           ""                        "$("$SHIM" ping)"
is "launches nothing for stop"           ""                        "$("$SHIM" stop)"
is "launches nothing for a bare --"      ""                        "$("$SHIM" --)"

printf '\n\033[1;34m== the whole point: the nested environment survives\033[0m\n'
# shellcheck disable=SC2016  # the inner sh must expand these, not this shell
got=$(WAYLAND_DISPLAY=wayland-9 HYPRLAND_INSTANCE_SIGNATURE=nested \
        "$SHIM" -- sh -c 'echo "$WAYLAND_DISPLAY/$HYPRLAND_INSTANCE_SIGNATURE"')
is "the command inherits the caller's compositor" "wayland-9/nested" "$got"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
