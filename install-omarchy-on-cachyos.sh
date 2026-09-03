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
# shellcheck source=/dev/null   # /etc/os-release is a runtime file, not shipped source

CHANNEL=stable
REPO_URL="https://pkgs.omarchy.org/${CHANNEL}/\$arch"
DB_URL="https://pkgs.omarchy.org/${CHANNEL}/x86_64"
KEY_FPR="40DFB630FF42BCFFB047046CF0134EE680CAC571"
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
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

# ------------------------------------------------------- pacman, retried
# A fresh machine pulls ~175 MiB from mirrors it has never spoken to, and
# mirrors misbehave: one 404s for a file the local database still lists,
# another resets the HTTP/2 stream halfway through a 114 MiB package, a third
# times out. pacman then rolls the whole transaction back and the install stops
# with nothing installed, leaving a by-hand re-run as the only way forward.
#
# None of that needs a human. pacman keeps whatever it did retrieve in
# /var/cache/pacman/pkg, so a retry resumes instead of starting over.
PAC_TRIES=${PAC_TRIES:-4}       # attempts per transaction
PAC_BACKOFF=${PAC_BACKOFF:-5}   # seconds before the 2nd attempt, doubled after

# Failures that are worth asking again. Everything not matched here - a file
# conflict, an unknown package, an unsatisfiable dependency - fails identically
# however many times it is asked.
PAC_TRANSIENT='failed retrieving|failed to retrieve|failed to synchronize|download library error|could not resolve host|connection timed out|connection reset|reset by server|transfer closed|operation too slow|temporary failure|timeout was reached'

# Given to every transaction:
#   --noconfirm                 the questions pacman asks here have exactly one
#                               right answer, and nobody may be watching to give it
#   --disable-download-timeout  a 20 KiB/s mirror is slow, not dead; the default
#                               low-speed cutoff throws away the whole transfer
declare -a PAC_OPTS=(--noconfirm --disable-download-timeout)

# pac <pacman arguments...>
# One transaction, retried while the failure is a download failure.
pac() {
  if (( DRYRUN )); then
    printf '   [dry-run] %s\n' "$(printf '%q ' sudo pacman "${PAC_OPTS[@]}" "$@")"
    return 0
  fi
  local err attempt=1 delay=$PAC_BACKOFF dropped f
  err=$(mktemp)
  while :; do
    # stderr alone is captured, so pacman still has a terminal on stdout and
    # keeps drawing its progress bars. sudo prompts on /dev/tty, so a password
    # prompt is not swallowed here either.
    if sudo pacman "${PAC_OPTS[@]}" "$@" 2>"$err"; then
      cat "$err" >&2
      rm -f "$err"
      return 0
    fi
    cat "$err" >&2

    # A cached package that arrived damaged: pacman names the file, deleting it
    # is the documented fix, and the next attempt fetches it again.
    dropped=0
    while read -r f; do
      [[ -n $f ]] || continue
      warn "discarding a corrupted download: $(basename "$f")"
      sudo rm -f "$f" "$f.sig"
      dropped=1
    done < <(grep -E 'invalid or corrupted' "$err" \
               | grep -oE '/var/cache/pacman/pkg/[^ '"'"'"]+' | sort -u)

    if (( ! dropped )) && ! grep -qEi "$PAC_TRANSIENT" "$err"; then
      rm -f "$err"
      die "pacman refused this transaction, and not over a download" \
          "Asking again would fail the same way, so it stops here." \
          "pacman's own error is printed above - it names what it objected to." \
          "Nothing is half-installed: a failed transaction is rolled back whole." \
          "Resolve that, then re-run:  $0 ${SELF_ARGS[*]-}"
    fi

    if (( attempt >= PAC_TRIES )); then
      rm -f "$err"
      die "the mirrors would not hand over every file, after $PAC_TRIES attempts" \
          "Nothing is half-installed: a failed transaction is rolled back whole." \
          "Everything already downloaded is kept, so a re-run resumes:  $0 ${SELF_ARGS[*]-}" \
          "Pick faster mirrors first, if this keeps happening:  sudo cachyos-rate-mirrors" \
          "Or check the link itself:  curl -I $DB_URL/omarchy.db"
    fi

    # A 404 is the signature of local databases that no longer match what the
    # mirror carries. Nothing else fixes that, and nothing else needs it.
    if grep -qE '404|[Nn]ot [Ff]ound' "$err"; then
      warn "a mirror is out of step with the local databases - forcing a refresh"
      sudo pacman "${PAC_OPTS[@]}" -Syy || true
    fi
    warn "download failure (attempt $attempt of $PAC_TRIES) - retrying in ${delay}s, keeping what already arrived"
    sleep "$delay"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
  done
}

# Kept so a recovery hint can hand back the exact command to re-run.
SELF_ARGS=("$@")
for arg in "$@"; do
  case "$arg" in
    --minimal) MINIMAL=1 ;;
    --dry-run) DRYRUN=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown option: $arg" "Valid options: --dry-run, --minimal" "See what it would do:  $0 --dry-run" ;;
  esac
done

(( EUID == 0 )) && die "Run as your normal user, not root. It will sudo where needed." "Re-run without sudo:  $0 ${*:-}" "It needs your HOME to seed configs, which root does not have."
command -v pacman >/dev/null || die "pacman not found - this only works on Arch and its derivatives" "Nothing has been changed."
(( DRYRUN )) || sudo -v || die "sudo required" "Nothing has been changed." "To see what it would do without sudo:  $0 --dry-run"

# One EXIT trap for the whole script: the sudo keepalive below and the keyring's
# scratch directory both hang off it.
KEEPALIVE=""
KEYRING_TMP=""
cleanup() {
  [[ -n $KEEPALIVE ]] && kill "$KEEPALIVE" 2>/dev/null
  [[ -n $KEYRING_TMP ]] && rm -rf "$KEYRING_TMP"
  return 0
}
trap cleanup EXIT

# Keep the sudo timestamp warm. The userspace transaction can spend twenty
# minutes downloading, and the default timestamp expires in five - so without
# this, the step after it stops on a password prompt in a script that had
# otherwise stopped needing anybody.
if ! (( DRYRUN )); then
  ( while sleep 45; do
      kill -0 "$$" 2>/dev/null || exit 0
      sudo -n true 2>/dev/null || exit 0
    done ) &
  KEEPALIVE=$!
fi

# ---------------------------------------------------------------- preflight
log "Preflight"
# shellcheck source=/dev/null  # runtime file, not shipped source
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
run cp -a /etc/pacman.conf "$BACKUP/pacman.conf"
run cp -a /etc/pacman.d/mirrorlist "$BACKUP/mirrorlist"
run cp -a /etc/mkinitcpio.conf "$BACKUP/mkinitcpio.conf"
run cp -a /etc/mkinitcpio.conf.d "$BACKUP/mkinitcpio.conf.d"
run_to "$BACKUP/pkglist-explicit.txt" pacman -Qqe
run_to "$BACKUP/pkglist-all.txt" pacman -Qq
run cp /proc/cmdline "$BACKUP/cmdline.txt"
# The bootloader config is the thing most at risk here and was the one thing not
# copied. It lives on a root-only vfat ESP, so this needs sudo and a plain cp -
# preserving vfat's ownership into $HOME would be wrong even if it worked.
if [[ -r /boot/limine.conf ]] || sudo test -f /boot/limine.conf 2>/dev/null; then
  run_to "$BACKUP/limine.conf" sudo cat /boot/limine.conf
fi

# btrfs + snapper: take a rollback point you can boot from limine.
if (( DRYRUN )); then
  echo "   [dry-run] would create a snapper pre-install snapshot"
elif command -v snapper >/dev/null && sudo snapper list-configs 2>/dev/null | grep -qw root; then
  log "Creating snapper pre-install snapshot"
  run sudo snapper -c root create -d "pre-omarchy $STAMP"
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
  grep -q 'omarchy-on-cachyos guards' /etc/pacman.conf || die "guard insertion failed - refusing to continue without the NoExtract guards" "Nothing has been installed yet, so your system is unchanged." "Restore pacman.conf:  sudo cp $BACKUP/pacman.conf /etc/pacman.conf" "Then check it parses:  pacman-conf >/dev/null && echo ok"
  n=$(grep -c '^NoExtract = ' /etc/pacman.conf)
  log "$n NoExtract guard(s) active"
fi

# ------------------------------------------------------------ keyring
log "Installing the Omarchy signing keyring"
if ! (( DRYRUN )) && sudo pacman-key --list-keys "$KEY_FPR" &>/dev/null; then
  log "Key $KEY_FPR already trusted."
else
  tmp="$(mktemp -d)"; KEYRING_TMP="$tmp"
  curl -fsSL "$DB_URL/omarchy.db" -o "$tmp/omarchy.db" || die "cannot reach $DB_URL" "Nothing has been installed. The guards are in place and harmless." "Check connectivity:  curl -I $DB_URL/omarchy.db" "If you use a VPN, try without it - throttled links time out here." "Remove the guards if you are abandoning the install:  ./block-omarchy-updates.sh --undo"
  bsdtar -xf "$tmp/omarchy.db" -C "$tmp"
  kdesc="$(find "$tmp" -maxdepth 2 -path '*omarchy-keyring-*/desc' | head -1)"
  [[ -n $kdesc ]] || die "omarchy-keyring not found in the repo database" "Nothing has been installed." "The repo layout may have changed upstream. Check:  curl -s $DB_URL/omarchy.db | bsdtar -tf - | grep keyring"
  kfile="$(grep -A1 '^%FILENAME%$' "$kdesc" | tail -1)"
  log "Fetching $kfile"
  curl -fsSL "$DB_URL/$kfile" -o "$tmp/$kfile" || die "keyring download failed" "Nothing has been installed." "Retry, or fetch by hand:  curl -O $DB_URL/<keyring-file>"
  pac -U "$tmp/$kfile"
  if ! (( DRYRUN )); then
    sudo pacman-key --populate omarchy 2>/dev/null || true
    sudo pacman-key --list-keys "$KEY_FPR" &>/dev/null \
      || die "Omarchy key $KEY_FPR not trusted after installing the keyring" "Aborting rather than lowering SigLevel to TrustAll, which would accept unsigned packages." "Inspect:  sudo pacman-key --list-keys | grep -A2 omarchy" "Remove the keyring and start over:  sudo pacman -Rns omarchy-keyring" "Nothing from the [omarchy] repo has been installed."
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
pac -Sy

# ------------------------------------------------------------ install
log "Installing the omarchy package (sddm assumed-installed: your display manager is kept)"
pac -S --needed omarchy --assume-installed sddm \
      --overwrite '/etc/skel/.config/alacritty/*'

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
    die "sd-encrypt missing from effective HOOKS - your LUKS root would not unlock" "*** DO NOT REBOOT until this is resolved. ***" "1. Restore the hook drop-ins:" "     sudo cp -a $BACKUP/mkinitcpio.conf.d/. /etc/mkinitcpio.conf.d/" "     sudo cp $BACKUP/mkinitcpio.conf /etc/mkinitcpio.conf" "2. Find the culprit - a drop-in without a NN- prefix sorts last and can" "   replace HOOKS wholesale:  ls /etc/mkinitcpio.conf.d/" "3. Confirm the fix:  ./verify-reboot-safety.sh" "4. Your existing initramfs on disk is UNCHANGED and still bootable; this" "   only affects the next rebuild. You are safe as long as you do not run" "   mkinitcpio before fixing it." "5. Worst case, boot a pre-install snapshot from the limine menu."
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
  pac -S --needed "${want[@]}"
elif (( DRYRUN )); then
  echo "   [dry-run] $PKGFILE does not exist yet (it ships inside the omarchy package)."
  echo "   [dry-run] On the real run this installs the full Omarchy userspace"
  echo "   [dry-run] (~148 packages from omarchy-base.packages), skipping: ${PKG_SKIP[*]}"
else
  warn "$PKGFILE not found; skipping userspace package set."
fi

# ------------------------------------------------ session entry
log "Exposing the Omarchy session to your greeter"
run sudo mkdir -p /usr/share/wayland-sessions
run sudo ln -sfn /usr/local/share/wayland-sessions/omarchy.desktop \
      /usr/share/wayland-sessions/omarchy.desktop

# ------------------------------------------------ application menu entries
log "Adding application-menu entries"
if [[ -x $SELF_DIR/omarchy-on-cachyos ]]; then
  run "$SELF_DIR/omarchy-on-cachyos" install-desktop
fi
if [[ -x $SELF_DIR/omarchy-window ]]; then
  run "$SELF_DIR/omarchy-window" --install-desktop
fi

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
    run mkdir -p "$(dirname "$dst")"
    run cp -a "$f" "$dst"
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
