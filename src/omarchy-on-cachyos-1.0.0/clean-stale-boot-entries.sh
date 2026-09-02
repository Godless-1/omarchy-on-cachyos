#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Remove orphaned kernel-install entry directories from /boot.
#
# systemd's kernel-install writes to /boot/<entry-token>/<kernel>/, where the token
# defaults to the machine-id. Reinstalling, or regenerating /etc/machine-id, strands
# the previous directory: it is never booted, never updated, and quietly holds a few
# hundred MB on an ESP that is usually small.
#
#   ./clean-stale-boot-entries.sh            # report only, changes nothing
#   ./clean-stale-boot-entries.sh --archive  # move them out of /boot (default action)
#   ./clean-stale-boot-entries.sh --delete   # remove them outright
#
# The active entry token is never touched, and the script refuses to remove anything
# your bootloader still references.

set -euo pipefail

MODE=report
DEST="${OMARCHY_BOOT_ARCHIVE:-$HOME/.local/share/omarchy-cachyos/stale-boot}"
for a in "$@"; do
  case "$a" in
    --archive) MODE=archive ;;
    --delete)  MODE=delete ;;
    -h|--help) sed -n '4,19p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m  %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) && die "Run as your normal user; it will sudo where needed."
sudo -v || die "sudo required"

TOKEN=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id 2>/dev/null) \
  || die "cannot determine the active entry token"
[[ -n $TOKEN ]] || die "active entry token is empty - refusing to guess"
log "Active entry token: $TOKEN"

# A candidate is a 32-hex-char directory under /boot that is not the active token
# and actually contains kernel payloads.
mapfile -t STALE < <(
  sudo find /boot -mindepth 1 -maxdepth 1 -type d \
       -regextype posix-extended -regex '.*/[0-9a-f]{32}$' 2>/dev/null |
  while read -r d; do
    [[ $(basename "$d") == "$TOKEN" ]] && continue
    sudo find "$d" -type f \( -name 'initramfs*' -o -name 'vmlinuz*' -o -name 'linux' \) \
      -print -quit 2>/dev/null | grep -q . && echo "$d"
  done
)

if (( ${#STALE[@]} == 0 )); then
  log "No orphaned entry directories. Nothing to do."; exit 0
fi

log "Orphaned entry directories (never booted):"
total=0
for d in "${STALE[@]}"; do
  sz=$(sudo du -sm "$d" 2>/dev/null | cut -f1); total=$((total + sz))
  printf '      %s  (%s MB)\n' "$d" "$sz"
  sudo find "$d" -maxdepth 2 -mindepth 1 -printf '        %P\n' 2>/dev/null | head -8
done
printf '      total: %s MB\n' "$total"

# Refuse to strand bootloader entries.
log "Checking whether the bootloader still references them"
REFERENCED=0
for cfg in /boot/limine.conf /boot/limine.cfg /boot/EFI/limine/limine.conf \
           /boot/loader/entries/*.conf; do
  sudo test -e "$cfg" 2>/dev/null || continue
  for d in "${STALE[@]}"; do
    if sudo grep -qF "$(basename "$d")" "$cfg" 2>/dev/null; then
      warn "$cfg still references $(basename "$d")"; REFERENCED=1
    fi
  done
done
if (( REFERENCED )); then
  warn "Removing these would leave dangling boot entries."
  echo  "      Regenerate your boot config first, then re-run:"
  echo  "        sudo limine-update    # or: sudo limine-mkinitcpio"
  die   "refusing to modify /boot while entries still point at it"
fi
log "No bootloader references. Safe to remove."

case "$MODE" in
  report)
    echo
    log "Report only. Re-run with --archive (recommended) or --delete."
    exit 0 ;;
  archive)
    mkdir -p "$DEST"
    for d in "${STALE[@]}"; do
      log "Archiving $(basename "$d") -> $DEST/"
      sudo cp -a "$d" "$DEST/" && sudo rm -rf "$d"
      sudo chown -R "$USER":"$(id -gn)" "$DEST/$(basename "$d")" 2>/dev/null || true
    done
    log "Archived to $DEST (delete it yourself once you're happy)" ;;
  delete)
    for d in "${STALE[@]}"; do log "Deleting $d"; sudo rm -rf "$d"; done
    log "Deleted." ;;
esac

echo
log "/boot now:"; sudo df -h /boot | tail -1 | sed 's/^/      /'
echo
log "Re-run ./verify-reboot-safety.sh to confirm a clean result."
