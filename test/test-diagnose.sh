#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove the diagnostics detect faults, by building fake system trees.
#
# A checker only ever run against a healthy machine is untested. omarchy-on-cachyos
# routes every filesystem probe through _p(), which prefixes OC_ROOT when set - so a
# fault can be simulated in a temp directory with no root, no bubblewrap, and no risk
# to the machine running the tests.
#
#   ./test/test-diagnose.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/omarchy-on-cachyos"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

# A minimal tree that looks like a healthy, fully-guarded install.
new_root() {
  local r; r=$(mktemp -d)
  mkdir -p "$r"/etc/{mkinitcpio.conf.d,fastfetch,kernel} \
           "$r"/usr/{bin,share/wayland-sessions} \
           "$r"/usr/share/libalpm/hooks \
           "$r"/usr/local/share/omarchy-blocked \
           "$r"/boot
  touch "$r/INSTALLED"
  printf '[options]\n# --- omarchy-on-cachyos guards (do not remove) ---\nNoExtract = x\n' > "$r/etc/pacman.conf"
  printf '#!/bin/bash\n# OMARCHY-BLOCKED-GUARD\n' > "$r/usr/bin/omarchy-update"
  printf 'ID=cachyos\nPRETTY_NAME="CachyOS"\n' > "$r/etc/os-release"
  touch "$r/usr/share/libalpm/hooks/99-restore-distro-identity.hook"
  touch "$r/usr/share/wayland-sessions/omarchy.desktop"
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$r/etc/kernel/entry-token"
  mkdir -p "$r/boot/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  # the launcher check looks at $HOME, which we cannot prefix; give it one
  mkdir -p "$r/home/.local/share/applications"
  echo "$r"
}

# XDG_DATA_HOME is cleared so the shortcut-backup probe resolves under the fake
# HOME rather than wherever the machine running the tests keeps its own.
check() { OC_ROOT="$1" HOME="$1/home" XDG_DATA_HOME='' "$TOOL" check 2>&1; }

# Leave a shortcut backup behind. `holders` is the JSON for that field: "[]" is
# an abandoned borrow (a killed session), a live pid means a window still needs
# the keys, and omitting the field entirely is a backup written before holder
# tracking existed.
stale_shortcuts() { # stale_shortcuts <root> <entry-count> [holders-json]
  local d="$1/home/.local/share/omarchy-cachyos" i n="$2" e="" h="${3-[]}"
  mkdir -p "$d"
  for ((i = 0; i < n; i++)); do
    e+="{\"id\":[\"kwin\",\"a$i\",\"\",\"\"],\"keys\":[268435527],\"kept\":[]},"
  done
  if [[ $h == omit ]]; then
    printf '{"version":1,"saved_at":"now","entries":[%s]}' "${e%,}"
  else
    printf '{"version":2,"saved_at":"now","holders":%s,"entries":[%s]}' "$h" "${e%,}"
  fi > "$d/kde-shortcuts.backup.json"
}

# The session's About art, as preserve-cachyos-identity --branding leaves it:
# a copy of what we wrote, beside the live file.
branding() { # branding <root> <applied-art> <live-art>
  local d="$1/home/.config/omarchy/branding" t="$1/home/.local/share/omarchy-cachyos/branding"
  mkdir -p "$d" "$t/applied"
  printf '%s\n' "$2" > "$t/applied/about.txt"
  printf '%s\n' "$3" > "$d/about.txt"
}

# A holders entry for a process that really is running: this shell.
live_holder() {
  local s; s=$(</proc/$$/stat)
  printf '[{"pid":%d,"start":"%s"}]' "$$" "$(awk '{print $20}' <<<"${s#*") "}")"
}

expect()     { local d="$1" w="$2" o="$3"; if grep -qF "$w" <<<"$o"; then ok "$d"; else
                 nope "$d"; printf '        wanted: %s\n' "$w"
                 printf '        got:\n'; head -14 <<<"$o" | sed 's/^/          /'; fi; }
expect_not() { local d="$1" w="$2" o="$3"; if grep -qF "$w" <<<"$o"; then
                 nope "$d"; head -14 <<<"$o" | sed 's/^/          /'; else ok "$d"; fi; }

printf '\n\033[1;34m== fault detection\033[0m\n'

R=$(new_root); expect_not "healthy fake tree reports nothing" "CRITICAL" "$(check "$R")"; rm -rf "$R"

R=$(new_root); printf 'HOOKS=(base udev encrypt)\n' > "$R/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
expect "detects the boot-critical mkinitcpio drop-in" "initramfs drop-in is present" "$(check "$R")"; rm -rf "$R"

R=$(new_root); mkdir -p "$R/etc/limine-entry-tool.d"; touch "$R/etc/limine-entry-tool.d/omarchy-uki.conf"
expect "detects the bootloader drop-ins" "bootloader drop-ins are present" "$(check "$R")"; rm -rf "$R"

R=$(new_root); printf '[options]\n' > "$R/etc/pacman.conf"
expect "detects missing NoExtract guards" "NoExtract guards are missing" "$(check "$R")"; rm -rf "$R"

R=$(new_root); printf '#!/bin/bash\necho real\n' > "$R/usr/bin/omarchy-update"
expect "detects an unguarded omarchy-update" "are runnable" "$(check "$R")"; rm -rf "$R"

R=$(new_root); touch "$R/usr/share/libalpm/hooks/00-omarchy-update-guard.hook"
expect "detects the pacman update-guard deadlock" "blocking plain" "$(check "$R")"; rm -rf "$R"

R=$(new_root); rm -f "$R/usr/share/libalpm/hooks/99-restore-distro-identity.hook"
printf 'ID=omarchy\nPRETTY_NAME="Omarchy"\n' > "$R/etc/os-release"
expect "detects hijacked distribution branding" "branding" "$(check "$R")"; rm -rf "$R"

R=$(new_root); rm -f "$R/usr/share/wayland-sessions/omarchy.desktop"
expect "detects a missing login session" "not offered at login" "$(check "$R")"; rm -rf "$R"

R=$(new_root); mkdir -p "$R/boot/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
expect "detects an orphaned /boot entry token" "orphaned /boot entry" "$(check "$R")"; rm -rf "$R"

R=$(new_root); ln -sf "$R/usr/bin/omarchy-update" "$R/usr/local/share/omarchy-blocked/usr_bin_omarchy-update"
expect "detects a stashed original that points at the guard" "symlink pointing at the guard" "$(check "$R")"; rm -rf "$R"

R=$(new_root); stale_shortcuts "$R" 3
expect "detects shortcuts a killed window session never handed back" \
  "missing 3 keyboard shortcut(s)" "$(check "$R")"; rm -rf "$R"

R=$(new_root); stale_shortcuts "$R" 3
expect "offers the restore command as the fix" \
  "omarchy-window-shortcuts restore" "$(check "$R")"; rm -rf "$R"

R=$(new_root); stale_shortcuts "$R" 3
expect "says plainly that Super and Alt+Tab were never taken" \
  "Alt+Tab are not affected" "$(check "$R")"; rm -rf "$R"

R=$(new_root); mkdir -p "$R/home/.local/share/omarchy-cachyos"
printf 'not json at all' > "$R/home/.local/share/omarchy-cachyos/kde-shortcuts.backup.json"
expect "still reports an unreadable shortcut backup" \
  "keyboard shortcut(s)" "$(check "$R")"; rm -rf "$R"

R=$(new_root)
expect_not "a healthy tree says nothing about shortcuts" \
  "keyboard shortcut" "$(check "$R")"; rm -rf "$R"

# Borrowed keys are the feature working. Reporting a fault there would send
# someone to reclaim shortcuts their open windows are still using.
R=$(new_root); stale_shortcuts "$R" 3 "$(live_holder)"
expect_not "stays quiet while a live window still holds the keys" \
  "keyboard shortcut" "$(check "$R")"; rm -rf "$R"

R=$(new_root); stale_shortcuts "$R" 3 omit
expect_not "stays quiet for a backup predating holder tracking" \
  "keyboard shortcut" "$(check "$R")"; rm -rf "$R"

R=$(new_root); branding "$R" "CACHYOS-ART" "OMARCHY-ART"
expect "detects Omarchy branding overwriting the session art" \
  "branding has come back" "$(check "$R")"; rm -rf "$R"

R=$(new_root); branding "$R" "CACHYOS-ART" "OMARCHY-ART"
expect "  offers the lightweight re-brand, not the full identity restore" \
  "preserve-cachyos-identity.sh --branding" "$(check "$R")"; rm -rf "$R"

R=$(new_root); branding "$R" "CACHYOS-ART" "CACHYOS-ART"
expect_not "stays quiet while the session art is still yours" \
  "branding has come back" "$(check "$R")"; rm -rf "$R"

# Never applied means nothing to have drifted, so nothing to report.
R=$(new_root); mkdir -p "$R/home/.config/omarchy/branding"
printf 'OMARCHY-ART\n' > "$R/home/.config/omarchy/branding/about.txt"
expect_not "says nothing when the branding was never changed" \
  "branding has come back" "$(check "$R")"; rm -rf "$R"

printf '\n\033[1;34m== limine boot-entry duplication\033[0m\n'
# A real failure: an orphaned OS entry kept stale verification hashes, showed an
# error instead of booting, and the working entry was the one with the wrong
# name. The rule that catches it is one regex in verify-reboot-safety.sh, and it
# only works because top-level OS entries write that comment unindented while
# snapshot sub-entries indent theirs. Assert the expression is still there, then
# assert it still counts correctly - a fixture alone would pass forever after
# someone edited the script.
# shellcheck disable=SC2016  # the literal source text, not something to expand
OSRE='^comment: machine-id=${MID}([[:space:]]|$)'
if grep -qF -- "$OSRE" "$HERE/verify-reboot-safety.sh"; then
  ok "verify-reboot-safety.sh still uses the tested entry-matching rule"
else
  nope "entry-matching rule changed; update this test to match verify-reboot-safety.sh"
fi

limine_fixture() { # limine_fixture <file> <count-of-top-level-os-entries>
  local f="$1" n="$2" i
  : > "$f"
  printf 'timeout: 5\ndefault_entry: 2\n\n' >> "$f"
  for ((i = 0; i < n; i++)); do
    printf 'comment: machine-id=%s order-priority=50 \n/+OS%d\n  //linux-cachyos\n' "$MIDF" "$i" >> "$f"
    # A snapshot sub-entry carrying the same id, indented. Must not be counted.
    printf '     ///%d | snapshot\n     comment: machine-id=%s\n' "$i" "$MIDF" >> "$f"
  done
}
MIDF=1c0f28fab0c443338dde8610e5e938b7
count_os() { grep -cE "^comment: machine-id=${MIDF}([[:space:]]|\$)" "$1" || true; }

expect_count() { # expect_count <description> <want> <file>
  local d="$1" want="$2" got; got=$(count_os "$3")
  if [[ $got == "$want" ]]; then ok "$d"; else nope "$d (counted $got, wanted $want)"; fi
}

T=$(mktemp -d)
limine_fixture "$T/one.conf" 1
expect_count "one OS entry counts as one, despite an indented snapshot sharing the id" 1 "$T/one.conf"

limine_fixture "$T/two.conf" 2
expect_count "an orphaned duplicate OS entry is detected" 2 "$T/two.conf"

printf 'timeout: 5\n  comment: machine-id=%s\n' "$MIDF" > "$T/none.conf"
expect_count "an indented id alone is not mistaken for an OS entry" 0 "$T/none.conf"
rm -rf "$T"

printf '\n\033[1;34m== severity ordering\033[0m\n'
R=$(new_root); printf 'HOOKS=(x)\n' > "$R/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
expect "boot faults are marked CRITICAL" "[CRITICAL]" "$(check "$R")"; rm -rf "$R"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
