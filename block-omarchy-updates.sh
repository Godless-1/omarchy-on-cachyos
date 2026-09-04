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
#   ./block-omarchy-updates.sh            # install the guards
#   ./block-omarchy-updates.sh --undo     # restore the originals
#   ./block-omarchy-updates.sh --status   # show current state
#   ./block-omarchy-updates.sh --dry-run  # print what would happen, change nothing
#
# --dry-run works with --undo too, so the reversal can be previewed before it is
# trusted. Combine them:  ./block-omarchy-updates.sh --undo --dry-run

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DRYRUN=0
MARKER="OMARCHY-BLOCKED-GUARD"

# Test seam, matching omarchy-on-cachyos. Unset in normal use, so every path
# below is the real one and this file behaves exactly as it did without it.
# Set to a directory, the whole block/undo cycle runs against a fixture tree -
# which is the only way the reversal path, the one the documentation points at
# most and nobody had ever run, could be exercised at all.
: "${OC_ROOT:=}"
# The fixture is owned by whoever runs the tests, so there is nothing to elevate
# for. Shadowing sudo here rather than editing 24 call sites keeps the diff on a
# script that replaces system binaries down to the paths themselves.
if [[ -n $OC_ROOT ]]; then
  sudo() {
    # sudo's own options are dropped, not passed on: `sudo -v` refreshes a
    # timestamp and must succeed having run nothing, where a plain passthrough
    # would try to execute `-v` and fail the credential check.
    while [[ ${1:-} == -* ]]; do shift; done
    (( $# )) || return 0
    "$@"
  }
fi

VAULT=$OC_ROOT/usr/local/share/omarchy-blocked
PACCONF=$OC_ROOT/etc/pacman.conf
# Omarchy's pre-transaction hook aborts any direct `pacman -Syu` and directs you
# to `omarchy update`, which this script blocks. Left in place the two deadlock,
# and the system cannot be updated at all.
HOOK=$OC_ROOT/usr/share/libalpm/hooks/00-omarchy-update-guard.hook
TARGETS=(
  "$OC_ROOT/usr/bin/omarchy-update"
  "$OC_ROOT/usr/bin/omarchy-refresh-pacman"
  "$OC_ROOT/usr/share/omarchy/bin/omarchy-update"
  "$OC_ROOT/usr/share/omarchy/bin/omarchy-refresh-pacman"
)

# The vault filename is derived from the logical path, with any test prefix
# stripped, so a fixture run produces the same names a real one does - and the
# repair branch below, which looks for `usr_bin_<name>` by hand, still matches.
vault_key() { local t="${1#"$OC_ROOT"}"; echo "${t#/}" | tr / _; }

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

for a in "$@"; do
  case "$a" in
    --status) status; exit 0 ;;
    --dry-run) DRYRUN=1 ;;
    --undo) : ;;   # handled below
    -h|--help) sed -n '4,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "unknown option: $a" "Valid: --undo, --status, --dry-run" ;;
  esac
done

# Every mutation goes through this, so --dry-run is honest by construction rather
# than by remembering to guard each call site.
do_() {
  if (( DRYRUN )); then printf '   [dry-run] %s\n' "$(printf '%q ' "$@")"; return 0; fi
  "$@"
}

# Refusing root is right for a real system - running this under sudo would leave
# root-owned files behind - but meaningless against a fixture, and CI's container
# is root. OC_ROOT is only ever set by the test suite.
if [[ -z $OC_ROOT ]] && (( ! DRYRUN )) && (( EUID == 0 )); then
  die "Run as your normal user; it will sudo where needed." "Re-run without sudo:  $0 ${*:-}"
fi
(( DRYRUN )) || sudo -v || die "sudo required" "Nothing has been changed." "To inspect the current state without sudo:  $0 --status"

# ------------------------------------------------------------------- undo
if [[ ${1:-} == "--undo" ]]; then
  log "Restoring originals from $VAULT"
  # /usr/bin first: the /usr/share copies may legitimately be symlinks to them.
  for t in $(printf '%s\n' "${TARGETS[@]}" | sort); do
    b="$VAULT/$(vault_key "$t")"
    if [[ -f $b ]]; then
      do_ sudo install -m 0755 "$b" "$t"
      (( DRYRUN )) && echo "  would restore $t" || echo "  restored $t"
    else
      warn "no backup for $t (reinstall with: sudo pacman -S omarchy)"
    fi
  done
  if [[ -f $VAULT/update-guard.hook ]]; then
    log "Restoring $HOOK"
    do_ sudo install -m 0644 "$VAULT/update-guard.hook" "$HOOK"
  fi

  log "Removing the NoExtract entries"
  do_ sudo sed -i -E '/^NoExtract = usr\/(bin|share\/omarchy\/bin)\/omarchy-(update|refresh-pacman)$/d' "$PACCONF"
  do_ sudo sed -i '\|^NoExtract = usr/share/libalpm/hooks/00-omarchy-update-guard.hook$|d' "$PACCONF"
  log "Done. The commands are live again."
  exit 0
fi

# ------------------------------------------------------------------ block
# Checked here, before a single binary is replaced. The NoExtract entries are
# inserted before the installer's end-marker, so without that marker they cannot
# be written - and discovering that after the commands have been guarded leaves
# them blocked with nothing stopping pacman restoring them, which is the one
# state this script exists to avoid.
if ! (( DRYRUN )) && ! grep -qxF "# --- end omarchy-on-cachyos guards ---" "$PACCONF"; then
  die "the omarchy-on-cachyos guards block is missing from $PACCONF" \
      "Nothing has been changed - this is checked before anything is replaced." \
      "That block is written by the installer, and the NoExtract entries go inside it." \
      "Create it:  $SELF_DIR/install-omarchy-on-cachyos.sh" \
      "Or see what happened to it:  grep -n omarchy-on-cachyos $PACCONF"
fi

do_ sudo mkdir -p "$VAULT"

log "Backing up the real commands to $VAULT"
for t in "${TARGETS[@]}"; do
  [[ -e $t ]] || continue
  b="$VAULT/$(vault_key "$t")"
  if is_guard "$t"; then
    echo "  $t is already a guard - not overwriting the backup"
  else
    # -L dereferences: /usr/share/omarchy/bin/omarchy-* are symlinks into /usr/bin,
    # and `cp -a` would stash a symlink that later resolves to the guard itself.
    do_ sudo cp -aL "$t" "$b"; echo "  saved $(basename "$t") -> $b"
  fi
done

# Repair symlinked vault entries left by earlier runs, which would otherwise
# restore a guard over a guard on --undo.
for t in "${TARGETS[@]}"; do
  (( DRYRUN )) && break   # the probes below need sudo; a dry run must not prompt
  b="$VAULT/$(vault_key "$t")"
  if sudo test -L "$b"; then
    tgt=$(sudo readlink -f "$b" 2>/dev/null || true)
    if [[ -n $tgt ]] && sudo grep -q "$MARKER" "$tgt" 2>/dev/null; then
      src="$VAULT/usr_bin_$(basename "$t")"
      if sudo test -f "$src" && ! sudo grep -q "$MARKER" "$src" 2>/dev/null; then
        warn "vault entry $(basename "$b") was a symlink into the guard - repairing"
        do_ sudo rm -f "$b"; do_ sudo cp -a "$src" "$b"
      else
        warn "vault entry $(basename "$b") is unusable; reinstall with: sudo pacman -S omarchy"
      fi
    fi
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
  if [[ -x $real ]] && ! grep -q "OMARCHY-BLOCKED-GUARD" "$real" 2>/dev/null; then
    echo "OMARCHY_ALLOW_DANGEROUS set - running the real $self." >&2
    exec "$real" "$@"
  fi
  if [[ -e $real ]]; then
    echo "Stashed copy of $self is itself a guard - refusing to loop." >&2
    echo "Reinstall the original with: sudo pacman -S omarchy" >&2
    exit 1
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
  do_ sudo install -m 0755 "$tmp" "$t"; echo "  guarded $t"
done
rm -f "$tmp"

log "Neutralising the pacman update-guard hook"
if [[ -f $HOOK ]]; then
  do_ sudo cp -a "$HOOK" "$VAULT/update-guard.hook"
  do_ sudo rm -f "$HOOK"
  echo "  removed $HOOK (stashed in $VAULT)"
  echo "  plain 'sudo pacman -Syu' works again"
else
  echo "  already absent"
fi

# The entries are inserted before the installer's end-marker; the precondition
# for that is checked at the top, before anything has been replaced.
log "Adding NoExtract entries so pacman never restores the originals"
for p in usr/bin/omarchy-update usr/bin/omarchy-refresh-pacman \
         usr/share/omarchy/bin/omarchy-update usr/share/omarchy/bin/omarchy-refresh-pacman \
         usr/share/libalpm/hooks/00-omarchy-update-guard.hook; do
  if grep -qxF "NoExtract = $p" "$PACCONF"; then
    echo "  already present: $p"
  else
    do_ sudo sed -i "/^# --- end omarchy-on-cachyos guards ---$/i NoExtract = $p" "$PACCONF"
    # Say what happened, not what was attempted.
    if (( DRYRUN )); then echo "  would add: $p"
    elif grep -qxF "NoExtract = $p" "$PACCONF"; then echo "  added: $p"
    else warn "could not add: $p"; fi
  fi
done
grep -q '^NoExtract = usr/bin/omarchy-update$' "$PACCONF" || die "NoExtract insertion failed - the guards are not in place" "The binaries may already be guarded but pacman would restore them on update." "Undo cleanly:  $0 --undo" "Then check pacman.conf is intact:  pacman-conf >/dev/null && echo ok"

echo
log "Blocked. Current state:"
status
cat <<EOF

  Covered: every shell (fish/bash/zsh), both sessions, the Omarchy menu's
  "Update > Omarchy" entry, and the indirect callers omarchy-channel-set
  and omarchy-reinstall-pkgs.

  Undo with: $0 --undo
EOF
