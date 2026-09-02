#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove the systemd-run shim keeps apps in the nested session, and keeps its
# hands off everything else.
#
# omarchy-launch-browser spells the launch `systemd-run --user ... uwsm-app --
# firefox`, so the unit is created - carrying the user manager's environment,
# meaning the HOST session's - before the uwsm-app shim is ever consulted. The
# shim runs those commands in place instead.
#
# The dangerous half is what it must NOT touch. Omarchy schedules
#   systemd-run --user --on-active=2s systemctl poweroff
# and running that here rather than handing it to systemd would power the
# machine off immediately instead of in two seconds. Those tests matter more
# than the rest of the file put together.
#
#   ./test/test-systemd-run-shim.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SHIM="$WORK/systemd-run"

# Lift the shim out of omarchy-window rather than copying it, so these tests
# fail if the real one drifts. Its passthrough target becomes a marker.
sed -n "/^cat > \"\$SHIMDIR\/systemd-run\" <<'SHIM'\$/,/^SHIM\$/p" "$HERE/omarchy-window" \
  | sed '1d;$d' > "$SHIM"
sed -i "s|@REAL_SDRUN@|/bin/echo PASSED-THROUGH|g" "$SHIM"
chmod +x "$SHIM"

if [[ ! -s $SHIM ]]; then
  nope "could not extract the shim from omarchy-window"
  printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"; exit 1
fi

is() { local d="$1" want="$2" got="$3"
       if [[ $got == "$want" ]]; then ok "$d"
       else nope "$d"; printf '        wanted: %q\n        got:    %q\n' "$want" "$got"; fi; }

printf '\n\033[1;34m== it is portable\033[0m\n'
if sh -n "$SHIM" 2>/dev/null; then ok "parses as POSIX sh"; else nope "does not parse as POSIX sh"; fi

printf '\n\033[1;34m== TIMERS MUST REACH THE REAL systemd-run\033[0m\n'
# If any of these run the command in place, a scheduled poweroff becomes an
# immediate one.
is "a --on-active poweroff is handed over" \
   "PASSED-THROUGH --user --collect --quiet --on-active=2s systemctl poweroff --no-wall" \
   "$("$SHIM" --user --collect --quiet --on-active=2s systemctl poweroff --no-wall)"
is "  so is a --on-active reboot" \
   "PASSED-THROUGH --user --on-active=2s systemctl reboot" \
   "$("$SHIM" --user --on-active=2s systemctl reboot)"
is "  so is a --on-calendar job" \
   "PASSED-THROUGH --user --on-calendar=daily true" \
   "$("$SHIM" --user --on-calendar=daily true)"
is "  so is --timer-property" \
   "PASSED-THROUGH --user --timer-property=AccuracySec=1s --on-active=5m true" \
   "$("$SHIM" --user --timer-property=AccuracySec=1s --on-active=5m true)"
is "  and a --scope is left alone too" \
   "PASSED-THROUGH --user --scope true" \
   "$("$SHIM" --user --scope true)"

printf '\n\033[1;34m== a system-wide unit is not ours either\033[0m\n'
is "no --user means hand it over" \
   "PASSED-THROUGH --unit=x true" \
   "$("$SHIM" --unit=x true)"

printf '\n\033[1;34m== the launches it does take over\033[0m\n'
is "runs a plain --user service in place" "hi" \
   "$("$SHIM" --user --quiet --collect echo hi)"
is "  strips --unit= and --property=" "hello" \
   "$("$SHIM" --user --quiet --collect --unit=omarchy-browser-1 --property=StandardOutput=null echo hello)"
is "  keeps the command's own arguments" "firefox --new-window https://example.invalid" \
   "$("$SHIM" --user --quiet --collect echo firefox --new-window https://example.invalid)"
is "  honours an explicit --" "after" \
   "$("$SHIM" --user --quiet -- echo after)"

printf '\n\033[1;34m== it refuses to guess\033[0m\n'
# A short option that might swallow a separate value would make a guess here
# exec that value as a command.
is "an unknown short option is handed over" \
   "PASSED-THROUGH --user -p Foo=bar echo hi" \
   "$("$SHIM" --user -p Foo=bar echo hi)"
is "nothing to run exits quietly" "" "$("$SHIM" --user --quiet)"

printf '\n\033[1;34m== the whole point: the nested environment survives\033[0m\n'
# shellcheck disable=SC2016  # the inner sh must expand these, not this shell
got=$(WAYLAND_DISPLAY=wayland-9 HYPRLAND_INSTANCE_SIGNATURE=nested \
        "$SHIM" --user --quiet --collect sh -c 'echo "$WAYLAND_DISPLAY/$HYPRLAND_INSTANCE_SIGNATURE"')
is "the command inherits the caller's compositor" "wayland-9/nested" "$got"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
