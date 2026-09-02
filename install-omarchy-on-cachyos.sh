#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Install Omarchy 4 alongside KDE Plasma on CachyOS, selectable at the greeter.
#
# Deliberately does NOT run Omarchy's install/ scripts: they replace
# /etc/pacman.conf + mirrorlist (destroying the CachyOS repos), rewrite the
# bootloader, and reconfigure the initramfs.
#
# Usage:
#   ./install-omarchy-on-cachyos.sh            # full Omarchy userspace
#   ./install-omarchy-on-cachyos.sh --minimal  # skip heavy optional apps
#   ./install-omarchy-on-cachyos.sh --dry-run  # show what would happen

set -euo pipefail

CHANNEL=stable
REPO_URL="https://pkgs.omarchy.org/${CHANNEL}/\$arch"
DB_URL="https://pkgs.omarchy.org/${CHANNEL}/x86_64"
KEY_FPR="40DFB630FF42BCFFB047046CF0134EE680CAC571"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.local/share/omarchy-cachyos/backup-$STAMP"
MINIMAL=0
DRYRUN=0

# Files Omarchy ships that must never land on this machine.
# Each is followed by the reason; see the README the script prints at the end.
declare -a GUARDS=(
  "etc/mkinitcpio.conf.d/omarchy_hooks.conf"      # would replace sd-encrypt -> encrypt: LUKS root stops unlocking
  "etc/limine-entry-tool.d/*"                     # would switch you to UKI + rename/reorder boot entries
  "etc/docker/daemon.json"                        # would change your Docker bridge subnet + DNS
  "etc/systemd/resolved.conf.d/20-docker-dns.conf"
  "etc/systemd/system/docker.service.d/no-block-boot.conf"
  "etc/sddm.conf.d/*"                             # irrelevant unless SDDM is your display manager
  "etc/skel/.config/alacritty/*"                  # owned by cachyos-alacritty-config, which cachyos-kde-settings requires
  # Keep the blocked-command guards from block-omarchy-updates.sh in place.
  # This block is rewritten on every run, so these must live here too.
  "usr/bin/omarchy-update"
  "usr/bin/omarchy-refresh-pacman"
  "usr/share/omarchy/bin/omarchy-update"
  "usr/share/omarchy/bin/omarchy-refresh-pacman"
  # Aborts every direct `pacman -Syu` and tells you to run `omarchy update`,
  # which we block. Without this guard the two deadlock each other.
  "usr/share/libalpm/hooks/00-omarchy-update-guard.hook"
)

# Packages from omarchy-base.packages to skip on this host.
declare -a PKG_SKIP=(
  sddm          # would install a second display manager
  ufw-docker    # would inject docker rules into your already-enabled ufw
  tldr          # tealdeer already provides /usr/bin/tldr and cachyos-fish-config requires it
)
# Additionally skipped with --minimal (multi-GB optional apps).
declare -a PKG_HEAVY=(
  libreoffice-fresh kdenlive obs-studio obsidian moonlight-qt
  dotnet-runtime gpu-screen-recorder
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m  %s\n' "$*" >&2; exit 1; }
run()  { if (( DRYRUN )); then printf '   [dry-run] %s\n' "$*"; else eval "$@"; fi; }

for arg in "$@"; do
  case "$arg" in
    --minimal) MINIMAL=1 ;;
    --dry-run) DRYRUN=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown option: $arg" ;;
  esac
done

(( EUID == 0 )) && die "Run as your normal user, not root. It will sudo where needed."
command -v pacman >/dev/null || die "pacman not found"
(( DRYRUN )) || sudo -v || die "sudo required"

# ---------------------------------------------------------------- preflight
log "Preflight"
. /etc/os-release
[[ ${ID:-} == cachyos ]] || warn "Expected CachyOS, found '${ID:-unknown}'. Continuing."

ROOT_IS_LUKS=0
grep -q 'rd.luks' /proc/cmdline && ROOT_IS_LUKS=1
CUR_HOOKS="$(grep -hE '^HOOKS=' /etc/mkinitcpio.conf | tail -1)"
if (( ROOT_IS_LUKS )); then
  log "LUKS root detected on a systemd initramfs. The mkinitcpio guard is mandatory."
  [[ $CUR_HOOKS == *sd-encrypt* ]] || warn "Expected sd-encrypt in HOOKS; found: $CUR_HOOKS"
fi

mkdir -p "$BACKUP"
log "Backing up to $BACKUP"
run "cp -a /etc/pacman.conf '$BACKUP/pacman.conf'"
run "cp -a /etc/pacman.d/mirrorlist '$BACKUP/mirrorlist'"
run "cp -a /etc/mkinitcpio.conf '$BACKUP/mkinitcpio.conf'"
run "cp -a /etc/mkinitcpio.conf.d '$BACKUP/mkinitcpio.conf.d'"
run "pacman -Qqe > '$BACKUP/pkglist-explicit.txt'"
run "pacman -Qq  > '$BACKUP/pkglist-all.txt'"
run "cp /proc/cmdline '$BACKUP/cmdline.txt'"

# btrfs + snapper: take a rollback point you can boot from limine.
if (( DRYRUN )); then
  echo "   [dry-run] would create a snapper pre-install snapshot"
elif command -v snapper >/dev/null && sudo snapper list-configs 2>/dev/null | grep -qw root; then
  log "Creating snapper pre-install snapshot"
  run "sudo snapper -c root create -d 'pre-omarchy $STAMP'"
else
  warn "No snapper 'root' config found; skipping snapshot."
fi

# ------------------------------------------------------- NoExtract guards
log "Installing NoExtract guards into /etc/pacman.conf"
guard_block="# --- omarchy-on-cachyos guards (do not remove) ---"
for g in "${GUARDS[@]}"; do guard_block+=$'\n'"NoExtract = $g"; done
guard_block+=$'\n'"# --- end omarchy-on-cachyos guards ---"
if (( DRYRUN )); then
  printf '   [dry-run] would (re)insert after [options]:\n%s\n' "$guard_block"
else
  # Strip any previous block first, so re-runs refresh rather than duplicate.
  sudo awk '
    /omarchy-on-cachyos guards \(do not remove\)/ { skip=1; next }
    /end omarchy-on-cachyos guards/ { skip=0; next }
    !skip { print }
  ' /etc/pacman.conf | sudo tee /etc/pacman.conf.stripped >/dev/null
  printf '%s\n' "$guard_block" | sudo tee /tmp/.omarchy-guards >/dev/null
  sudo awk '
    /^\[options\]/ && !done { print; while ((getline line < "/tmp/.omarchy-guards") > 0) print line; done=1; next }
    { print }
  ' /etc/pacman.conf.stripped | sudo tee /etc/pacman.conf.new >/dev/null
  sudo mv /etc/pacman.conf.new /etc/pacman.conf
  sudo rm -f /tmp/.omarchy-guards /etc/pacman.conf.stripped
  grep -q 'omarchy-on-cachyos guards' /etc/pacman.conf || die "guard insertion failed"
  n=$(grep -c '^NoExtract = ' /etc/pacman.conf)
  log "$n NoExtract guard(s) active"
fi

# ------------------------------------------------------------ keyring
log "Installing the Omarchy signing keyring"
if ! (( DRYRUN )) && sudo pacman-key --list-keys "$KEY_FPR" &>/dev/null; then
  log "Key $KEY_FPR already trusted."
else
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$DB_URL/omarchy.db" -o "$tmp/omarchy.db" || die "cannot reach $DB_URL"
  bsdtar -xf "$tmp/omarchy.db" -C "$tmp"
  kdesc="$(find "$tmp" -maxdepth 2 -path '*omarchy-keyring-*/desc' | head -1)"
  [[ -n $kdesc ]] || die "omarchy-keyring not found in repo db"
  kfile="$(grep -A1 '^%FILENAME%$' "$kdesc" | tail -1)"
  log "Fetching $kfile"
  curl -fsSL "$DB_URL/$kfile" -o "$tmp/$kfile" || die "keyring download failed"
  run "sudo pacman -U --noconfirm '$tmp/$kfile'"
  if ! (( DRYRUN )); then
    sudo pacman-key --populate omarchy 2>/dev/null || true
    sudo pacman-key --list-keys "$KEY_FPR" &>/dev/null \
      || die "Omarchy key $KEY_FPR not trusted after install - aborting rather than lowering SigLevel"
    log "Verified key $KEY_FPR"
  fi
fi

# --------------------------------------------------------------- repo
log "Adding [omarchy] repo (last, so it never overrides CachyOS packages)"
if grep -q '^\[omarchy\]' /etc/pacman.conf; then
  log "[omarchy] already configured."
else
  if (( DRYRUN )); then
    printf '   [dry-run] would append [omarchy] Server = %s\n' "$REPO_URL"
  else
    printf '\n[omarchy]\nSigLevel = Required DatabaseOptional\nServer = %s\n' "$REPO_URL" \
      | sudo tee -a /etc/pacman.conf >/dev/null
  fi
fi
run "sudo pacman -Sy"

# ------------------------------------------------------------ install
log "Installing the omarchy package (sddm assumed-installed: your display manager is kept)"
run "sudo pacman -S --needed --noconfirm omarchy --assume-installed sddm --overwrite '/etc/skel/.config/alacritty/*'"

# ---- HARD GATE: verify the boot guards actually held -------------------
if ! (( DRYRUN )); then
  log "Verifying boot guards held"
  fail=0
  if [[ -e /etc/mkinitcpio.conf.d/omarchy_hooks.conf ]]; then
    warn "omarchy_hooks.conf was extracted despite the guard. Removing it NOW."
    sudo rm -f /etc/mkinitcpio.conf.d/omarchy_hooks.conf; fail=1
  fi
  if compgen -G "/etc/limine-entry-tool.d/omarchy-*.conf" >/dev/null; then
    warn "limine-entry-tool drop-ins were extracted. Removing them NOW."
    sudo rm -f /etc/limine-entry-tool.d/omarchy-*.conf; fail=1
  fi
  eff_hooks="$(sudo bash -c '
    HOOKS=(); MODULES=()
    . /etc/mkinitcpio.conf
    for f in /etc/mkinitcpio.conf.d/*.conf; do [ -e "$f" ] && . "$f"; done
    echo "${HOOKS[*]}"' 2>/dev/null)"
  echo "    effective HOOKS: $eff_hooks"
  if (( ROOT_IS_LUKS )) && [[ $eff_hooks != *sd-encrypt* ]]; then
    die "sd-encrypt missing from effective HOOKS. DO NOT REBOOT. Restore $BACKUP/mkinitcpio.conf.d"
  fi
  (( fail )) && warn "Guards had to be enforced manually - check pacman.conf NoExtract syntax."
  log "Boot configuration intact."
fi

# ------------------------------------------------- Omarchy userspace
PKGFILE=/usr/share/omarchy/install/omarchy-base.packages
if [[ -r $PKGFILE ]]; then
  mapfile -t pkgs < <(grep -vE '^\s*#|^\s*$' "$PKGFILE")
  skip=("${PKG_SKIP[@]}")
  (( MINIMAL )) && skip+=("${PKG_HEAVY[@]}")
  want=()
  for p in "${pkgs[@]}"; do
    keep=1
    for s in "${skip[@]}"; do [[ $p == "$s" ]] && keep=0 && break; done
    (( keep )) && want+=("$p")
  done
  log "Installing Omarchy userspace: ${#want[@]} packages (skipping: ${skip[*]})"
  run "sudo pacman -S --needed --noconfirm ${want[*]}"
elif (( DRYRUN )); then
  echo "   [dry-run] $PKGFILE does not exist yet (it ships inside the omarchy package)."
  echo "   [dry-run] On the real run this installs the full Omarchy userspace"
  echo "   [dry-run] (~148 packages from omarchy-base.packages), skipping: ${PKG_SKIP[*]}"
else
  warn "$PKGFILE not found; skipping userspace package set."
fi

# ------------------------------------------------ session entry
log "Exposing the Omarchy session to your greeter"
run "sudo mkdir -p /usr/share/wayland-sessions"
run "sudo ln -sfn /usr/local/share/wayland-sessions/omarchy.desktop /usr/share/wayland-sessions/omarchy.desktop"

# ------------------------------------------------ user config seeding
log "Seeding your Omarchy user config (only files omarchy-settings owns)"
# BOTH packages ship /etc/skel content. omarchy-settings has the .config files;
# the omarchy package has .local/state/omarchy/migrations - 96 zero-byte markers
# that tell omarchy-migrate a fresh install has nothing to migrate. Missing them
# leaves every migration "pending" and an update would run all of them.
if pacman -Qq omarchy-settings &>/dev/null; then
  seeded=0; kept=()
  while read -r f; do
    [[ -d $f ]] && continue
    rel="${f#/etc/skel/}"; dst="$HOME/$rel"
    if [[ -e $dst ]]; then kept+=("$rel"); continue; fi
    run "mkdir -p '$(dirname "$dst")'"
    run "cp -a '$f' '$dst'"
    seeded=$((seeded+1))
  done < <( { pacman -Qlq omarchy-settings; pacman -Qlq omarchy; } 2>/dev/null \
              | grep '^/etc/skel/' | sort -u )
  log "Seeded $seeded new config file(s) into \$HOME"
  if (( ${#kept[@]} )); then
    warn "Left ${#kept[@]} existing file(s) untouched (yours wins):"
    printf '      ~/%s\n' "${kept[@]}"
    echo  "      Omarchy's versions stay available under /etc/skel/ if you want them."
  fi
elif (( DRYRUN )); then
  echo "   [dry-run] would seed files owned by omarchy-settings from /etc/skel"
else
  warn "omarchy-settings not installed; skipped config seeding."
fi

# ------------------------------------------------------------ done
cat <<EOF

$(log "Done.")

  Log out, and pick "Omarchy (Hyprland uwsm)" at the greeter.
  Plasma is untouched - pick it any time to switch back.

  Rollback:      ./uninstall-omarchy-on-cachyos.sh
  Backups:       $BACKUP
  Snapshot:      bootable from the limine menu (Snapshots)

  NEVER run these - they replace /etc/pacman.conf and delete your CachyOS repos:
      omarchy-update
      omarchy-refresh-pacman
  Update normally instead:  sudo pacman -Syu

EOF
