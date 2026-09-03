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
#   ./preserve-cachyos-identity.sh --branding      # OPTIONAL, opt-in: also put your
#                                                  # distro's logo in Omarchy's own
#                                                  # About window and screensaver.
#                                                  # Not done by --apply: inside
#                                                  # Omarchy, Omarchy should look
#                                                  # like Omarchy.
#
#   PLYMOUTH_THEME=cachyos-bootanimation ./preserve-cachyos-identity.sh --apply

set -euo pipefail
# shellcheck source=/dev/null   # /etc/os-release is a runtime file, not shipped source

MODE=report
THEME="${PLYMOUTH_THEME:-cachyos}"
BRANDING=/usr/share/libalpm/scripts/cachyos-branding
HOOK=/usr/share/libalpm/hooks/99-restore-distro-identity.hook
HELPER=/usr/local/bin/restore-distro-identity
PACCONF=/etc/pacman.conf
FASTFETCH=etc/fastfetch/config.jsonc

for a in "$@"; do case "$a" in
  --apply) MODE=apply ;; --undo) MODE=undo ;; --branding) MODE=branding ;;
  -h|--help) sed -n '4,17p' "$0" | sed 's/^# \?//'; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 1 ;;
esac; done

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

log "Current identity"
# shellcheck source=/dev/null  # runtime file, not shipped source
printf '      os-release   : %s\n' "$(. /etc/os-release; echo "${PRETTY_NAME:-?} (ID=${ID:-?})")"
printf '      /etc/os-release is a %s\n' "$(test -L /etc/os-release && echo 'symlink -> package file' || echo 'regular file')"
printf '      plymouth     : %s\n' "$(plymouth-set-default-theme 2>/dev/null || echo '?')"
printf '      fastfetch cfg: %s\n' "$(pacman -Qoq /etc/fastfetch/config.jsonc 2>/dev/null || echo 'unowned/absent')"
printf '      identity hook: %s\n' "$(test -f "$HOOK" && echo installed || echo 'not installed')"

# --- optional: put your logo inside Omarchy too -----------------------------
# NOT part of --apply, on purpose. The system files above are global - they are
# what fastfetch, the boot splash and every distro-detection script read, and
# they should say what the distribution actually is. Omarchy's About window and
# screensaver are different: they are Omarchy's own furniture, inside Omarchy,
# and Omarchy should look like itself there.
#
# So this is opt-in, for people who want their distribution's logo in those two
# places as well. --branding does it, --undo puts Omarchy's back.
#
# Nothing here is destructive: Omarchy's originals are copied aside first and
# --undo puts them back byte for byte. A copy of what we generated is kept too,
# so drift can be detected after an update rewrites the live files.
BRAND_DIR="$HOME/.config/omarchy/branding"
BRAND_STATE="${XDG_DATA_HOME:-$HOME/.local/share}/omarchy-cachyos/branding"

brand_source() { # the distribution's own logo, whatever distribution this is
  local id logo f
  # shellcheck source=/dev/null
  id=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
  # shellcheck source=/dev/null
  logo=$(. /etc/os-release 2>/dev/null; echo "${LOGO:-}")
  for f in "/usr/share/icons/$id.svg" "/usr/share/icons/$logo.svg" \
           "/usr/share/pixmaps/$id.svg" "/usr/share/pixmaps/$id.png" \
           "/usr/share/pixmaps/$logo.png"; do
    [[ -f $f ]] && { echo "$f"; return 0; }
  done
  return 1
}

# shellcheck source=/dev/null
# PRETTY_NAME first: it is the short form ("CachyOS"), and a wordmark squeezed
# into 80 columns has no room for NAME's "CachyOS Linux".
brand_name() { . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-${NAME:-Linux}}"; }

apply_session_branding() {
  local src name tmp
  [[ -d $BRAND_DIR ]] || { echo "      no $BRAND_DIR - Omarchy's session files are not here; skipped"; return 0; }
  command -v omarchy-transcode-ascii >/dev/null || {
    echo "      omarchy-transcode-ascii not found; skipped"; return 0; }
  src=$(brand_source) || { echo "      no logo image for this distribution; skipped"; return 0; }
  name=$(brand_name)

  mkdir -p "$BRAND_STATE/original" "$BRAND_STATE/applied"
  # Only capture the originals once, or a second run would record our own art
  # as the thing to restore and --undo would become a no-op.
  local f
  for f in about.txt screensaver.txt; do
    [[ -f $BRAND_DIR/$f && ! -f $BRAND_STATE/original/$f ]] && cp -a "$BRAND_DIR/$f" "$BRAND_STATE/original/$f"
  done

  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  # About: the logo mark, at the size Omarchy's own `branding about image` uses.
  if omarchy-transcode-ascii "$src" "$tmp/about.txt" --width 54 --height 26 >/dev/null 2>&1 \
     && [[ -s $tmp/about.txt ]]; then
    install -m644 "$tmp/about.txt" "$BRAND_DIR/about.txt"
    install -m644 "$tmp/about.txt" "$BRAND_STATE/applied/about.txt"
    echo "      about.txt      <- $src"
  else
    echo "      about.txt      transcode failed; left as it was"
  fi

  # Screensaver: Omarchy's is a wordmark, so render one rather than reuse the
  # mark. Falls back to the mark when ImageMagick is not installed.
  if command -v magick >/dev/null && command -v fc-match >/dev/null; then
    local font; font=$(fc-match -f '%{file}' 'sans-serif:bold' 2>/dev/null || true)
    if [[ -n $font ]] && magick -background black -fill white -font "$font" -pointsize 200 \
         "label:$name" -trim +repage -bordercolor black -border 10 "$tmp/word.png" >/dev/null 2>&1; then
      omarchy-transcode-ascii "$tmp/word.png" "$tmp/saver.txt" --width 80 --mode block --invert >/dev/null 2>&1 || true
    fi
  fi
  [[ -s ${tmp}/saver.txt ]] || omarchy-transcode-ascii "$src" "$tmp/saver.txt" --width 80 --height 20 >/dev/null 2>&1 || true
  if [[ -s $tmp/saver.txt ]]; then
    install -m644 "$tmp/saver.txt" "$BRAND_DIR/screensaver.txt"
    install -m644 "$tmp/saver.txt" "$BRAND_STATE/applied/screensaver.txt"
    echo "      screensaver.txt <- \"$name\" wordmark"
  else
    echo "      screensaver.txt transcode failed; left as it was"
  fi
}

undo_session_branding() {
  local f restored=0
  for f in about.txt screensaver.txt; do
    [[ -f $BRAND_STATE/original/$f ]] || continue
    install -m644 "$BRAND_STATE/original/$f" "$BRAND_DIR/$f" && restored=$((restored + 1))
  done
  if (( restored )); then
    rm -rf "$BRAND_STATE/applied"
    echo "      restored $restored Omarchy branding file(s) exactly as they were"
  else
    echo "      no saved Omarchy branding to restore"
  fi
}

# An update can rewrite the session's art, and re-running the whole identity
# restore for two text files would be absurd - and would ask for a password it
# does not need. This does that part on its own.
if [[ $MODE == branding ]]; then
  log "Re-branding the Omarchy session's About and screensaver"
  apply_session_branding
  log "Done. Undo with: $0 --undo"
  exit 0
fi

if [[ $MODE == report ]]; then
  echo; log "Omarchy session branding"
  if [[ -f $BRAND_STATE/applied/about.txt ]] && cmp -s "$BRAND_STATE/applied/about.txt" "$BRAND_DIR/about.txt"; then
    echo "      About and screensaver show this distribution"
  elif [[ -d $BRAND_DIR ]]; then
    echo "      About and screensaver show Omarchy's own art (the default)"
  else
    echo "      not present on this machine"
  fi
  echo; log "Report only. Re-run with --apply."; exit 0
fi

(( EUID == 0 )) && die "Run as your normal user; it will sudo where needed." "Re-run without sudo:  $0 ${*:-}"
sudo -v || die "sudo required" "Nothing has been changed." "To see current state without sudo:  $0"
[[ -x $BRANDING ]] || die "$BRANDING not found - this script targets CachyOS" "Nothing has been changed." "On another distribution, restore identity with your own tooling, then" "adapt the PostTransaction hook this script installs (see the source)." "Your os-release right now:  grep PRETTY_NAME /etc/os-release"

if [[ $MODE == undo ]]; then
  log "Removing the identity hook"
  sudo rm -f "$HOOK" "$HELPER"
  sudo sed -i "\|^NoExtract = $FASTFETCH\$|d" "$PACCONF"
  log "Restoring Omarchy's own session branding"
  undo_session_branding
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
# shellcheck source=/dev/null  # runtime file, not shipped source
echo "      now: $(. /etc/os-release; echo "$PRETTY_NAME (ID=$ID)")"

# --- 2. plymouth ------------------------------------------------------------
log "Restoring the Plymouth theme"
if [[ -d /usr/share/plymouth/themes/$THEME ]]; then
  sudo plymouth-set-default-theme "$THEME"
  echo "      theme: $(plymouth-set-default-theme)"
  echo "      NOTE: takes effect at the next initramfs rebuild."
else
  warn "theme '$THEME' not installed; leaving as-is"
  echo "      available: $(find /usr/share/plymouth/themes -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
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

# Changing the distribution name is not only cosmetic. limine-entry-tool titles
# its top-level boot entry from NAME/PRETTY_NAME in /etc/os-release and keys on
# that title, so the next kernel event writes a NEW entry under the new name and
# abandons the old one - which then keeps stale verification hashes and quietly
# stops booting while still sitting in the menu. Regenerating now renames the
# entry in one step, instead of leaving a duplicate for the next kernel update
# to create.
if command -v limine-update >/dev/null 2>&1; then
  cat <<'EOF'
  Boot menu: your distribution name just changed, and limine names its boot
             entry after it. Regenerate now so the entry is renamed rather than
             duplicated by the next kernel update:

               sudo limine-update

             Skipping this is not dangerous today - your current entry still
             boots - but you will end up with two entries for one machine, and
             the stale one fails verification. ./verify-reboot-safety.sh now
             detects exactly that.
EOF
fi
