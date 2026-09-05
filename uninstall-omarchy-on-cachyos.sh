#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Reverse install-omarchy-on-cachyos.sh. Leaves Plasma and the CachyOS repos alone.
#
# Usage: ./uninstall-omarchy-on-cachyos.sh [--keep-apps] [--dry-run]
#   --keep-apps  remove the session; retain applications, repository and safeguards

set -euo pipefail

# Test seam, as in block-omarchy-updates.sh and clean-stale-boot-entries.sh.
# Unset in normal use, so every path is the real one. Set, the whole removal runs
# against a fixture - which is the only way this script, listed as never run
# since the first release, gets exercised at all.
: "${OC_ROOT:=}"
if [[ -n $OC_ROOT ]]; then
  sudo() { while [[ ${1:-} == -* ]]; do shift; done; (( $# )) || return 0; "$@"; }
fi
SESSION="$OC_ROOT/usr/share/wayland-sessions/omarchy.desktop"
PACCONF="$OC_ROOT/etc/pacman.conf"

DRYRUN=0; KEEP_APPS=0
for a in "$@"; do case "$a" in
  --dry-run) DRYRUN=1 ;; --keep-apps) KEEP_APPS=1 ;;
  -h|--help) sed -n '2,7p' "$0"; exit 0 ;; *) echo "unknown: $a" >&2; exit 1 ;;
esac; done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
# Execute an argument vector directly - no eval, so paths with spaces or globs
# survive intact. run_to adds the one thing an array cannot express: redirection.
run() {
  if (( DRYRUN )); then printf '   [dry-run] %s\n' "$(printf '%q ' "$@")"
  else "$@"; fi
}
run_to() {
  local out="$1"; shift
  if (( DRYRUN )); then printf '   [dry-run] %s > %s\n' "$(printf '%q ' "$@")" "$out"
  else "$@" > "$out"; fi
}

# Refusing root is right for a real removal and meaningless against a fixture.
[[ -z $OC_ROOT ]] && (( EUID == 0 )) && { echo "Run as your normal user." >&2; exit 1; }
(( DRYRUN )) || sudo -v

# Resolve the whole removal before changing session files or safeguards.
# -R deliberately avoids recursively removing applications and dependencies.
if (( ! KEEP_APPS )); then
  installed=$(pacman -Qq) || { warn "Cannot read installed packages; nothing removed."; exit 1; }
  packages=()
  for p in omarchy omarchy-settings; do
    if grep -qx "$p" <<< "$installed"; then packages+=("$p"); fi
  done
  if (( ${#packages[@]} )); then
    if ! run sudo pacman -R --noconfirm "${packages[@]}"; then
      warn "Package removal failed. Repository, guards and session files are retained."
      warn "Resolve the pacman error and rerun this command; do not remove guards manually."
      exit 1
    fi
    if (( ! DRYRUN )); then
      remaining=$(pacman -Qq) || { warn "Cannot verify removal; safeguards retained."; exit 1; }
      for p in "${packages[@]}"; do
        if grep -qx "$p" <<< "$remaining"; then
          warn "$p is still installed; safeguards retained. Resolve the removal and retry."
          exit 1
        fi
      done
    fi
  fi
else
  log "--keep-apps: leaving packages installed, with repository and safeguards retained"
fi

# Do this before anything is removed. A nested window that was killed mid-session
# leaves KDE's Meta+ shortcuts lent out, and uninstalling the helper that holds
# the backup would strand them with nothing left to put them back.
_shortcuts=$(command -v omarchy-window-shortcuts 2>/dev/null || true)
[[ -n $_shortcuts ]] || _shortcuts="$(dirname "$(readlink -f "$0")")/omarchy-window-shortcuts"
# Gate on the backup itself, not on `status`: that also exits non-zero when there
# is no Plasma to ask, which would fire this on a machine that never borrowed.
_sbak="${OC_KDE_SHORTCUT_BACKUP:-${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-cachyos/kde-shortcuts.backup.json}"
if [[ -x $_shortcuts && -f $_sbak ]]; then
  log "Giving KDE back the keyboard shortcuts a nested window had borrowed"
  run "$_shortcuts" restore
fi

log "Unlinking Omarchy's agent skills from your Claude Code config"
# Only symlinks that point into the Omarchy package. Anything else under
# skills/ is the user's own and is left exactly where it is - and once the
# package goes, these would dangle.
_skilldst="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
if [[ -d $_skilldst ]]; then
  _unlinked=0
  for _sk in "$_skilldst"/*; do
    [[ -L $_sk ]] || continue
    case "$(readlink "$_sk")" in
      "$OC_ROOT"/usr/share/omarchy/*) run rm -f "$_sk"; _unlinked=$((_unlinked+1)) ;;
    esac
  done
  log "Unlinked $_unlinked skill(s); anything you added yourself was left alone"
  # Only if we emptied it. rmdir refuses a non-empty directory, which is the check.
  if (( ! DRYRUN )); then
    rmdir "$_skilldst" 2>/dev/null || true
  fi
fi

log "Removing the Omarchy session entry"
run sudo rm -f "$SESSION"


if (( ! KEEP_APPS )); then
log "Removing the [omarchy] repo from $PACCONF"
if grep -q '^\[omarchy\]' "$PACCONF"; then
  run sudo cp "$PACCONF" "$PACCONF.pre-omarchy-removal"
  if (( ! DRYRUN )); then
    sudo awk '
      /^\[omarchy\]$/ { skip=1; next }
      skip && /^\[/    { skip=0 }
      skip && (/^SigLevel/ || /^Server/ || /^[[:space:]]*$/) { next }
      { print }
    ' "$PACCONF" | sudo tee "$PACCONF".new >/dev/null
    sudo mv "$PACCONF".new "$PACCONF"
  fi
fi

log "Removing the NoExtract guards"
if grep -q 'omarchy-on-cachyos guards' "$PACCONF" && (( ! DRYRUN )); then
  sudo awk '
    /omarchy-on-cachyos guards \(do not remove\)/ { skip=1; next }
    /end omarchy-on-cachyos guards/ { skip=0; next }
    !skip { print }
  ' "$PACCONF" | sudo tee "$PACCONF".new >/dev/null
  sudo mv "$PACCONF".new "$PACCONF"
fi

fi

log "Checking for leftover Omarchy files in /etc"
for f in "$OC_ROOT"/etc/mkinitcpio.conf.d/omarchy_hooks.conf "$OC_ROOT"/etc/limine-entry-tool.d/omarchy-*.conf; do
  # An argument vector, like every other call here. This was one quoted string,
  # so it tried to exec a command literally named `sudo rm -f '/etc/...'`, exited
  # 127, and under `set -e` ended the uninstall on the spot - leaving both files
  # on disk, skipping the sd-encrypt check below and the database refresh, and
  # ending with "No such file or directory" instead of "Removal complete".
  # These are the two boot-hazard files this project exists to keep off the
  # machine, so the one path that removes them never did.
  [[ -e $f ]] && { warn "leftover: $f"; run sudo rm -f "$f"; }
done

if (( ! DRYRUN )); then
  eff="$(sudo bash -c 'r="$1"; HOOKS=(); . "$r/etc/mkinitcpio.conf"; for f in "$r"/etc/mkinitcpio.conf.d/*.conf; do [ -e "$f" ] && . "$f"; done; echo "${HOOKS[*]}"' _ "$OC_ROOT")"
  echo "    effective HOOKS: $eff"
  grep -q rd.luks /proc/cmdline && [[ $eff != *sd-encrypt* ]] && warn "sd-encrypt MISSING - do not reboot until fixed."
fi

log "Repository edits take effect on your next normal full system upgrade (pacman -Syu)."

cat <<EOF

$(log "Removal complete.")
  Your ~/.config/hypr and ~/.config/omarchy were left in place. Other applications may still use them.
  Delete them manually if you want a clean slate.
  Config backups from install time live in ~/.local/share/omarchy-cachyos/

EOF
