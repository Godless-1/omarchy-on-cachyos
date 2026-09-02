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

check() { OC_ROOT="$1" HOME="$1/home" "$TOOL" check 2>&1; }

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

printf '\n\033[1;34m== severity ordering\033[0m\n'
R=$(new_root); printf 'HOOKS=(x)\n' > "$R/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
expect "boot faults are marked CRITICAL" "[CRITICAL]" "$(check "$R")"; rm -rf "$R"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
