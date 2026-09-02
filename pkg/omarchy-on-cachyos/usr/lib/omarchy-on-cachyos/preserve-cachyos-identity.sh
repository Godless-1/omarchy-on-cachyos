#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Keep your distribution's identity after installing Omarchy.
#
# omarchy-settings has a post-install script that copies etc-overrides/ into /etc,
# replacing /etc/os-release, /etc/plymouth/plymouthd.conf and others. NoExtract
# cannot stop a script, so this restores them and installs a pacman hook that
# re-restores them after every omarchy-settings upgrade.
#
#   ./preserve-cachyos-identity.sh                 # report only
#   ./preserve-cachyos-identity.sh --apply         # restore + install the hook
#   ./preserve-cachyos-identity.sh --undo          # remove the hook, keep Omarchy's
#
#   PLYMOUTH_THEME=cachyos-bootanimation ./preserve-cachyos-identity.sh --apply

set -euo pipefail

MODE=report
THEME="${PLYMOUTH_THEME:-cachyos}"
BRANDING=/usr/share/libalpm/scripts/cachyos-branding
HOOK=/usr/share/libalpm/hooks/99-restore-distro-identity.hook
HELPER=/usr/local/bin/restore-distro-identity
PACCONF=/etc/pacman.conf
FASTFETCH=etc/fastfetch/config.jsonc

for a in "$@"; do case "$a" in
  --apply) MODE=apply ;; --undo) MODE=undo ;;
  -h|--help) sed -n '4,17p' "$0" | sed 's/^# \?//'; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 1 ;;
esac; done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m  %s\n' "$*" >&2; exit 1; }

log "Current identity"
printf '      os-release   : %s\n' "$(. /etc/os-release; echo "${PRETTY_NAME:-?} (ID=${ID:-?})")"
printf '      /etc/os-release is a %s\n' "$(test -L /etc/os-release && echo 'symlink -> package file' || echo 'regular file')"
printf '      plymouth     : %s\n' "$(plymouth-set-default-theme 2>/dev/null || echo '?')"
printf '      fastfetch cfg: %s\n' "$(pacman -Qoq /etc/fastfetch/config.jsonc 2>/dev/null || echo 'unowned/absent')"
printf '      identity hook: %s\n' "$(test -f "$HOOK" && echo installed || echo 'not installed')"

if [[ $MODE == report ]]; then
  echo; log "Report only. Re-run with --apply."; exit 0
fi

(( EUID == 0 )) && die "Run as your normal user; it will sudo where needed."
sudo -v || die "sudo required"
[[ -x $BRANDING ]] || die "$BRANDING not found - this script targets CachyOS"

if [[ $MODE == undo ]]; then
  log "Removing the identity hook"
  sudo rm -f "$HOOK" "$HELPER"
  sudo sed -i "\|^NoExtract = $FASTFETCH\$|d" "$PACCONF"
  log "Done. Omarchy's branding will apply again on its next update."
  exit 0
fi

# --- 1. os-release ----------------------------------------------------------
# cachyos-branding sed-edits /etc/os-release in place, so it must be a real file.
# Left as a symlink it would edit the package-owned /usr/lib/os-release instead.
log "Restoring os-release"
if [[ -L /etc/os-release ]]; then
  sudo cp --remove-destination /usr/lib/os-release /etc/os-release
  echo "      replaced symlink with a real file (cachyos-branding edits in place)"
fi
sudo "$BRANDING" os-release
echo "      now: $(. /etc/os-release; echo "$PRETTY_NAME (ID=$ID)")"

# --- 2. plymouth ------------------------------------------------------------
log "Restoring the Plymouth theme"
if [[ -d /usr/share/plymouth/themes/$THEME ]]; then
  sudo plymouth-set-default-theme "$THEME"
  echo "      theme: $(plymouth-set-default-theme)"
  echo "      NOTE: takes effect at the next initramfs rebuild."
else
  warn "theme '$THEME' not installed; leaving as-is"
  echo "      available: $(ls /usr/share/plymouth/themes | tr '\n' ' ')"
fi

# --- 3. fastfetch -----------------------------------------------------------
# This one IS a package file, so NoExtract genuinely stops it coming back.
log "Removing Omarchy's fastfetch config"
if grep -qxF "NoExtract = $FASTFETCH" "$PACCONF"; then
  echo "      NoExtract already present"
else
  if grep -q '^# --- end omarchy-on-cachyos guards ---$' "$PACCONF"; then
    sudo sed -i "/^# --- end omarchy-on-cachyos guards ---$/i NoExtract = $FASTFETCH" "$PACCONF"
  else
    printf 'NoExtract = %s\n' "$FASTFETCH" | sudo tee -a "$PACCONF" >/dev/null
  fi
  echo "      NoExtract added"
fi
sudo rm -f /etc/fastfetch/config.jsonc
echo "      removed; fastfetch falls back to its default, which reads LOGO= from os-release"

# --- 4. make it durable -----------------------------------------------------
log "Installing a PostTransaction hook so this survives omarchy-settings upgrades"
sudo tee "$HELPER" >/dev/null <<HELPEREOF
#!/usr/bin/env bash
# Installed by preserve-cachyos-identity.sh. Re-asserts distribution identity
# after omarchy-settings' post-install script overwrites it.
set -euo pipefail
[[ -L /etc/os-release ]] && cp --remove-destination /usr/lib/os-release /etc/os-release
[[ -x $BRANDING ]] && "$BRANDING" os-release || true
[[ -x $BRANDING ]] && "$BRANDING" lsb-release 2>/dev/null || true
if [[ -d /usr/share/plymouth/themes/$THEME ]]; then
  plymouth-set-default-theme "$THEME" >/dev/null 2>&1 || true
fi
rm -f /etc/fastfetch/config.jsonc
HELPEREOF
sudo chmod 0755 "$HELPER"

sudo tee "$HOOK" >/dev/null <<HOOKEOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = omarchy-settings
Target = omarchy-settings-dev

[Action]
Description = Restoring distribution identity after Omarchy settings...
When = PostTransaction
Exec = $HELPER
HOOKEOF
echo "      $HOOK"
echo "      $HELPER"

cat <<EOF

$(log "Done.")

  Verify:   fastfetch
  Boot art: the Plymouth change needs an initramfs rebuild -
              sudo limine-mkinitcpio
            or ./verify-reboot-safety.sh --rebuild

  Undo:     $0 --undo
EOF
