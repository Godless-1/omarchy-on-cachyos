#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove the update check is honest, quiet, and cannot break a window opening.
#
# It runs on every nested-window start, so the properties that matter most are
# the negative ones: --notify must never touch the network, must never speak
# unless there is genuinely something newer, and must exit 0 no matter what it
# finds - a failed update check may not stop a desktop from starting.
#
# curl and pacman are stubbed on PATH, and HOME/XDG dirs point at a temp tree,
# so nothing here reaches the network or the installed system.
#
#   ./test/test-update-check.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/update-omarchy-on-cachyos.sh"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home"

# curl records that it was called, and answers with whatever the test staged.
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
echo called >> "$CURL_LOG"
[ -f "$CURL_BODY" ] || exit 22
cat "$CURL_BODY"
STUB
# pacman reports the version the test staged, so no real package is consulted.
cat > "$WORK/bin/pacman" <<'STUB'
#!/bin/sh
case "$1" in
  -Q) [ -n "${FAKE_INSTALLED:-}" ] && echo "omarchy-on-cachyos ${FAKE_INSTALLED}" || exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/curl" "$WORK/bin/pacman"

export PATH="$WORK/bin:$PATH"
export HOME="$WORK/home"
export XDG_CACHE_HOME="$WORK/home/.cache" XDG_CONFIG_HOME="$WORK/home/.config"
export CURL_LOG="$WORK/curl.log" CURL_BODY="$WORK/body.json"
CACHE="$XDG_CACHE_HOME/omarchy-cachyos/update.json"

stage_cache() { # stage_cache <latest> [age-seconds]
  mkdir -p "$(dirname "$CACHE")"
  python3 -c '
import json, sys, time
json.dump({"checked": int(time.time()) - int(sys.argv[2]), "latest": sys.argv[1],
           "asset": "https://example.invalid/p.pkg.tar.zst"}, open(sys.argv[3], "w"))' \
    "$1" "${2:-0}" "$CACHE"
}
stage_api() { printf '{"tag_name":"v%s","assets":[{"name":"x.pkg.tar.zst","browser_download_url":"https://example.invalid/x.pkg.tar.zst"}]}' "$1" > "$CURL_BODY"; }
reset() { : > "$CURL_LOG"; rm -f "$CACHE" "$CURL_BODY" "$XDG_CONFIG_HOME/omarchy-cachyos/no-update-check"; unset OMARCHY_OC_NO_UPDATE_CHECK; }
curl_calls() { wc -l < "$CURL_LOG" | tr -d ' '; }

is() { local d="$1" want="$2" got="$3"
       if [[ $got == "$want" ]]; then ok "$d"
       else nope "$d"; printf '        wanted: %q\n        got:    %q\n' "$want" "$got"; fi; }
has() { local d="$1" want="$2" got="$3"
        if grep -qF "$want" <<<"$got"; then ok "$d"
        else nope "$d"; printf '        wanted to contain: %s\n        got: %s\n' "$want" "$got"; fi; }

printf '\n\033[1;34m== --notify must never reach the network\033[0m\n'
reset; export FAKE_INSTALLED=1.0.0; stage_cache 9.9.9
out=$("$TOOL" --notify 2>&1)
is "no curl call at all"                    "0"  "$(curl_calls)"
has "  and it says a newer one is out"      "9.9.9" "$out"
has "  naming this project, not Omarchy"    "not Omarchy itself" "$out"

printf '\n\033[1;34m== --notify stays silent unless there is news\033[0m\n'
reset; stage_cache 1.0.0
is "silent when up to date"                 ""   "$("$TOOL" --notify 2>&1)"
reset; stage_cache 0.9.0
is "silent when the release is older"       ""   "$("$TOOL" --notify 2>&1)"
reset
is "silent with no cache at all"            ""   "$("$TOOL" --notify 2>&1)"
is "  still no network"                     "0"  "$(curl_calls)"

printf '\n\033[1;34m== it always exits 0, so a window always opens\033[0m\n'
reset; stage_cache 9.9.9
"$TOOL" --notify >/dev/null 2>&1; is "exit 0 with an update waiting" "0" "$?"
reset; "$TOOL" --notify >/dev/null 2>&1; is "exit 0 with no cache"    "0" "$?"
reset; printf 'not json' > "$CACHE"
"$TOOL" --notify >/dev/null 2>&1; is "exit 0 on a corrupt cache"      "0" "$?"

printf '\n\033[1;34m== opting out is respected\033[0m\n'
reset; stage_cache 9.9.9; export OMARCHY_OC_NO_UPDATE_CHECK=1
is "silent when disabled by an environment variable" "" "$("$TOOL" --notify 2>&1)"
unset OMARCHY_OC_NO_UPDATE_CHECK
mkdir -p "$XDG_CONFIG_HOME/omarchy-cachyos"; touch "$XDG_CONFIG_HOME/omarchy-cachyos/no-update-check"
is "silent when disabled by file"           ""   "$("$TOOL" --notify 2>&1)"

printf '\n\033[1;34m== --refresh writes the cache, and fails safely\033[0m\n'
reset; stage_api 2.0.0
"$TOOL" --refresh >/dev/null 2>&1
is "records the tag without its v"          "2.0.0" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["latest"])' "$CACHE" 2>/dev/null)"
reset; stage_cache 1.2.3          # no body staged: curl will fail
"$TOOL" --refresh >/dev/null 2>&1
is "a failed fetch leaves the old cache"    "1.2.3" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["latest"])' "$CACHE" 2>/dev/null)"
reset; stage_cache 1.2.3; printf 'garbage' > "$CURL_BODY"
"$TOOL" --refresh >/dev/null 2>&1
is "garbage JSON leaves the old cache"      "1.2.3" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["latest"])' "$CACHE" 2>/dev/null)"

printf '\n\033[1;34m== version ordering\033[0m\n'
reset; export FAKE_INSTALLED=1.4.3.9; stage_cache 1.4.3.10
has "1.4.3.10 is newer than 1.4.3.9"        "1.4.3.10" "$("$TOOL" --notify 2>&1)"
reset; export FAKE_INSTALLED=1.4.3.10; stage_cache 1.4.3.9
is "  and not the other way round"          ""   "$("$TOOL" --notify 2>&1)"
reset; export FAKE_INSTALLED=1.4.3.3-1; stage_cache 1.4.3.3
is "pkgrel does not read as newer"          ""   "$("$TOOL" --notify 2>&1)"

printf '\n\033[1;34m== --install refuses to act without cause\033[0m\n'
reset; export FAKE_INSTALLED=2.0.0; stage_cache 1.0.0; stage_api 2.0.0
has "says nothing to do after a live check" "nothing to install" "$("$TOOL" --install 2>&1)"
is "explicit install checks even a fresh cache" "1" "$(curl_calls)"
reset; export FAKE_INSTALLED=1.4.6; stage_cache 1.4.6
printf '{"tag_name":"v1.4.7","assets":[]}' > "$CURL_BODY"
out=$("$TOOL" --install --no-restart 2>&1); rc=$?
has "discovers 1.4.7 despite fresh 1.4.6 cache" "Release v1.4.7 has no package" "$out"
is "refuses missing package without installing" "1" "$rc"
reset; stage_cache 1.4.6
out=$("$TOOL" --install 2>&1); rc=$?
is "network failure fails the explicit upgrade" "1" "$rc"
has "does not mistake stale data for current" "Could not check GitHub" "$out"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
