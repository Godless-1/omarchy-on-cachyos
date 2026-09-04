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
# It also reports orphaned *entries inside limine.conf*, which are a different
# fault with the same cause. limine-entry-tool titles its top-level OS entry from
# NAME/PRETTY_NAME in /etc/os-release and keys on that title, so a changed
# distribution name makes it write a new entry and abandon the old. The abandoned
# one keeps the hashes it had that day and stops booting, while still sitting in
# the menu - the good-looking entry being the dead one.
#
#   ./clean-stale-boot-entries.sh --remove-stale-entry   # remove it, then regenerate
#
# The active entry token is never touched, and the script refuses to remove anything
# your bootloader still references.

set -euo pipefail

MODE=report
REMOVE_ENTRY=0
# Test seams. Unset in normal use, so both resolve to the real thing.
LIMINE_CONF="${OC_LIMINE_CONF:-/boot/limine.conf}"
DEST="${OMARCHY_BOOT_ARCHIVE:-$HOME/.local/share/omarchy-cachyos/stale-boot}"
for a in "$@"; do
  case "$a" in
    --archive) MODE=archive ;;
    --delete)  MODE=delete ;;
    --remove-stale-entry) REMOVE_ENTRY=1 ;;
    -h|--help) sed -n '4,19p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die() {
  local msg="$1"; shift
  printf '\n\033[1;31mXX\033[0m  %s\n' "$msg" >&2
  if (( $# )); then
    printf '\n    \033[1mHow to recover:\033[0m\n' >&2
    printf '      %s\n' "$@" >&2
  fi
  printf '\n' >&2
  exit 1
}

# --- orphaned entries inside limine.conf ----------------------------------
# The config is read directly rather than through limine-entry-tool, whose --help
# needs root even to print usage. A top-level entry belongs to this machine if
# something under it loads from boot():/<token>/. The live one is whichever
# carries the highest snapshot number, because only the live entry keeps being
# given new ones - the abandoned one is frozen on the day it was orphaned.
entry_table() { # entry_table <conf> <token>  ->  name<TAB>highest-snapshot
  local conf="$1" token="$2"
  { if [[ -r $conf ]]; then cat "$conf"; else sudo cat "$conf"; fi; } 2>/dev/null | awk -v mid="$token" '
    /^\/[^\/]/ { name = $0; sub(/^\/\+?/, "", name); next }
    name == "" { next }
    index($0, "boot():/" mid "/") { claim[name] = 1 }
    /^[[:space:]]*\/\/\/[0-9]+/ {
      s = $0; sub(/^[[:space:]]*\/\/\//, "", s); sub(/[^0-9].*$/, "", s)
      if (s + 0 > snap[name]) snap[name] = s + 0
    }
    END { for (n in claim) printf "%s\t%d\n", n, snap[n] }
  '
}

entry_check() { # entry_check <conf> <token>
  local conf="$1" token="$2" rows=() live stale livesnap stalesnap
  mapfile -t rows < <(entry_table "$conf" "$token" | sort -t"$(printf '\t')" -k2,2nr)

  if (( ${#rows[@]} == 0 )); then
    warn "No top-level entry in $conf loads from boot():/$token/"
    echo "      Not necessarily wrong, but nothing here can be judged."
    echo "      Look by hand:  sudo limine-entry-tool --tree"
    return 0
  fi
  if (( ${#rows[@]} == 1 )); then
    log "One boot entry claims this machine: ${rows[0]%%$'\t'*}"
    return 0
  fi

  live=${rows[0]%%$'\t'*};  livesnap=${rows[0]##*$'\t'}
  stale=${rows[1]%%$'\t'*}; stalesnap=${rows[1]##*$'\t'}

  warn "${#rows[@]} top-level entries claim this machine - only one can be current"
  local r
  for r in "${rows[@]}"; do
    printf '      %-28s newest snapshot: %s\n' "${r%%$'\t'*}" "${r##*$'\t'}"
  done
  echo "      The abandoned ones keep the hashes they had when the distribution"
  echo "      name changed, so they fail verification and error out instead of"
  echo "      booting. Your live entry is unaffected."

  # Refuse rather than guess. A tie means neither has newer snapshots than the
  # other, and picking the wrong one removes the entry that still boots.
  if (( livesnap == stalesnap )); then
    warn "Cannot tell which is live: both stop at snapshot $livesnap."
    echo "      Refusing to choose. Compare them yourself:"
    echo "        sudo limine-entry-tool --tree"
    echo "        sudo limine-remove-entry '<the one that is not current>'"
    echo "        sudo limine-update"
    return 0
  fi

  log "Live: '$live' (snapshot $livesnap).  Stale: '$stale' (snapshot $stalesnap)."
  if (( ! REMOVE_ENTRY )); then
    echo "      Remove the stale one with:"
    echo "        $0 --remove-stale-entry"
    echo "      or by hand, which is the same two commands:"
    echo "        sudo limine-remove-entry '$stale'"
    echo "        sudo limine-update"
    return 0
  fi

  if (( ${#rows[@]} > 2 )); then
    warn "More than two entries claim this machine; removing one at a time."
  fi

  local backup
  backup="$DEST/limine.conf.$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$DEST"
  # The redirect is deliberately unprivileged: $backup is in the user's own
  # directory, and sudo is needed only to read the root-only ESP.
  # shellcheck disable=SC2024
  sudo cat "$conf" > "$backup" || die "could not back up $conf" \
    "Nothing has been changed." "Without a backup this will not touch the bootloader."
  log "Backed up $conf to $backup"

  log "Removing '$stale' by name"
  # By name, never by machine-ID-and-position: both entries match the id, so a
  # wrong position removes the one that still boots.
  sudo limine-remove-entry "$stale" || die "limine-remove-entry failed" \
    "Nothing was removed." "Restore if needed:  sudo cp $backup $conf"
  sudo limine-update || die "limine-update failed after removing '$stale'" \
    "The entry is gone but the config was not regenerated." \
    "Restore:  sudo cp $backup $conf" \
    "Then retry, or run:  sudo limine-update"

  local left; left=$(entry_table "$conf" "$token" | wc -l)
  if (( left == 1 )); then
    log "One entry left. Confirm with:  sudo limine-entry-tool --tree"
  else
    warn "$left entries still claim this machine; re-run to remove the next."
  fi
}

# Test seam: with OC_LIMINE_CONF set, only the entry analysis runs, against that
# file, with no sudo and no /boot. Everything below needs a real machine.
if [[ -n ${OC_LIMINE_CONF:-} ]]; then
  entry_check "$LIMINE_CONF" "${OC_MACHINE_ID:?OC_MACHINE_ID must be set with OC_LIMINE_CONF}"
  exit 0
fi

(( EUID == 0 )) && die "Run as your normal user; it will sudo where needed." "Re-run without sudo:  $0 ${*:-}"
sudo -v || die "sudo required" "Nothing has been changed."

TOKEN=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id 2>/dev/null) \
  || die "cannot determine the active entry token" "Nothing has been changed - refusing to guess which /boot entries are live." "Check by hand:  cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id"
[[ -n $TOKEN ]] || die "active entry token is empty - refusing to guess" "Nothing has been changed." "An empty token means every /boot/<hex>/ directory would look orphaned." "Check:  cat /etc/machine-id"
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
