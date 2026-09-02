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

set -uo pipefail
REBUILD=0; [[ ${1:-} == "--rebuild" ]] && REBUILD=1
PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[1;33mWARN\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
hdr()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

sudo -v || { echo "sudo required"; exit 1; }

hdr "1. Bootloader config not hijacked"
[[ -e /etc/mkinitcpio.conf.d/omarchy_hooks.conf ]] \
  && bad "omarchy_hooks.conf present - it would swap sd-encrypt for encrypt" \
  || ok "no omarchy_hooks.conf"
if compgen -G "/etc/limine-entry-tool.d/omarchy-*" >/dev/null 2>&1; then
  bad "omarchy limine drop-ins present - would switch you to UKI and rename entries"
else ok "no omarchy limine-entry-tool drop-ins"; fi

hdr "2. Effective mkinitcpio HOOKS"
EFF=$(sudo bash -c 'HOOKS=(); MODULES=(); . /etc/mkinitcpio.conf
  for f in /etc/mkinitcpio.conf.d/*.conf; do [ -e "$f" ] && . "$f"; done; echo "${HOOKS[*]}"')
echo "        $EFF"
grep -q 'rd.luks' /proc/cmdline && LUKS=1 || LUKS=0
PLY_THEME=$(grep -i '^Theme=' /etc/plymouth/plymouthd.conf 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
if (( LUKS )); then
  [[ $EFF == *sd-encrypt* ]] && ok "sd-encrypt present (matches rd.luks.uuid= on cmdline)" \
                             || bad "sd-encrypt MISSING but root is LUKS - would not unlock"
  [[ $EFF == *" systemd"* || $EFF == "systemd"* || $EFF == *"base systemd"* ]] \
     && ok "systemd initramfs" || bad "systemd hook missing - rd.luks.uuid= would not be parsed"
  [[ $EFF == *encrypt* && $EFF != *sd-encrypt* ]] && bad "busybox 'encrypt' hook found - wrong for this cmdline"
else ok "root is not LUKS - encryption hooks not required"; fi
[[ $EFF == *sd-btrfs-overlayfs* ]] && ok "sd-btrfs-overlayfs present (limine snapshot boot)" \
                                   || warn "sd-btrfs-overlayfs missing - booting a snapshot may fail"

hdr "3. Actual initramfs on disk"
# Two layouts in the wild:
#   classic mkinitcpio : /boot/initramfs-<kernel>.img
#   kernel-install     : /boot/<entry-token>/<kernel>/initramfs   (CachyOS + limine)
# The entry token defaults to the machine-id. Images under a DIFFERENT token are
# orphans from a previous install - they are never booted, so judging them is noise.
ACTIVE_TOKEN=$(cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id 2>/dev/null)
mapfile -t IMGS < <(sudo find /boot -maxdepth 4 \
  \( -name 'initramfs*.img' -o -name 'initramfs' -o -name 'initrd' \) -type f 2>/dev/null | sort)

# There is NO "Hooks" line in lsinitcpio -a for a systemd image: sd-encrypt is a
# build-time hook that installs systemd-cryptsetup and its units, leaving no runtime
# hook list. Grepping for one reports a false failure, which is worse than no check.
ORPHANS=()
if (( ${#IMGS[@]} == 0 )); then
  warn "no initramfs found under /boot - cannot inspect (UKI-only setup?)"
  sudo ls -la /boot | sed 's/^/        /'
else
  for img in "${IMGS[@]}"; do
    token=$(basename "$(dirname "$(dirname "$img")")")
    label="$(basename "$(dirname "$img")")"
    if [[ -n ${ACTIVE_TOKEN:-} && $token != "$ACTIVE_TOKEN" && ${#token} == 32 ]]; then
      ORPHANS+=("$(dirname "$(dirname "$img")")")
      continue
    fi
    printf '        %s  (%s)\n' "$img" "$(sudo stat -c %y "$img" | cut -d. -f1)"
    LIST=$(sudo lsinitcpio -l "$img" 2>/dev/null)
    if [[ -z $LIST ]]; then
      warn "$label: could not read image - NOT a failure, just uninspectable"; continue
    fi
    if (( LUKS )); then
      if [[ $EFF == *sd-encrypt* ]]; then
        grep -qE 'systemd-cryptsetup-generator|bin/systemd-cryptsetup' <<<"$LIST" \
          && ok "$label: systemd-cryptsetup present (sd-encrypt did its job)" \
          || bad "$label: systemd-cryptsetup ABSENT - root would not unlock"
        grep -qE 'sysinit\.target\.wants/cryptsetup\.target' <<<"$LIST" \
          && ok "$label: cryptsetup.target wired into sysinit.target.wants" \
          || warn "$label: cryptsetup.target not in sysinit.target.wants"
      else
        grep -qE '(^|/)hooks/encrypt$' <<<"$LIST" \
          && ok "$label: busybox encrypt hook present" \
          || bad "$label: no encryption hook found"
      fi
    fi
    if [[ -n ${PLY_THEME:-} ]]; then
      grep -q "plymouth/themes/${PLY_THEME}/" <<<"$LIST" \
        && ok "$label: plymouth theme '${PLY_THEME}' baked in" \
        || warn "$label: plymouth theme '${PLY_THEME}' not in this image (text prompt fallback)"
    fi
  done
  if (( ${#ORPHANS[@]} )); then
    printf '        active entry token: %s\n' "${ACTIVE_TOKEN:-unknown}"
    while read -r o; do
      printf '        orphaned (not booted, not judged): %s  [%s]\n' "$o" "$(sudo du -sh "$o" 2>/dev/null | cut -f1)"
    done < <(printf '%s\n' "${ORPHANS[@]}" | sort -u)
    echo   "        reclaim with: ./clean-stale-boot-entries.sh"
  fi
fi

hdr "4. Kernel cmdline vs initramfs capability"
echo "        $(cat /proc/cmdline)"
if (( LUKS )); then
  grep -q 'rd.luks.uuid=' /proc/cmdline && ok "cmdline uses systemd-style rd.luks.uuid=" \
                                        || warn "cmdline does not use rd.luks.uuid="
  U=$(sed -n 's/.*rd.luks.uuid=\([0-9a-f-]*\).*/\1/p' /proc/cmdline)
  sudo blkid | grep -qi "$U" && ok "LUKS UUID $U exists on disk" || bad "LUKS UUID $U not found"
fi

hdr "5. Plymouth (renders the LUKS prompt)"
T="$PLY_THEME"
echo "        configured theme: ${T:-<none>}"
if [[ -n $T ]]; then
  [[ -d /usr/share/plymouth/themes/$T ]] && ok "theme '$T' exists on disk" \
    || bad "theme '$T' NOT installed - plymouth may fail at the passphrase prompt"
fi
echo "        NOTE: the initramfs carries its own copy of plymouthd.conf + theme."
echo "              A theme change only takes effect on the next initramfs rebuild,"
echo "              at which point both are copied together."

hdr "6. Bootloader entries"
for c in /boot/limine.conf /boot/EFI/limine/limine.conf /boot/limine.cfg; do
  sudo test -e "$c" && { echo "        found $c"; sudo grep -cE '^/|^:' "$c" 2>/dev/null \
    | xargs -I{} echo "        entries: {}"; break; }
done
sudo test -d /boot/EFI && ok "EFI directory present" || warn "no /boot/EFI"

hdr "7. Rollback available"
if command -v snapper >/dev/null; then
  N=$(sudo snapper -c root list 2>/dev/null | tail -n +3 | wc -l)
  (( N > 0 )) && ok "$N snapper snapshots (bootable from the limine menu)" || warn "no snapshots"
fi

if (( REBUILD )); then
  hdr "8. Regenerating initramfs (config verified above)"
  if (( FAIL > 0 )); then
    bad "refusing to rebuild while checks are failing - fix them first"
  else
    if command -v limine-mkinitcpio >/dev/null && [[ ! -d /etc/mkinitcpio.d || -z $(ls -A /etc/mkinitcpio.d 2>/dev/null) ]]; then
      echo "        no mkinitcpio presets; this is a limine + kernel-install system"
      sudo limine-mkinitcpio && ok "limine-mkinitcpio succeeded" || bad "limine-mkinitcpio FAILED - do not reboot"
    else
      sudo mkinitcpio -P && ok "mkinitcpio -P succeeded" || bad "mkinitcpio -P FAILED - do not reboot"
    fi
    mapfile -t IMGS < <(sudo find /boot -maxdepth 4 \
      \( -name 'initramfs*.img' -o -name 'initramfs' -o -name 'initrd' \) -type f 2>/dev/null | sort)
    if (( LUKS )) && command -v lsinitcpio >/dev/null; then
      for img in "${IMGS[@]}"; do
        sudo lsinitcpio -a "$img" 2>/dev/null | grep -qi 'sd-encrypt' \
          && ok "$(basename "$img"): sd-encrypt present after rebuild" \
          || bad "$(basename "$img"): sd-encrypt MISSING after rebuild - DO NOT REBOOT"
      done
    fi
  fi
fi

printf '\n\033[1;34m== Verdict\033[0m\n'
printf '  passed: %d   warnings: %d   failures: %d\n\n' "$PASS" "$WARN" "$FAIL"
if (( FAIL > 0 )); then
  printf '  \033[1;31mDO NOT REBOOT.\033[0m Paste this output for help.\n\n'; exit 1
fi
printf '  \033[1;32mSafe to reboot.\033[0m\n\n'
