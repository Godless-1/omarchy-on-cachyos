#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove the browser launcher shim runs the right browser with the right flags.
#
# Fixing the environment is not enough for a browser: it is single-instance, so
# a second invocation just signals the copy already running on the host, and
# that process is connected to the host's compositor. The only cure is a
# genuinely separate instance, which means a separate profile.
#
# omarchy-launch-browser also reads Exec= out of the .desktop file and runs the
# ABSOLUTE path (/usr/lib/firefox/firefox), which no PATH shim can intercept -
# so the launcher itself is shimmed instead.
#
#   ./test/test-browser-shim.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SHIM="$WORK/omarchy-launch-browser"

# Lift it out of omarchy-window rather than restating it, so these fail if the
# real one drifts. The browser becomes a marker that echoes its arguments.
sed -n "/cat > \"\$SHIMDIR\/omarchy-launch-browser\" <<'BSHIM'\$/,/^BSHIM\$/p" "$HERE/omarchy-window" \
  | sed '1d;$d' > "$SHIM"

if [[ ! -s $SHIM ]]; then
  nope "could not extract the shim from omarchy-window"
  printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"; exit 1
fi

build() { # build <priv-flag> <isolate-flags>
  sed -e "s|@PRIV@|$1|" -e "s|@BROWSER@|/bin/echo|" -e "s|@ISOLATE@|$2|" "$SHIM" > "$WORK/run"
  chmod +x "$WORK/run"
}

is() { local d="$1" want="$2" got="$3"
       if [[ $got == "$want" ]]; then ok "$d"
       else nope "$d"; printf '        wanted: %q\n        got:    %q\n' "$want" "$got"; fi; }

printf '\n\033[1;34m== it is portable\033[0m\n'
build --private-window "--new-instance --profile /tmp/p"
if sh -n "$WORK/run" 2>/dev/null; then ok "parses as POSIX sh"; else nope "does not parse as POSIX sh"; fi

printf '\n\033[1;34m== firefox-family isolation\033[0m\n'
is "always passes the profile flags" \
   "--new-instance --profile /tmp/p" "$("$WORK/run")"
is "  keeps a URL argument" \
   "--new-instance --profile /tmp/p https://example.invalid" \
   "$("$WORK/run" https://example.invalid)"
is "  translates --private to the firefox spelling" \
   "--new-instance --profile /tmp/p --private-window" "$("$WORK/run" --private)"
is "  translates --private among other arguments, in order" \
   "--new-instance --profile /tmp/p --private-window https://example.invalid" \
   "$("$WORK/run" --private https://example.invalid)"
is "  leaves other flags alone" \
   "--new-instance --profile /tmp/p --kiosk" "$("$WORK/run" --kiosk)"

printf '\n\033[1;34m== chromium-family isolation\033[0m\n'
build --incognito "--user-data-dir=/tmp/c"
is "uses its own data dir" "--user-data-dir=/tmp/c" "$("$WORK/run")"
is "  and its own private-mode spelling" \
   "--user-data-dir=/tmp/c --incognito" "$("$WORK/run" --private)"

printf '\n\033[1;34m== a profile path with spaces survives\033[0m\n'
build --private-window "--new-instance --profile /tmp/two\\ words"
is "quoting holds" "--new-instance --profile /tmp/two words" "$("$WORK/run")"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
