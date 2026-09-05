#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove uninstall-omarchy-on-cachyos.sh reverses the install.
#
# It was listed as "written, linted, syntax-checked only" from the first release
# to this one - the script the README offers as "undo this project entirely",
# never executed. Running it found that it aborted partway through whenever a
# leftover boot-hazard file existed, which is precisely when it matters.
#
# OC_ROOT prefixes every path and shadows sudo; pacman is replaced by a recorder
# on PATH, so package removal is observed rather than performed.
#
#   ./test/test-uninstall.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/uninstall-omarchy-on-cachyos.sh"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
has()  { local d="$1" pat="$2" hay="$3"
         if grep -qF -- "$pat" <<<"$hay"; then ok "$d"; else
           nope "$d"; printf '        wanted: %s\n' "$pat"; fi; }
gone()    { local d="$1"; if [[ -e $2 ]]; then nope "$d ($2 remains)"; else ok "$d"; fi; }
remains() { local d="$1"; if [[ -e $2 ]]; then ok "$d"; else nope "$d ($2 is gone)"; fi; }

# Refuse to run against anything that is not a fixture. An empty root would send
# every path below at the real /etc.
fixture() { [[ -n ${1:-} && $1 == /tmp/* && -d $1/etc ]] && return 0
            printf '\033[1;31mABORT\033[0m  refusing to run against %s\n' "${1:-<empty>}" >&2
            exit 99; }

new_root() { # new_root [--leftovers]
  local r; r=$(mktemp -d)
  mkdir -p "$r"/{etc/mkinitcpio.conf.d,etc/limine-entry-tool.d,usr/share/wayland-sessions} \
           "$r"/usr/share/omarchy "$r"/home/.claude/skills "$r"/bin
  touch "$r/usr/share/wayland-sessions/omarchy.desktop"
  printf 'HOOKS=(base systemd sd-encrypt filesystems)\n' > "$r/etc/mkinitcpio.conf"
  # shellcheck disable=SC2016  # $arch is literal here, exactly as pacman reads it
  printf '[options]\n# --- omarchy-on-cachyos guards (do not remove) ---\nNoExtract = usr/bin/omarchy-update\n# --- end omarchy-on-cachyos guards ---\nHoldPkg = pacman glibc\n\n[omarchy]\nSigLevel = Required DatabaseOptional\nServer = https://pkgs.omarchy.org/stable/$arch\n\n[cachyos]\nServer = https://mirror\n' \
    > "$r/etc/pacman.conf"
  # Skills: one linked into the Omarchy package, one the user's own.
  mkdir -p "$r/usr/share/omarchy/default/agents/skills/omarchy"
  ln -sfn "$r/usr/share/omarchy/default/agents/skills/omarchy" "$r/home/.claude/skills/omarchy"
  ln -sfn /tmp "$r/home/.claude/skills/mine"
  if [[ " $* " == *" --leftovers "* ]]; then
    printf 'HOOKS=(base udev encrypt)\n' > "$r/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
    printf 'ENABLE_UKI=yes\n'            > "$r/etc/limine-entry-tool.d/omarchy-uki.conf"
  fi
  # A pacman that records rather than acts, so removal is observable.
  cat > "$r/bin/pacman" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${PACMAN_LOG:?}"
case "$1" in
  -Qq) [[ ${FAIL_QUERY:-0} == 1 ]] && exit 1
        [[ -f ${PACMAN_LOG}.removed ]] || printf 'omarchy\nomarchy-settings\n'; exit 0 ;;
  -R) [[ ${FAIL_REMOVAL:-0} == 1 ]] && exit 1
      [[ ${NO_REMOVE:-0} == 1 ]] || touch "${PACMAN_LOG}.removed" ;;
esac
exit 0
EOF
  chmod +x "$r/bin/pacman"
  echo "$r"
}
run() { local r="$1"; shift; fixture "$r"
        # CLAUDE_CONFIG_DIR is cleared deliberately: it is exported by Claude
        # Desktop on the machine this was written on, and left set the skills
        # probe reads that config directory instead of the fixture's.
        OC_ROOT="$r" HOME="$r/home" PACMAN_LOG="$r/pacman.log" CLAUDE_CONFIG_DIR='' \
          PATH="$r/bin:$PATH" "$TOOL" "$@" 2>&1; }

printf '\n\033[1;34m== a clean removal\033[0m\n'

R=$(new_root)
out=$(run "$R"); rc=$?
if (( rc == 0 )); then ok "the uninstall completes"
else nope "it exited $rc"; printf '        %s\n' "$(tail -3 <<<"$out")"; fi
gone    "removes the session entry" "$R/usr/share/wayland-sessions/omarchy.desktop"
if ! grep -q '^\[omarchy\]' "$R/etc/pacman.conf"; then ok "removes the [omarchy] repo"
else nope "the [omarchy] repo is still in pacman.conf"; fi
if ! grep -q 'omarchy-on-cachyos guards' "$R/etc/pacman.conf"; then ok "removes the NoExtract guards"
else nope "the guards block is still in pacman.conf"; fi
if grep -q '^\[cachyos\]' "$R/etc/pacman.conf"; then ok "  and leaves your own repos alone"
else nope "it removed [cachyos] too"; fi
remains "keeps a copy of pacman.conf from before the removal" "$R/etc/pacman.conf.pre-omarchy-removal"
has "asks pacman to remove omarchy" "-R --noconfirm omarchy omarchy-settings" "$(cat "$R/pacman.log")"
has "  and omarchy-settings in the same transaction" "-R --noconfirm omarchy omarchy-settings" "$(cat "$R/pacman.log")"
gone    "unlinks the skill pointing into the Omarchy package" "$R/home/.claude/skills/omarchy"
remains "  and leaves a skill of your own alone" "$R/home/.claude/skills/mine"
rm -rf "$R"

printf '\n\033[1;34m== the leftovers it exists to remove\033[0m\n'

# The regression. `run "sudo rm -f '$f'"` passed one string where every other
# call passes a vector, so it tried to exec a command with that whole name and
# exited 127. Under `set -e` that ended the uninstall on the spot - leaving both
# boot-hazard files it had just warned about still on disk, skipping its own
# sd-encrypt safety check and the database refresh, and finishing with a raw
# "No such file or directory" instead of saying it was done.
R=$(new_root --leftovers)
out=$(run "$R"); rc=$?
if (( rc == 0 )); then ok "completes even with leftovers present"
else nope "aborted with leftovers present (exit $rc)"; fi
gone "removes the initramfs drop-in that breaks a LUKS root" \
  "$R/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
gone "removes the limine drop-in that switches you to UKI" \
  "$R/etc/limine-entry-tool.d/omarchy-uki.conf"
if ! grep -q 'omarchy-on-cachyos guards' "$R/etc/pacman.conf"; then
  ok "  and still gets as far as removing the guards"
else
  nope "  stopped before removing the guards"
fi
rm -rf "$R"

printf '\n\033[1;34m== --keep-apps and --dry-run\033[0m\n'

R=$(new_root)
out=$(run "$R" --keep-apps)
has "--keep-apps says it is leaving the packages" "leaving packages installed" "$out"
if ! grep -q -- '-R ' "$R/pacman.log" 2>/dev/null; then ok "  and asks pacman to remove nothing"
else nope "  but still removed packages"; fi
gone "  while still removing the session entry" "$R/usr/share/wayland-sessions/omarchy.desktop"
rm -rf "$R"

R=$(new_root --leftovers)
sum_before=$(find "$R/etc" "$R/usr" -type f -exec md5sum {} + | sort | md5sum)
run "$R" --dry-run >/dev/null
sum_after=$(find "$R/etc" "$R/usr" -type f -exec md5sum {} + | sort | md5sum)
if [[ $sum_before == "$sum_after" ]]; then ok "--dry-run changes nothing on disk"
else nope "--dry-run modified the tree"; fi
# Querying is allowed - `-Qq` decides whether a package is even installed. What
# a dry run must never do is change anything.
if ! grep -qE -- '-(R|Sy)' "$R/pacman.log" 2>/dev/null; then
  ok "  and asks pacman to change nothing, only to answer"
else
  nope "  but told pacman to act: $(cat "$R/pacman.log")"
fi
rm -rf "$R"

# Previously a failed pacman transaction silently stripped the safeguards.
R=$(new_root)
before=$(cat "$R/etc/pacman.conf")
out=$(FAIL_REMOVAL=1 run "$R"); rc=$?
if (( rc != 0 )); then ok "failed removal exits nonzero"; else nope "failure was swallowed"; fi
remains "failure retains session" "$R/usr/share/wayland-sessions/omarchy.desktop"
if [[ $(cat "$R/etc/pacman.conf") == "$before" ]]; then ok "failure retains repository and guards"; else nope "failure removed protection"; fi
rm -rf "$R"
R=$(new_root)
before=$(cat "$R/etc/pacman.conf")
run "$R" --keep-apps >/dev/null
if [[ $(cat "$R/etc/pacman.conf") == "$before" ]]; then ok "keep-apps retains repository and guards"; else nope "keep-apps removed protection"; fi
rm -rf "$R"
R=$(new_root)
rm "$R/home/.claude/skills/omarchy" "$R/home/.claude/skills/mine"
run "$R" --dry-run >/dev/null
remains "dry-run preserves an empty skills directory" "$R/home/.claude/skills"
rm -rf "$R"

for fault in FAIL_QUERY NO_REMOVE; do
  R=$(new_root)
  before=$(cat "$R/etc/pacman.conf")
  export "$fault=1"
  out=$(run "$R"); rc=$?
  unset "$fault"
  if (( rc != 0 )); then ok "$fault stops uninstall"; else nope "$fault was ignored"; fi
  if [[ $(cat "$R/etc/pacman.conf") == "$before" ]]; then ok "$fault retains safeguards"; else nope "$fault stripped guards"; fi
  remains "$fault retains session" "$R/usr/share/wayland-sessions/omarchy.desktop"
  rm -rf "$R"
done

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
