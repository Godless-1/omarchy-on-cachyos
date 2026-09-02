#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Make omarchy-update and omarchy-refresh-pacman impossible to run by accident,
# from any shell, any session (Plasma or Omarchy), and from the Omarchy menu.
#
# Mechanism: replace the binaries with a guard, then NoExtract those paths so
# pacman never restores the originals on an omarchy package update.
#
#   ./block-omarchy-updates.sh          # install the guards
#   ./block-omarchy-updates.sh --undo   # restore the originals
#   ./block-omarchy-updates.sh --status # show current state

set -euo pipefail

MARKER="OMARCHY-BLOCKED-GUARD"
VAULT=/usr/local/share/omarchy-blocked
PACCONF=/etc/pacman.conf
TARGETS=(
  /usr/bin/omarchy-update
  /usr/bin/omarchy-refresh-pacman
  /usr/share/omarchy/bin/omarchy-update
  /usr/share/omarchy/bin/omarchy-refresh-pacman
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m  %s\n' "$*" >&2; exit 1; }

is_guard() { [[ -f $1 ]] && grep -q "$MARKER" "$1" 2>/dev/null; }

status() {
  for t in "${TARGETS[@]}"; do
    [[ -e $t ]] || { printf '  %-46s (absent)\n' "$t"; continue; }
    if is_guard "$t"; then printf '  %-46s \033[1;32mBLOCKED\033[0m\n' "$t"
    else                   printf '  %-46s \033[1;31mlive\033[0m\n' "$t"; fi
  done
  echo
  echo "  NoExtract entries:"
  grep -E '^NoExtract = usr/(bin|share/omarchy/bin)/omarchy-(update|refresh-pacman)$' "$PACCONF" \
    | sed 's/^/    /' || echo "    (none)"
}

case "${1:-}" in
  --status) status; exit 0 ;;
esac

(( EUID == 0 )) && die "Run as your normal user; it will sudo where needed."
sudo -v || die "sudo required"

# ------------------------------------------------------------------- undo
if [[ ${1:-} == "--undo" ]]; then
  log "Restoring originals from $VAULT"
  for t in "${TARGETS[@]}"; do
    b="$VAULT/$(echo "${t#/}" | tr / _)"
    if [[ -f $b ]]; then
      sudo install -m 0755 "$b" "$t"; echo "  restored $t"
    else
      warn "no backup for $t (reinstall with: sudo pacman -S omarchy)"
    fi
  done
  log "Removing the NoExtract entries"
  sudo sed -i -E '/^NoExtract = usr\/(bin|share\/omarchy\/bin)\/omarchy-(update|refresh-pacman)$/d' "$PACCONF"
  log "Done. The commands are live again."
  exit 0
fi

# ------------------------------------------------------------------ block
sudo mkdir -p "$VAULT"

log "Backing up the real commands to $VAULT"
for t in "${TARGETS[@]}"; do
  [[ -e $t ]] || continue
  b="$VAULT/$(echo "${t#/}" | tr / _)"
  if is_guard "$t"; then
    echo "  $t is already a guard - not overwriting the backup"
  else
    sudo cp -a "$t" "$b"; echo "  saved $(basename "$t") -> $b"
  fi
done

log "Installing guards"
tmp=$(mktemp)
cat > "$tmp" <<'GUARD'
#!/usr/bin/env bash
# OMARCHY-BLOCKED-GUARD
# This command is blocked on this machine. It is Omarchy running on a CachyOS
# base, and these two commands assume a pure Omarchy install.
#
#   omarchy-refresh-pacman  overwrites /etc/pacman.conf and /etc/pacman.d/mirrorlist,
#                           which deletes the cachyos-v3, cachyos-core-v3,
#                           cachyos-extra-v3, chaotic-aur and blackarch repos and
#                           then force-downgrades every CachyOS-optimised package.
#                           (omarchy-channel-set and omarchy-reinstall-pkgs call it.)
#
#   omarchy-update          runs omarchy-migrate, and none of the shipped migrations
#                           are marked done for this user, so it would execute all of
#                           them against a system they were not written for.
#
# Update this machine with:   sudo pacman -Syu
# That upgrades Omarchy too - [omarchy] is just another repo here.

self=$(basename "$0")
msg="'$self' is blocked on this machine. Use: sudo pacman -Syu"

if [[ -n ${OMARCHY_ALLOW_DANGEROUS:-} ]]; then
  real="/usr/local/share/omarchy-blocked/$(echo "${0#/}" | tr / _)"
  if [[ -x $real ]]; then
    echo "OMARCHY_ALLOW_DANGEROUS set - running the real $self." >&2
    exec "$real" "$@"
  fi
  echo "No stashed original found for $self." >&2
  exit 1
fi

# Visible from the Omarchy menu, which runs this in a floating terminal.
command -v notify-send >/dev/null 2>&1 && \
  notify-send -u critical "Blocked: $self" "Use 'sudo pacman -Syu' instead." 2>/dev/null || true

{
  printf '\n\033[1;31m  %s is blocked on this machine.\033[0m\n\n' "$self"
  sed -n '3,20p' "$0" | sed 's/^# \?/  /'
  printf '\n  Override (only if you truly mean it):  OMARCHY_ALLOW_DANGEROUS=1 %s\n\n' "$self"
} >&2

# Keep the menu's floating terminal open long enough to read this.
[[ -t 0 ]] && { printf '  Press Enter to close. ' >&2; read -r _ || true; }
exit 1
GUARD

for t in "${TARGETS[@]}"; do
  [[ -e $t || $t == /usr/bin/* ]] || continue
  sudo install -m 0755 "$tmp" "$t"; echo "  guarded $t"
done
rm -f "$tmp"

log "Adding NoExtract entries so pacman never restores the originals"
for p in usr/bin/omarchy-update usr/bin/omarchy-refresh-pacman \
         usr/share/omarchy/bin/omarchy-update usr/share/omarchy/bin/omarchy-refresh-pacman; do
  if grep -qxF "NoExtract = $p" "$PACCONF"; then
    echo "  already present: $p"
  else
    sudo sed -i "/^# --- end omarchy-on-cachyos guards ---$/i NoExtract = $p" "$PACCONF"
    echo "  added: $p"
  fi
done
grep -q '^NoExtract = usr/bin/omarchy-update$' "$PACCONF" || die "NoExtract insertion failed"

echo
log "Blocked. Current state:"
status
cat <<EOF

  Covered: every shell (fish/bash/zsh), both sessions, the Omarchy menu's
  "Update > Omarchy" entry, and the indirect callers omarchy-channel-set
  and omarchy-reinstall-pkgs.

  Undo with: $0 --undo
EOF
