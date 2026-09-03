#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Verify this machine will boot after the Omarchy install.
#
#   ./verify-reboot-safety.sh            # read-only checks
#   ./verify-reboot-safety.sh --rebuild  # also regenerate the initramfs and re-verify
#
# The critical chain: LUKS root -> systemd initramfs -> sd-encrypt understands
# rd.luks.uuid= on the kernel cmdline. If any link breaks, root cannot unlock.
#
# Every failure prints how to undo or repair it. Nothing here changes the system
# unless you pass --rebuild.

set -uo pipefail

REBUILD=0
case "${1:-}" in
  --rebuild) REBUILD=1 ;;
  -h|--help) sed -n '5,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac

PASS=0; FAIL=0; WARN=0
FIXES=()

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); return 0; }
warn() { printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); return 0; }
hdr()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; return 0; }
# bad <message> [remediation lines...] - the remediation is printed inline AND
# collected for the verdict, so it is impossible to miss a failure's fix.
bad() {
  local msg="$1"; shift
  printf '  \033[1;31mFAIL\033[0m  %s\n' "$msg"; FAIL=$((FAIL+1))
  local line
  for line in "$@"; do printf '        \033[1;36m->\033[0m %s\n' "$line"; done
  FIXES+=("$msg")
  for line in "$@"; do FIXES+=("    $line"); done
  return 0
}

latest_backup() {
  local d
  d=$(find "$HOME/.local/share/omarchy-cachyos" -maxdepth 1 -type d -name 'backup-*' 2>/dev/null | sort | tail -1)
  [[ -n $d ]] && echo "$d" || echo "$HOME/.local/share/omarchy-cachyos/backup-<timestamp>"
}
BACKUP=$(latest_backup)

sudo -v || { echo "sudo required - this script only reads, but /boot is root-only"; exit 1; }

# --------------------------------------------------------------- 1
hdr "1. Bootloader config not hijacked"
if [[ -e /etc/mkinitcpio.conf.d/omarchy_hooks.conf ]]; then
  bad "omarchy_hooks.conf present - it would swap sd-encrypt for encrypt" \
      "Remove it now:  sudo rm /etc/mkinitcpio.conf.d/omarchy_hooks.conf" \
      "Stop it returning:  ./block-omarchy-updates.sh  (adds the NoExtract guard)" \
      "Do NOT run mkinitcpio until it is gone."
else ok "no omarchy_hooks.conf"; fi

if compgen -G "/etc/limine-entry-tool.d/omarchy-*" >/dev/null 2>&1; then
  bad "omarchy limine drop-ins present - would switch you to UKI and rename entries" \
      "Remove them:  sudo rm /etc/limine-entry-tool.d/omarchy-*.conf" \
      "Then regenerate entries:  sudo limine-update   (or sudo limine-mkinitcpio)" \
      "Stop them returning:  ./install-omarchy-on-cachyos.sh  (rewrites the NoExtract guards)"
else ok "no omarchy limine-entry-tool drop-ins"; fi

# limine-entry-tool titles its top-level OS entry from NAME/PRETTY_NAME in
# /etc/os-release, and keys on that title. Change the distribution identity -
# which is exactly what Omarchy does, and what preserve-cachyos-identity.sh
# undoes - and the next kernel event does not rename the existing entry: it
# writes a brand new one and abandons the old. The abandoned block keeps the
# hashes it had on the day it was orphaned, so with ENABLE_VERIFICATION=yes it
# stops matching the initramfs on disk and refuses to boot, while the menu still
# offers it. One machine, two OS entries, and the good-looking one is the dead one.
MID=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id 2>/dev/null || true)
if [[ -n ${MID:-} ]] && sudo test -f /boot/limine.conf 2>/dev/null; then
  # Count entries that can actually boot this machine, not comments that mention
  # it. The first version of this counted unindented `comment: machine-id=`
  # lines, which was a proxy and a bad one: removing an OS entry can leave the
  # comment that preceded it behind, and the check then reported a duplicate
  # that no longer existed. What makes a top-level entry this machine's is that
  # something under it loads from boot():/<machine-id>/ - so count those.
  # Top-level entries start with a single unindented slash; every sub-entry
  # uses two or more, or is indented, so snapshots fold into their parent.
  OSN=$(sudo awk -v mid="$MID" '
    /^\/[^\/]/            { name = $0; next }
    index($0, "boot():/" mid "/") { if (name != "") hit[name] = 1 }
    END                   { print length(hit) + 0 }
  ' /boot/limine.conf 2>/dev/null || true)
  OSN=${OSN:-0}
  if (( OSN > 1 )); then
    # A warning, not a failure, and the distinction is the whole point: the live
    # entry boots. Calling bad() here would print DO NOT REBOOT above a paragraph
    # explaining that rebooting is fine, which is how a checker teaches people to
    # stop reading it.
    warn "$OSN top-level boot entries claim this machine - only one can be current"
    echo "        The extra ones were orphaned when your distribution name changed. They"
    echo "        keep the hashes they had that day, so they fail verification and error"
    echo "        out instead of booting. Your live entry is untouched - this is a"
    echo "        warning, not a failure, and rebooting is safe."
    echo "        -> See which is which:      sudo limine-entry-tool --tree"
    echo "                                    the live one lists your newest snapshot"
    echo "        -> Remove a stale one by name, which is unambiguous:"
    echo "             sudo limine-remove-entry '<name exactly as --tree prints it>'"
    echo "        -> Then regenerate:         sudo limine-update"
  elif (( OSN == 1 )); then
    ok "one boot entry for this machine (no orphaned duplicates)"
  else
    warn "could not find a top-level boot entry for this machine-id in limine.conf"
    echo "        -> not necessarily wrong; check by hand:  sudo limine-entry-tool --tree"
  fi
fi

# --------------------------------------------------------------- 2
hdr "2. Effective mkinitcpio HOOKS"
EFF=$(sudo bash -c 'HOOKS=(); MODULES=(); . /etc/mkinitcpio.conf
  for f in /etc/mkinitcpio.conf.d/*.conf; do [ -e "$f" ] && . "$f"; done; echo "${HOOKS[*]}"')
echo "        $EFF"

LUKS=0
grep -q 'rd.luks' /proc/cmdline && LUKS=1
PLY_THEME=$(grep -i '^Theme=' /etc/plymouth/plymouthd.conf 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')

if (( LUKS )); then
  if [[ $EFF == *sd-encrypt* ]]; then
    ok "sd-encrypt present (matches rd.luks.uuid= on cmdline)"
  else
    bad "sd-encrypt MISSING but root is LUKS - would not unlock" \
        "Restore your hook drop-ins:  sudo cp -a $BACKUP/mkinitcpio.conf.d/. /etc/mkinitcpio.conf.d/" \
        "Restore the base config:     sudo cp $BACKUP/mkinitcpio.conf /etc/mkinitcpio.conf" \
        "Check for the culprit:       ls /etc/mkinitcpio.conf.d/  (anything without a NN- prefix sorts last)" \
        "Re-run this script. Do NOT rebuild or reboot until it passes."
  fi
  if [[ $EFF == *" systemd"* || $EFF == "systemd"* ]]; then
    ok "systemd initramfs"
  else
    bad "systemd hook missing - rd.luks.uuid= would not be parsed" \
        "Restore:  sudo cp -a $BACKUP/mkinitcpio.conf.d/. /etc/mkinitcpio.conf.d/" \
        "A drop-in has replaced HOOKS wholesale. Look for a bare 'HOOKS=(...)' assignment."
  fi
  if [[ $EFF == *encrypt* && $EFF != *sd-encrypt* ]]; then
    bad "busybox 'encrypt' hook found - wrong for a rd.luks.uuid= cmdline" \
        "The two are not interchangeable: 'encrypt' expects cryptdevice=UUID=...:name" \
        "Restore:  sudo cp -a $BACKUP/mkinitcpio.conf.d/. /etc/mkinitcpio.conf.d/"
  fi
else
  ok "root is not LUKS - encryption hooks not required"
fi

if [[ $EFF == *sd-btrfs-overlayfs* ]]; then
  ok "sd-btrfs-overlayfs present (limine snapshot boot)"
elif [[ $EFF == *btrfs-overlayfs* ]]; then
  warn "btrfs-overlayfs (busybox form) - snapshot boot expects sd-btrfs-overlayfs here"
  echo "        -> Restore:  sudo cp -a $BACKUP/mkinitcpio.conf.d/. /etc/mkinitcpio.conf.d/"
else
  warn "sd-btrfs-overlayfs missing - booting a snapshot may fail"
  echo "        -> Only matters if you use limine-snapper-sync. Reinstall it to restore the drop-in:"
  echo "           sudo pacman -S limine-snapper-sync"
fi

# --------------------------------------------------------------- 3
# Shared by section 3 and the post-rebuild recheck, so the two can never diverge.
# There is NO "Hooks" line in `lsinitcpio -a` for a systemd image: sd-encrypt is a
# build-time hook that installs systemd-cryptsetup and its units, leaving no runtime
# hook list. Grepping for one reports a false failure, which is worse than no check.
check_image() { # check_image <path> <label> <phase>
  local img="$1" label="$2" phase="$3" list
  list=$(sudo lsinitcpio -l "$img" 2>/dev/null)
  if [[ -z $list ]]; then
    warn "$label: could not read image - NOT a failure, just uninspectable"
    echo "        -> Try manually:  sudo lsinitcpio -l '$img' | head"
    return 0
  fi
  if (( LUKS )); then
    if [[ $EFF == *sd-encrypt* ]]; then
      if grep -qE 'systemd-cryptsetup-generator|bin/systemd-cryptsetup' <<<"$list"; then
        ok "$label: systemd-cryptsetup present$phase"
      else
        bad "$label: systemd-cryptsetup ABSENT$phase - root would not unlock" \
            "DO NOT REBOOT." \
            "Confirm by hand:  sudo lsinitcpio -l '$img' | grep -i cryptsetup" \
            "If the config is right (section 2 passed), rebuild:  sudo limine-mkinitcpio" \
            "If it is still absent, boot a snapper snapshot from the limine menu and restore" \
            "  the pre-install state from $BACKUP"
      fi
      if grep -qE 'sysinit\.target\.wants/cryptsetup\.target' <<<"$list"; then
        ok "$label: cryptsetup.target wired into sysinit.target.wants"
      else
        warn "$label: cryptsetup.target not in sysinit.target.wants"
        echo "        -> Unlock may still work, but rebuild to be sure:  sudo limine-mkinitcpio"
      fi
    else
      if grep -qE '(^|/)hooks/encrypt$' <<<"$list"; then
        ok "$label: busybox encrypt hook present$phase"
      else
        bad "$label: no encryption hook found$phase" \
            "DO NOT REBOOT." \
            "Confirm:  sudo lsinitcpio -l '$img' | grep -E 'hooks/(encrypt|sd-encrypt)'" \
            "Rebuild:  sudo mkinitcpio -P   (or sudo limine-mkinitcpio)"
      fi
    fi
  fi
  if [[ -n ${PLY_THEME:-} ]]; then
    if grep -q "plymouth/themes/${PLY_THEME}/" <<<"$list"; then
      ok "$label: plymouth theme '${PLY_THEME}' baked in"
    else
      warn "$label: plymouth theme '${PLY_THEME}' not in this image"
      echo "        -> Cosmetic only: you get a text passphrase prompt, not a failure."
      echo "           Bake it in with:  sudo limine-mkinitcpio"
    fi
  fi
}

find_images() {
  sudo find /boot -maxdepth 4 \
    \( -name 'initramfs*.img' -o -name 'initramfs' -o -name 'initrd' \) -type f 2>/dev/null | sort
}

hdr "3. Actual initramfs on disk"
# Two layouts: classic mkinitcpio (/boot/initramfs-<kernel>.img) and kernel-install
# (/boot/<entry-token>/<kernel>/initramfs). Images under a token that is not the
# active one are orphans from a previous install - never booted, so not judged.
ACTIVE_TOKEN=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id 2>/dev/null)
mapfile -t IMGS < <(find_images)
ORPHANS=()
if (( ${#IMGS[@]} == 0 )); then
  warn "no initramfs found under /boot - cannot inspect (UKI-only setup?)"
  echo "        -> Not necessarily a problem. Look for a .efi bundle instead:"
  echo "           sudo find /boot -name '*.efi' -maxdepth 4"
  sudo ls -la /boot | sed 's/^/        /'
else
  for img in "${IMGS[@]}"; do
    token=$(basename "$(dirname "$(dirname "$img")")")
    label="$(basename "$(dirname "$img")")"
    if [[ -n ${ACTIVE_TOKEN:-} && $token != "$ACTIVE_TOKEN" && ${#token} == 32 ]]; then
      ORPHANS+=("$(dirname "$(dirname "$img")")"); continue
    fi
    printf '        %s  (%s)\n' "$img" "$(sudo stat -c %y "$img" | cut -d. -f1)"
    check_image "$img" "$label" ""
  done
  if (( ${#ORPHANS[@]} )); then
    printf '        active entry token: %s\n' "${ACTIVE_TOKEN:-unknown}"
    while read -r o; do
      printf '        orphaned (not booted, not judged): %s  [%s]\n' "$o" "$(sudo du -sh "$o" 2>/dev/null | cut -f1)"
    done < <(printf '%s\n' "${ORPHANS[@]}" | sort -u)
    echo   "        reclaim with: ./clean-stale-boot-entries.sh"
  fi
fi

# --------------------------------------------------------------- 4
hdr "4. Kernel cmdline vs initramfs capability"
echo "        $(cat /proc/cmdline)"
if (( LUKS )); then
  if grep -q 'rd.luks.uuid=' /proc/cmdline; then
    ok "cmdline uses systemd-style rd.luks.uuid="
  else
    warn "cmdline does not use rd.luks.uuid= but rd.luks is present"
    echo "        -> Check which syntax your setup expects before changing hooks."
  fi
  U=$(sed -n 's/.*rd.luks.uuid=\([0-9a-f-]*\).*/\1/p' /proc/cmdline)
  if [[ -n $U ]] && sudo blkid | grep -qi "$U"; then
    ok "LUKS UUID $U exists on disk"
  elif [[ -n $U ]]; then
    bad "LUKS UUID $U not found on any block device" \
        "Your cmdline points at a device that is not present." \
        "List what is there:  sudo blkid | grep crypto_LUKS" \
        "Fix the UUID in your bootloader config, then:  sudo limine-update"
  fi
fi

# --------------------------------------------------------------- 5
hdr "5. Plymouth (renders the LUKS prompt)"
echo "        configured theme: ${PLY_THEME:-<none>}"
if [[ -n ${PLY_THEME:-} ]]; then
  if [[ -d /usr/share/plymouth/themes/$PLY_THEME ]]; then
    ok "theme '$PLY_THEME' exists on disk"
  else
    bad "theme '$PLY_THEME' NOT installed - plymouth may fail at the passphrase prompt" \
        "Pick an installed one:  ls /usr/share/plymouth/themes" \
        "Set it:  sudo plymouth-set-default-theme <name>" \
        "Then rebuild:  sudo limine-mkinitcpio" \
        "You can still type your passphrase blind if this breaks - it is not fatal."
  fi
fi
echo "        NOTE: the initramfs carries its own copy of plymouthd.conf + theme."
echo "              A theme change only takes effect on the next initramfs rebuild,"
echo "              at which point both are copied together."

# --------------------------------------------------------------- 6
hdr "6. Bootloader entries"
FOUND_CFG=""
for c in /boot/limine.conf /boot/EFI/limine/limine.conf /boot/limine.cfg /boot/loader/loader.conf; do
  if sudo test -e "$c"; then
    FOUND_CFG="$c"; echo "        found $c"
    echo "        entries: $(sudo grep -cE '^/|^:' "$c" 2>/dev/null || echo '?')"
    break
  fi
done
if [[ -z $FOUND_CFG ]]; then
  warn "no bootloader config found in the usual places"
  echo "        -> Look manually:  sudo ls -la /boot /boot/EFI"
fi
if sudo test -d /boot/EFI; then ok "EFI directory present"; else warn "no /boot/EFI (BIOS boot?)"; fi

# --------------------------------------------------------------- 7
hdr "7. Rollback available"
if command -v snapper >/dev/null; then
  N=$(sudo snapper -c root list 2>/dev/null | tail -n +3 | wc -l)
  if (( N > 0 )); then
    ok "$N snapper snapshots (bootable from the limine menu)"
  else
    warn "no snapper snapshots"
    echo "        -> Take one before changing anything:  sudo snapper -c root create -d 'manual'"
  fi
else
  warn "snapper not installed - no snapshot rollback available"
  echo "        -> Your config backups are still in $BACKUP"
fi

# --------------------------------------------------------------- 8
if (( REBUILD )); then
  hdr "8. Regenerating initramfs (config verified above)"
  if (( FAIL > 0 )); then
    bad "refusing to rebuild while checks are failing" \
        "Rebuilding now would bake a broken configuration into the image you boot." \
        "Fix the failures listed above, re-run without --rebuild until clean, then retry."
  else
    RC=0
    # Presets are not the deciding factor - the bootloader is. limine-mkinitcpio
    # builds the image *and* rewrites the boot entries and their verification
    # hashes; plain `mkinitcpio -P` only builds the image, leaving entries
    # pointing at hashes that no longer match. limine ships
    # /usr/local/bin/mkinitcpio (earlier on PATH than /usr/bin, sudo's
    # secure_path included) purely to warn about that, and it then stops to ask
    # an interactive question that would hang an unattended run. So whenever the
    # limine tooling is present it is the right tool, presets or not.
    if command -v limine-mkinitcpio >/dev/null; then
      echo "        limine system: rebuilding the image and its boot entries together"
      sudo limine-mkinitcpio || RC=$?
      if (( RC == 0 )); then ok "limine-mkinitcpio succeeded"
      else bad "limine-mkinitcpio FAILED (exit $RC)" \
               "DO NOT REBOOT - the image on disk may be half-written." \
               "Read the output above for the failing hook." \
               "Your previous images are unchanged unless it reported copying one." \
               "Recover by booting a snapper snapshot from the limine menu."; fi
    else
      sudo mkinitcpio -P || RC=$?
      if (( RC == 0 )); then ok "mkinitcpio -P succeeded"
      else bad "mkinitcpio -P FAILED (exit $RC)" \
               "DO NOT REBOOT." \
               "Re-run verbosely to see why:  sudo mkinitcpio -P -v" \
               "Recover by booting a snapper snapshot from the limine menu."; fi
    fi
    if (( RC == 0 )); then
      # Re-scan: the rebuild may have written new paths.
      mapfile -t IMGS < <(find_images)
      for img in "${IMGS[@]}"; do
        token=$(basename "$(dirname "$(dirname "$img")")")
        [[ -n ${ACTIVE_TOKEN:-} && $token != "$ACTIVE_TOKEN" && ${#token} == 32 ]] && continue
        check_image "$img" "$(basename "$(dirname "$img")")" " after rebuild"
      done
    fi
  fi
fi

# --------------------------------------------------------------- verdict
printf '\n\033[1;34m== Verdict\033[0m\n'
printf '  passed: %d   warnings: %d   failures: %d\n\n' "$PASS" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
  printf '  \033[1;31mDO NOT REBOOT.\033[0m Everything that failed, and how to fix it:\n\n'
  printf '    %s\n' "${FIXES[@]}"
  cat <<EOF

  General recovery, in increasing order of severity:

    1. Re-run this script after each fix - it is read-only without --rebuild.
    2. Restore the pre-install config:
         sudo cp $BACKUP/mkinitcpio.conf /etc/mkinitcpio.conf
         sudo cp -a $BACKUP/mkinitcpio.conf.d/. /etc/mkinitcpio.conf.d/
         sudo cp $BACKUP/pacman.conf /etc/pacman.conf
    3. Undo this project entirely:
         ./uninstall-omarchy-on-cachyos.sh
    4. Boot a pre-install snapshot from the limine menu (Snapshots submenu).

  If you are reading this from a live USB, the backups are under
  <your-home>/.local/share/omarchy-cachyos/ on the root subvolume.

EOF
  exit 1
fi
if (( WARN > 0 )); then
  printf '  \033[1;32mNo failures.\033[0m %d warning(s) above - nothing blocking, but read them:\n' "$WARN"
  printf '  a warning means a check could not run, or found something non-fatal.\n'
  printf '  Each one prints what to do about it.\n\n'
else
  printf '  \033[1;32mSafe to reboot.\033[0m Every check ran and passed.\n\n'
fi
