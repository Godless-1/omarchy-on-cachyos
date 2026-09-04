#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove block-omarchy-updates.sh can be undone.
#
# `--undo` is the escape hatch the documentation points at more than any other,
# and until this file existed nobody had run it: PROVENANCE listed it under "what
# was not tested" from the first release. It replaces system binaries, so the one
# thing it must never do is fail to put them back.
#
# OC_ROOT prefixes every path and shadows sudo, so the whole cycle runs against a
# fixture tree owned by whoever runs the tests.
#
#   ./test/test-block-undo.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/block-omarchy-updates.sh"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
same() { local d="$1" a="$2" b="$3"
         if [[ $a == "$b" ]]; then ok "$d"; else nope "$d ($a != $b)"; fi; }

# A tree shaped like a real install: two commands in /usr/bin, two symlinks to
# them under /usr/share/omarchy/bin, and a pacman.conf carrying the installer's
# guards block - the NoExtract entries are inserted inside it.
new_root() { # new_root [--no-guards-block]
  local r; r=$(mktemp -d)
  mkdir -p "$r"/usr/bin "$r"/usr/share/omarchy/bin "$r"/usr/share/libalpm/hooks \
           "$r"/etc "$r"/usr/local/share
  printf '#!/bin/bash\necho REAL omarchy-update "$@"\n'         > "$r/usr/bin/omarchy-update"
  printf '#!/bin/bash\necho REAL omarchy-refresh-pacman "$@"\n' > "$r/usr/bin/omarchy-refresh-pacman"
  chmod +x "$r/usr/bin/omarchy-update" "$r/usr/bin/omarchy-refresh-pacman"
  ln -sf "$r/usr/bin/omarchy-update"         "$r/usr/share/omarchy/bin/omarchy-update"
  ln -sf "$r/usr/bin/omarchy-refresh-pacman" "$r/usr/share/omarchy/bin/omarchy-refresh-pacman"
  if [[ ${1:-} == --no-guards-block ]]; then
    printf '[options]\nHoldPkg = pacman glibc\n' > "$r/etc/pacman.conf"
  else
    printf '[options]\n# --- omarchy-on-cachyos guards (do not remove) ---\nNoExtract = etc/x\n# --- end omarchy-on-cachyos guards ---\nHoldPkg = pacman glibc\n' \
      > "$r/etc/pacman.conf"
  fi
  echo "$r"
}
run()  { OC_ROOT="$1" "$TOOL" "${@:2}" 2>&1; }
# A fingerprint of the whole tree: contents, modes and symlink targets.
snap() { find "$1" -mindepth 1 \( -type f -o -type l \) -printf '%P %y %l %m\n' -exec sh -c \
           'for f; do [ -f "$f" ] && md5sum "$f"; done' _ {} + 2>/dev/null | sort; }
guards() { grep -lc OMARCHY-BLOCKED-GUARD "$1"/usr/bin/omarchy-* \
             "$1"/usr/share/omarchy/bin/omarchy-* 2>/dev/null | wc -l; }
noextract() { grep -cE '^NoExtract = usr/(bin|share)/' "$1/etc/pacman.conf" 2>/dev/null || true; }

printf '\n\033[1;34m== blocking\033[0m\n'

R=$(new_root)
before=$(md5sum "$R/usr/bin/omarchy-update" | cut -d' ' -f1)
out=$(run "$R"); rc=$?
if (( rc == 0 )); then ok "block succeeds against a fixture tree"
else nope "block exited $rc"; printf '        %s\n' "$(tail -3 <<<"$out")"; fi
same "guards replace all four commands" "$(guards "$R")" "4"
same "five NoExtract entries added" "$(noextract "$R")" "5"
if [[ -f "$R/usr/local/share/omarchy-blocked/usr_bin_omarchy-update" ]]; then
  ok "the vault is keyed by the logical path, not the fixture path"
else
  nope "vault key wrong: $(find "$R/usr/local/share/omarchy-blocked" -type f -printf '%P ' 2>/dev/null)"
fi
same "the vaulted original is byte-identical to what was there" \
  "$(md5sum "$R/usr/local/share/omarchy-blocked/usr_bin_omarchy-update" | cut -d' ' -f1)" "$before"
if grep -q BLOCKED <<<"$(run "$R" --status)"; then ok "--status reports it blocked"
else nope "--status does not say BLOCKED"; fi

printf '\n\033[1;34m== undoing\033[0m\n'

out=$(run "$R" --undo); rc=$?
if (( rc == 0 )); then ok "undo succeeds"
else nope "undo exited $rc"; printf '        %s\n' "$(tail -3 <<<"$out")"; fi
same "the original command is restored byte-identical" \
  "$(md5sum "$R/usr/bin/omarchy-update" | cut -d' ' -f1)" "$before"
same "no guard survives anywhere" "$(guards "$R")" "0"
same "every NoExtract entry is removed" "$(noextract "$R")" "0"
if "$R/usr/bin/omarchy-update" 2>/dev/null | grep -q '^REAL'; then
  ok "the restored command runs and is the real one"
else
  nope "the restored command does not run"
fi
if grep -q 'omarchy-on-cachyos guards' "$R/etc/pacman.conf"; then
  ok "undo leaves the installer's guards block itself alone"
else
  nope "undo removed the guards block, not just its entries"
fi
rm -rf "$R"

printf '\n\033[1;34m== block twice, undo once\033[0m\n'

# The second block must not stash a guard over the vaulted original - that would
# make undo restore a guard and lock the commands out for good.
R=$(new_root)
before=$(md5sum "$R/usr/bin/omarchy-update" | cut -d' ' -f1)
run "$R" >/dev/null; run "$R" >/dev/null
same "a second block leaves the vaulted original intact" \
  "$(md5sum "$R/usr/local/share/omarchy-blocked/usr_bin_omarchy-update" | cut -d' ' -f1)" "$before"
run "$R" --undo >/dev/null
same "  so undo still restores the real command" \
  "$(md5sum "$R/usr/bin/omarchy-update" | cut -d' ' -f1)" "$before"
rm -rf "$R"

printf '\n\033[1;34m== dry runs change nothing\033[0m\n'

R=$(new_root); s0=$(snap "$R")
run "$R" --dry-run >/dev/null
same "--dry-run leaves the tree untouched" "$(snap "$R")" "$s0"
run "$R" --undo --dry-run >/dev/null
same "--undo --dry-run leaves the tree untouched" "$(snap "$R")" "$s0"
rm -rf "$R"

printf '\n\033[1;34m== refusing rather than half-doing\033[0m\n'

# Without the installer's guards block there is nothing to insert the NoExtract
# entries into. This used to print "added" five times and then fail.
R=$(new_root --no-guards-block); s0=$(snap "$R")
out=$(run "$R"); rc=$?
if (( rc != 0 )); then ok "refuses when the guards block is missing"
else nope "proceeded without a guards block"; fi
if grep -q 'added:' <<<"$out"; then
  nope "claimed entries were added when none could be"
else
  ok "  and does not claim to have added anything"
fi
same "  and changes nothing" "$(snap "$R")" "$s0"
rm -rf "$R"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
