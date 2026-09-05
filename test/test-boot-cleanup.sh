#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove clean-stale-boot-entries.sh removes only what is safe to remove.
#
# Three things here were listed for every release as never run: `--delete`,
# `--archive` beyond a single machine, and the refusal when the bootloader still
# references a directory. That refusal is the one that matters - removing a
# referenced entry directory leaves a menu entry pointing at nothing.
#
# OC_ROOT prefixes /boot and the token files and shadows sudo, so the whole cycle
# runs against a fixture owned by whoever runs the tests.
#
#   ./test/test-boot-cleanup.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/clean-stale-boot-entries.sh"
LIVE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
has()  { local d="$1" pat="$2" hay="$3"
         if grep -qF -- "$pat" <<<"$hay"; then ok "$d"; else
           nope "$d"; printf '        wanted: %s\n' "$pat"; fi; }
hasnt() { local d="$1" pat="$2" hay="$3"
          if grep -qF -- "$pat" <<<"$hay"; then nope "$d"; else ok "$d"; fi; }
present() { local d="$1"; if [[ -d $2 ]]; then ok "$d"; else nope "$d ($2 is gone)"; fi; }
absent()  { local d="$1"; if [[ -d $2 ]]; then nope "$d ($2 is still there)"; else ok "$d"; fi; }

# A /boot shaped like kernel-install leaves it: one directory per entry token,
# each holding kernel payloads.
new_root() { # new_root [--reference-dead]
  local r tok
  r=$(mktemp -d)
  mkdir -p "$r/etc" "$r/boot/EFI/limine" "$r/home"
  printf '%s' "$LIVE" > "$r/etc/machine-id"
  for tok in "$LIVE" "$DEAD"; do
    mkdir -p "$r/boot/$tok/linux-cachyos"
    head -c 2048 /dev/zero > "$r/boot/$tok/linux-cachyos/vmlinuz"
    head -c 4096 /dev/zero > "$r/boot/$tok/linux-cachyos/initramfs"
  done
  # A 32-hex directory holding no kernel payload is not an entry directory.
  mkdir -p "$r/boot/cccccccccccccccccccccccccccccccc/notes"
  printf 'timeout: 5\n/+CachyOS\n  path: boot():/%s/linux-cachyos/vmlinuz#h\n' "$LIVE" \
    > "$r/boot/limine.conf"
  if [[ " $* " == *" --reference-dead "* ]]; then
    printf '  path: boot():/%s/linux-cachyos/vmlinuz#h\n' "$DEAD" >> "$r/boot/limine.conf"
  fi
  echo "$r"
}
# Every path this suite touches is built from a fixture root. A typo that left
# that root empty once made them resolve to the real /boot and /etc/machine-id,
# and only file permissions stopped it - so nothing runs until the root has been
# checked to be a real temporary directory.
fixture() { # fixture <path>
  [[ -n ${1:-} && $1 == /tmp/* && -d $1 && -d $1/boot ]] && return 0
  printf '\033[1;31mABORT\033[0m  refusing to run against %s\n' "${1:-<empty>}" >&2
  exit 99
}
run() { local r="$1"; shift; fixture "$r"
        OC_ROOT="$r" HOME="$r/home" OMARCHY_BOOT_ARCHIVE="$r/home/archive" \
          "$TOOL" "$@" 2>&1; }

printf '\n\033[1;34m== finding orphans\033[0m\n'

R=$(new_root)
out=$(run "$R")
has "reports the orphaned entry directory" "$DEAD" "$out"
hasnt "  and never lists the active one" "$LIVE  (" "$out"
hasnt "  nor a 32-hex directory holding no kernel" "cccccccccccccccccccccccccccccccc" "$out"
present "report mode leaves the orphan in place" "$R/boot/$DEAD"
present "  and the active entry untouched" "$R/boot/$LIVE"
rm -rf "$R"

# Nothing to do is not a failure.
R=$(new_root); fixture "$R"; rm -rf "${R:?}/boot/$DEAD"
out=$(run "$R"); rc=$?
has "says so when there is nothing orphaned" "Nothing to do" "$out"
if (( rc == 0 )); then ok "  and exits 0"; else nope "  but exited $rc"; fi
rm -rf "$R"

printf '\n\033[1;34m== refusing while the bootloader still points at it\033[0m\n'

# The guard that has never fired on a real machine.
R=$(new_root --reference-dead)
out=$(run "$R" --delete); rc=$?
has "warns that the config still references it" "still references $DEAD" "$out"
has "  and refuses to touch /boot" "refusing to modify" "$out"
if (( rc != 0 )); then ok "  exiting non-zero"; else nope "  but exited 0"; fi
present "  leaving the referenced directory exactly where it was" "$R/boot/$DEAD"
has "  and saying how to make it safe" "limine-update" "$out"
rm -rf "$R"

printf '\n\033[1;34m== archiving\033[0m\n'

R=$(new_root)
out=$(run "$R" --archive)
has "says it is safe to remove first" "Safe to remove" "$out"
absent "moves the orphan out of /boot" "$R/boot/$DEAD"
present "  into the archive directory" "$R/home/archive/$DEAD"
present "  and leaves the active entry alone" "$R/boot/$LIVE"
if [[ -f "$R/home/archive/$DEAD/linux-cachyos/initramfs" ]]; then
  ok "  with its contents intact, not just the directory"
else
  nope "  archived directory is missing its payload"
fi
rm -rf "$R"

printf '\n\033[1;34m== deleting\033[0m\n'

R=$(new_root)
run "$R" --delete >/dev/null
absent "removes the orphan outright" "$R/boot/$DEAD"
present "  and still leaves the active entry alone" "$R/boot/$LIVE"
if [[ -f "$R/boot/$LIVE/linux-cachyos/initramfs" ]]; then
  ok "  with the live kernel payload intact"
else
  nope "  the live payload was destroyed"
fi
rm -rf "$R"

printf '\n\033[1;34m== refusing to guess\033[0m\n'

# An empty token would make every directory look orphaned, including the live one.
R=$(new_root); fixture "$R"; : > "$R/etc/machine-id"
out=$(run "$R" --delete); rc=$?
has "refuses when the entry token is empty" "refusing to guess" "$out"
if (( rc != 0 )); then ok "  exiting non-zero"; else nope "  but exited 0"; fi
present "  and deletes nothing" "$R/boot/$DEAD"
present "  including the live entry" "$R/boot/$LIVE"
rm -rf "$R"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
