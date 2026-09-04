#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove clean-stale-boot-entries.sh can tell a live limine entry from an
# abandoned one, and refuses when it cannot.
#
# This is the fault that took a real machine's boot menu apart: two top-level
# entries for one installation, the one still carrying the distribution's own
# name being the dead one. Choosing wrongly here removes the entry that boots,
# so every case that cannot be decided must refuse rather than guess.
#
# OC_LIMINE_CONF and OC_MACHINE_ID run the analysis against a fixture, with no
# sudo and no /boot.
#
#   ./test/test-boot-entry-orphans.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/clean-stale-boot-entries.sh"
MID=1c0f28fab0c443338dde8610e5e938b7
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
has()  { local d="$1" pat="$2" hay="$3"
         if grep -qF -- "$pat" <<<"$hay"; then ok "$d"; else
           nope "$d"; printf '        wanted: %s\n' "$pat"
           printf '        got:\n'; awk '{ print "          " $0 }' <<<"$hay" | head -12; fi; }
hasnt() { local d="$1" pat="$2" hay="$3"
          if grep -qF -- "$pat" <<<"$hay"; then
            nope "$d"; awk '{ print "          " $0 }' <<<"$hay" | head -12; else ok "$d"; fi; }

run() { OC_LIMINE_CONF="$1" OC_MACHINE_ID="$MID" "$TOOL" 2>&1; }

# One top-level OS entry, shaped like the real file: kernels plus an indented
# Snapshots sub-tree whose children all load from the same machine directory.
os_entry() { # os_entry <name> <newest-snapshot> [comment-before|comment-inside]
  local name="$1" snap="$2" where="${3:-comment-inside}"
  [[ $where == comment-before ]] && printf 'comment: machine-id=%s\n' "$MID"
  printf '/+%s\n' "$name"
  [[ $where == comment-inside ]] && printf 'comment: machine-id=%s order-priority=50 \n' "$MID"
  printf '  //linux-cachyos\n  path: boot():/%s/linux-cachyos/vmlinuz#h\n' "$MID"
  printf '     //Snapshots\n'
  printf '     ///%d | snap\n     path: boot():/%s/limine_history/v#h\n' "$snap" "$MID"
  printf '     ///%d | older\n     path: boot():/%s/limine_history/v#h\n' "$((snap - 1))" "$MID"
}
# The parts of a real config that are not this machine and must never be counted.
others() {
  printf '/+Other systems and bootloaders\n//Windows Boot Manager\n'
  printf '        image_path: guid(DE1D-11C6):/efi/Microsoft/Boot/bootmgfw.efi\n'
  printf '/EFI fallback\nprotocol: efi\npath: boot():/EFI/BOOT/BOOTX64.EFI\n'
}

T=$(mktemp -d)

printf '\n\033[1;34m== telling live from abandoned\033[0m\n'

# The real failure, reproduced: the entry named after the distribution is the dead
# one, and the oddly-named entry is the one that boots.
{ printf 'timeout: 5\n\n'; os_entry CachyOS 235 comment-before; others
  os_entry "Arch Linux" 279; } > "$T/dup.conf"
out=$(run "$T/dup.conf")
has "reports both entries claiming one machine" "2 top-level entries claim this machine" "$out"
has "picks the entry with the newest snapshot as live" "Live: 'Arch Linux' (snapshot 279)" "$out"
has "names the frozen entry as stale, whatever it is called" "Stale: 'CachyOS' (snapshot 235)" "$out"
has "quotes the removal command by name, not by position" \
  "sudo limine-remove-entry 'CachyOS'" "$out"
hasnt "never suggests the machine-ID-and-position form" "limine-remove-entry $MID" "$out"
has "tells you to regenerate afterwards" "sudo limine-update" "$out"

# Names must match what --tree prints, because that is what the removal takes.
hasnt "strips the /+ marker from entry names" "'/+CachyOS'" "$out"

printf '\n\033[1;34m== leaving a healthy machine alone\033[0m\n'

{ printf 'timeout: 5\n\n'; os_entry CachyOS 279; others; } > "$T/one.conf"
out=$(run "$T/one.conf")
has "reports a single entry plainly" "One boot entry claims this machine: CachyOS" "$out"
hasnt "raises nothing on a healthy config" "top-level entries claim this machine" "$out"

# An unrelated bootloader and the EFI fallback are not this machine's entries.
{ printf 'timeout: 5\n\n'; others; } > "$T/none.conf"
out=$(run "$T/none.conf")
has "says so when no entry claims this machine" "No top-level entry in" "$out"
hasnt "does not invent a live entry from a chainloaded OS" "Live:" "$out"

printf '\n\033[1;34m== refusing to guess\033[0m\n'

# Equal newest snapshots: nothing distinguishes them, and a wrong choice removes
# the entry that still boots.
{ printf 'timeout: 5\n\n'; os_entry CachyOS 300; others; os_entry "Arch Linux" 300; } > "$T/tie.conf"
out=$(run "$T/tie.conf")
has "refuses when both entries stop at the same snapshot" "Cannot tell which is live" "$out"
hasnt "  and picks neither" "Stale:" "$out"
has "  points at the tool that can show the difference" "limine-entry-tool --tree" "$out"

# --remove-stale-entry must not act on an undecidable config either.
out=$(OC_LIMINE_CONF="$T/tie.conf" OC_MACHINE_ID="$MID" "$TOOL" --remove-stale-entry 2>&1)
has "refuses the removal flag on a tie as well" "Cannot tell which is live" "$out"
hasnt "  and runs no removal" "Removing '" "$out"

rm -rf "$T"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
