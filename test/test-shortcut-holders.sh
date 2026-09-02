#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove the shortcut borrow is reference counted correctly.
#
# More than one nested window can be open, and each needs the same Meta+ keys.
# Closing one used to hand every key back while the others were still using
# them. These tests pin down the rule that replaced it: the keys go back when
# the LAST holder lets go, and never before.
#
# No Plasma required. KDE's shortcut service is stubbed by putting a fake gdbus
# first on PATH, so the real script runs unmodified - no test-only branches in
# the code that has to work on a live desktop.
#
#   ./test/test-shortcut-holders.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/omarchy-window-shortcuts"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

# --- the stub -------------------------------------------------------------
# Answers only the four methods the script calls, in gdbus's GVariant text
# form. Overview is Meta+W alone; Walk Through Windows is Meta+Tab AND Alt+Tab,
# which is the case that must keep Alt+Tab.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gdbus" <<'STUB'
#!/bin/sh
method=""; prev=""; target=""
for a in "$@"; do
  [ "$prev" = "-m" ] && method="$a"
  case "$a" in *"'kwin'"*) target="$a" ;; esac
  prev="$a"
done
case "$method" in
  *.allMainComponents)      echo "([['kwin', 'KWin', '', '']],)" ;;
  *.allActionsForComponent) echo "([['kwin', 'Overview', 'KWin', 'Overview'], ['kwin', 'Walk Through Windows', 'KWin', 'WTW']],)" ;;
  *.shortcut)
      case "$target" in
        *Overview*) echo "([268435543],)" ;;      # Meta+W
        *)          echo "([285212673, 150994945],)" ;;  # Meta+Tab, Alt+Tab
      esac ;;
  *.setForeignShortcut) echo "$*" >> "${STUB_LOG:-/dev/null}"; echo "()" ;;
  *) echo "()" ;;
esac
STUB
chmod +x "$WORK/bin/gdbus"

export PATH="$WORK/bin:$PATH"
export OC_KDE_SHORTCUT_BACKUP="$WORK/backup.json"
export STUB_LOG="$WORK/dbus.log"

run() { "$TOOL" "$@" 2>&1; }
holders() { python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1])).get("holders") or []))
except Exception: print("-")' "$OC_KDE_SHORTCUT_BACKUP"; }
entries() { python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1]))["entries"]))
except Exception: print("-")' "$OC_KDE_SHORTCUT_BACKUP"; }
have_backup() { [[ -f $OC_KDE_SHORTCUT_BACKUP ]] && echo yes || echo no; }

# A real, live process to hold a claim with. It sets SPAWNED rather than echoing
# the pid: a command substitution waits for every process holding the pipe, so
# `$(sleep 300 & echo $!)` would block until the sleep finished. stdout is
# redirected for the same reason.
SPAWNED=""
spawn() {
  sleep 300 >/dev/null 2>&1 &
  SPAWNED=$!
  PIDS+=("$SPAWNED")
}

is() { local d="$1" want="$2" got="$3"
       if [[ $got == "$want" ]]; then ok "$d"
       else nope "$d"; printf '        wanted: %q\n        got:    %q\n' "$want" "$got"; fi; }

printf '\n\033[1;34m== one window\033[0m\n'
spawn; A=$SPAWNED
run suppress --claim "$A" >/dev/null
is "a claim creates the backup"            "yes" "$(have_backup)"
is "  with one holder"                     "1"   "$(holders)"
is "  and both actions recorded"           "2"   "$(entries)"

printf '\n\033[1;34m== a second window joins\033[0m\n'
spawn; B=$SPAWNED
out=$(run suppress --claim "$B")
is "joins instead of re-scanning"          "2"   "$(holders)"
is "  entries are untouched by the join"   "2"   "$(entries)"
if grep -q 'Joined an existing borrow' <<<"$out"; then ok "  and says so"; else nope "  and says so"; printf '        got: %s\n' "$out"; fi

printf '\n\033[1;34m== the bug this fixes\033[0m\n'
run restore --release "$A" >/dev/null
is "releasing one holder keeps the borrow" "yes" "$(have_backup)"
is "  leaving the other holder"            "1"   "$(holders)"

run restore --release "$B" >/dev/null
is "the LAST release hands the keys back"  "no"  "$(have_backup)"

printf '\n\033[1;34m== a killed session heals\033[0m\n'
spawn; C=$SPAWNED; run suppress --claim "$C" >/dev/null
kill "$C" 2>/dev/null; wait "$C" 2>/dev/null
spawn; D=$SPAWNED; run suppress --claim "$D" >/dev/null
is "a dead holder is pruned, not counted"  "1"   "$(holders)"
is "  and the originals are NOT re-scanned over" "2" "$(entries)"
run restore --release "$D" >/dev/null
is "  so the last live holder can finish"  "no"  "$(have_backup)"

printf '\n\033[1;34m== a recycled pid is not mistaken for the holder\033[0m\n'
spawn; E=$SPAWNED; run suppress --claim "$E" >/dev/null
python3 - "$OC_KDE_SHORTCUT_BACKUP" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
# Same pid, different start time - as a reused pid would look.
d["holders"] = [{"pid": d["holders"][0]["pid"], "start": "999999999"}]
json.dump(d, open(p, "w"))
PY
spawn; F=$SPAWNED; run suppress --claim "$F" >/dev/null
is "start-time mismatch drops the holder"  "1"   "$(holders)"

printf '\n\033[1;34m== the escape hatch\033[0m\n'
spawn; G=$SPAWNED; run suppress --claim "$G" >/dev/null
run restore >/dev/null
is "a bare restore ignores holders"        "no"  "$(have_backup)"

printf '\n\033[1;34m== a backup from before holder tracking\033[0m\n'
python3 - "$OC_KDE_SHORTCUT_BACKUP" <<'PY'
import json, sys
json.dump({"version": 1, "saved_at": "old",
           "entries": [{"id": ["kwin", "Overview", "", ""], "keys": [268435543], "kept": []}]},
          open(sys.argv[1], "w"))
PY
out=$(run status)
if grep -q 'before holder tracking' <<<"$out"; then
  ok "is reported as unknown, not as unheld"
else nope "is reported as unknown, not as unheld"; printf '        got: %s\n' "$out"; fi

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
