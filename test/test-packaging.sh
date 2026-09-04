#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Keep the package's own promises consistent with each other.
#
# Every list that names commands has now gone stale at least once: the
# post-install greeting forgot omarchy-window-shortcuts for two releases, then
# forgot omarchy-oc-update straight after that was fixed. Nobody notices,
# because nothing breaks - the command works, it just goes unmentioned. So the
# lists check each other here instead of relying on somebody remembering.
#
#   ./test/test-packaging.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PASS=0; FAIL=0
ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

cmds=$(sed -n "/^_cmds=(/,/^)/p" "$HERE/PKGBUILD" | grep -oE "^  '[a-z-]+" | tr -d " '")
targets=$(sed -n "/^_cmds=(/,/^)/p" "$HERE/PKGBUILD" | grep -oE ":[a-zA-Z0-9._-]+'" | tr -d ":'")

printf '\n\033[1;34m== every shipped command is named in the greeting\033[0m\n'
while read -r c; do
  [[ -n $c ]] || continue
  if grep -q -- "$c" "$HERE/omarchy-on-cachyos.install"; then ok "$c"
  else nope "$c is shipped but the post-install greeting never mentions it"; fi
done <<< "$cmds"

printf '\n\033[1;34m== every command points at a file that exists\033[0m\n'
while read -r t; do
  [[ -n $t ]] || continue
  if [[ -f $HERE/$t ]]; then ok "$t"
  else nope "$t is listed in _cmds but is not in the repository"; fi
done <<< "$targets"

printf '\n\033[1;34m== every command is reachable as an ooc subcommand\033[0m\n'
# ooc <name> should work for each script, with the omarchy-oc- prefix dropped.
while read -r c; do
  [[ -n $c ]] || continue
  case $c in omarchy-on-cachyos | ooc) continue ;; esac
  sub=${c#omarchy-oc-}; sub=${sub#omarchy-}
  if grep -qE "^  ($sub|[a-z|-]*\|$sub|$sub\|[a-z|-]*)\)" "$HERE/omarchy-on-cachyos"; then ok "ooc $sub"
  else nope "ooc $sub is not a subcommand of omarchy-on-cachyos"; fi
done <<< "$cmds"

printf '\n\033[1;34m== no build output in the repository\033[0m\n'
# This has now happened twice. The first time it was 64 makepkg artefacts, which
# made CI rebuild a stale extracted tree; the second was the bare clone the
# git-tag source leaves behind, which slipped in through `git add -A` and broke
# `reuse lint`. Both were invisible in `git status` afterwards, because tracked
# files are not untracked files - which is exactly why a human check missed it
# and why this one is mechanical.
build_junk=$(git -C "$HERE" ls-files \
  | grep -E '^(src|pkg)/|^omarchy-on-cachyos-[0-9]|\.pkg\.tar\.' || true)
if [[ -z $build_junk ]]; then
  ok "no build output is tracked"
else
  nope "build output is tracked in git:"
  while IFS= read -r j; do printf '        %s\n' "$j"; done <<<"$build_junk" | head -8
fi

# The rule that keeps it out. Asserted directly, because the guard above only
# fires after the mistake has already been committed.
for pat in src/ pkg/ 'omarchy-on-cachyos-1.2.3/x'; do
  if git -C "$HERE" check-ignore -q "$pat"; then ok "gitignore covers $pat"
  else nope "gitignore does not cover $pat"; fi
done

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
