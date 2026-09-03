#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove the installer survives the mirrors on its own.
#
# The install that prompted this stopped fifteen minutes in, with 22 of 23
# packages downloaded, because one CDN reset a stream and one mirror answered
# 404 for a file the local database still listed. Nothing was wrong with the
# machine and nothing needed deciding - but pacman rolled the transaction back,
# and the only way on was a human noticing and re-running the script.
#
# So: a download failure is retried, a 404 forces a database refresh first, a
# corrupted cache file is thrown away rather than fetched into forever, and a
# failure that is NOT about downloading stops at once instead of being asked
# four times.
#
# pac() is lifted out of the installer and driven against a scripted pacman, so
# no package, mirror or /var/cache is touched.
#
#   ./test/test-pacman-retry.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/install-omarchy-on-cachyos.sh"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
is() { local d="$1" want="$2" got="$3"
       if [[ $got == "$want" ]]; then ok "$d"
       else nope "$d"; printf '        wanted: %q\n        got:    %q\n' "$want" "$got"; fi; }
has() { local d="$1" want="$2" got="$3"
        if grep -qF -- "$want" <<<"$got"; then ok "$d"
        else nope "$d"; printf '        wanted to contain: %s\n        got: %s\n' "$want" "$got"; fi; }
hasnt() { local d="$1" bad="$2" got="$3"
          if grep -qF -- "$bad" <<<"$got"; then nope "$d"; printf '        should not contain: %s\n' "$bad"
          else ok "$d"; fi; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# ---- the harness: the real pac(), with the installer's scaffolding stubbed --
# die exits 9, so a test can tell "gave up on the mirrors" from "pacman said no".
cat > "$WORK/pac.sh" <<'STUB'
set -uo pipefail
DRYRUN=${DRYRUN:-0}
DB_URL=https://example.invalid/x86_64
SELF_ARGS=()
warn() { printf 'warn: %s\n' "$*"; }
die()  { printf 'die: %s\n' "$@" >&2; exit 9; }
STUB
{
  grep -E '^(PAC_TRIES|PAC_BACKOFF|PAC_TRANSIENT)=' "$TOOL"
  grep -E '^declare -a PAC_OPTS=' "$TOOL"
  awk '/^pac\(\) \{/ {p=1} p {print} p && /^\}/ {exit}' "$TOOL"
  printf 'pac "$@"\n'
} >> "$WORK/pac.sh"

# sudo runs what it is handed, except that an rm is only recorded - a test that
# can really delete out of /var/cache/pacman/pkg is a test nobody should run.
cat > "$WORK/bin/sudo" <<'STUB'
#!/bin/sh
case "$1" in
  rm) shift; echo "rm $*" >> "$SUDO_RM_LOG"; exit 0 ;;
esac
exec "$@"
STUB
# pacman answers from a scenario file: one line per transaction attempt, "ok"
# to succeed, anything else printed to stderr as that attempt's failure. A -Syy
# refresh is not an attempt; it is recorded separately and always works.
cat > "$WORK/bin/pacman" <<'STUB'
#!/bin/sh
echo "$*" >> "$PACMAN_LOG"
case " $* " in
  *" -Syy "*) echo refresh >> "$REFRESH_LOG"; exit 0 ;;
esac
echo attempt >> "$ATTEMPT_LOG"
line=$(sed -n "$(wc -l < "$ATTEMPT_LOG")p" "$SCENARIO")
[ -n "$line" ] || line=ok
[ "$line" = ok ] && exit 0
printf '%s\n' "$line" >&2
exit 1
STUB
chmod +x "$WORK/bin/sudo" "$WORK/bin/pacman"

export PATH="$WORK/bin:$PATH"
export PACMAN_LOG="$WORK/pacman.log" ATTEMPT_LOG="$WORK/attempts.log"
export REFRESH_LOG="$WORK/refresh.log" SUDO_RM_LOG="$WORK/rm.log"
export SCENARIO="$WORK/scenario"
export PAC_BACKOFF=0            # the waiting is not what is under test

CACHED=/var/cache/pacman/pkg/omarchy-4.0.2-1-any.pkg.tar.zst
E404="error: failed retrieving file 'omarchy-4.0.2-1-any.pkg.tar.zst' from mirror.example : The requested URL returned error: 404"
ERESET="error: failed retrieving file 'omarchy-4.0.2-1-any.pkg.tar.zst' from pkgs.omarchy.org : HTTP/2 stream 1 reset by server (error 0x2 INTERNAL_ERROR)"
ECORRUPT="error: 'omarchy-4.0.2-1-any.pkg.tar.zst': invalid or corrupted package (PGP signature)"
ECORRUPTF="error: '$CACHED': invalid or corrupted package (PGP signature)"
ETARGET="error: target not found: omarhcy"
ECONFLICT="error: failed to commit transaction (conflicting files)"

# try <outcome>... - one scenario line per attempt. Leaves RC, OUT, ATTEMPTS,
# REFRESHES and RMS behind.
try() {
  : > "$PACMAN_LOG"; : > "$ATTEMPT_LOG"; : > "$REFRESH_LOG"; : > "$SUDO_RM_LOG"
  printf '%s\n' "$@" > "$SCENARIO"
  OUT=$(bash "$WORK/pac.sh" -S --needed omarchy 2>&1); RC=$?
  ATTEMPTS=$(wc -l < "$ATTEMPT_LOG" | tr -d ' ')
  REFRESHES=$(wc -l < "$REFRESH_LOG" | tr -d ' ')
  RMS=$(cat "$SUDO_RM_LOG")
}

printf '\n\033[1;34m== a mirror that fails mid-download is asked again\033[0m\n'
try "$ERESET" ok
is  "the transaction succeeds on the retry"     "0" "$RC"
is  "  exactly one retry, not a loop"           "2" "$ATTEMPTS"
is  "  no database refresh for a reset stream"  "0" "$REFRESHES"
has "  and it says so while it happens" "download failure (attempt 1 of" "$OUT"

printf '\n\033[1;34m== a 404 refreshes the databases first\033[0m\n'
try "$E404" ok
is  "recovers"                                  "0" "$RC"
is  "  forces exactly one -Syy before retrying" "1" "$REFRESHES"
has "  and explains why"            "out of step with the local databases" "$OUT"

printf '\n\033[1;34m== a corrupted download is discarded, not fetched into forever\033[0m\n'
try "$ECORRUPTF" ok
is  "recovers"                            "0" "$RC"
has "  deletes the file pacman named"     "rm -f $CACHED" "$RMS"
has "  and its detached signature"        "$CACHED.sig" "$RMS"
try "$ECORRUPT" ok
is    "stops when pacman names no file to delete"    "9" "$RC"
is    "  having deleted nothing it was not told to" "" "$RMS"

printf '\n\033[1;34m== a failure that is not about downloading stops at once\033[0m\n'
for e in "$ETARGET" "$ECONFLICT"; do
  try "$e" ok
  is "one attempt only for: ${e:7:34}..." "9 1" "$RC $ATTEMPTS"
done
has "  and it says why it will not retry" "not over a download" "$OUT"

printf '\n\033[1;34m== it gives up eventually, and says how to resume\033[0m\n'
tries=$(grep -oE '^PAC_TRIES=.*:-[0-9]+' "$TOOL" | grep -oE '[0-9]+$')
try "$ERESET" "$ERESET" "$ERESET" "$ERESET" "$ERESET" "$ERESET"
is  "stops instead of retrying forever"            "9" "$RC"
is  "  after exactly PAC_TRIES ($tries) attempts"  "$tries" "$ATTEMPTS"
has "  and a re-run picks up where it left off"    "a re-run resumes" "$OUT"
has "  nothing was left half-installed"            "rolled back whole" "$OUT"

printf '\n\033[1;34m== every transaction is unattended and patient\033[0m\n'
try ok
has "--noconfirm: no question waits on a human" "--noconfirm" "$(cat "$PACMAN_LOG")"
has "--disable-download-timeout: slow is not dead" \
    "--disable-download-timeout" "$(cat "$PACMAN_LOG")"

printf '\n\033[1;34m== --dry-run still touches nothing\033[0m\n'
: > "$PACMAN_LOG"; : > "$ATTEMPT_LOG"; printf 'ok\n' > "$SCENARIO"
OUT=$(DRYRUN=1 bash "$WORK/pac.sh" -S --needed omarchy 2>&1); RC=$?
is  "exits 0"                            "0" "$RC"
is  "  never runs pacman"                "" "$(cat "$PACMAN_LOG")"
has "  prints the transaction it would run" "[dry-run] sudo pacman" "$OUT"

printf '\n\033[1;34m== no transaction bypasses the retry wrapper\033[0m\n'
stray=$(grep -nE '^[[:space:]]*(run )?sudo pacman -' "$TOOL" | grep -v 'PAC_OPTS')
hasnt "every -S/-U in the installer goes through pac()" "sudo pacman" "$stray"

printf '\n'
if (( FAIL )); then printf '\033[1;31m%d failed\033[0m, %d passed\n\n' "$FAIL" "$PASS"; exit 1; fi
printf '\033[1;32mall %d checks passed\033[0m\n\n' "$PASS"
