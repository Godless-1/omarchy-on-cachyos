#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove the nested Hyprland config omarchy-window generates says what it should,
# and that SUPER+Q is really bound to an exit.
#
# The bindings this adds are otherwise only observable by starting a desktop, so
# omarchy-window grew --print-config: it generates the config, prints it, and
# stops - no compositor, no KWin rule, no borrowed keys.
#
#   ./test/test-window-config.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/omarchy-window"
PASS=0; FAIL=0; SKIP=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
# Not a pass. A skip that counted as one is how a suite goes green on a machine
# where the thing it checks was never run.
skip() { printf '  \033[1;33mSKIP\033[0m  %s\n' "$*"; SKIP=$((SKIP+1)); }
has()  { local d="$1" pat="$2" hay="$3"
         if grep -qF -- "$pat" <<<"$hay"; then ok "$d"; else
           nope "$d"; printf '        wanted: %s\n' "$pat"; fi; }

WORK=$(mktemp -d)
# A private XDG_RUNTIME_DIR, so anything the run leaves behind is visible.
export XDG_RUNTIME_DIR="$WORK/run"; mkdir -p "$XDG_RUNTIME_DIR"

CFG=$("$TOOL" --print-config -s 1280x800 2>/dev/null); rc=$?

printf '\n\033[1;34m== the generated config\033[0m\n'

if (( rc == 0 )) && [[ -n $CFG ]]; then ok "--print-config prints a config and exits 0"
else nope "--print-config exited $rc"; fi

has "binds SUPER + Q" 'o.bind("SUPER + Q"' "$CFG"
has "  to Hyprland's own exit dispatcher, not a shell command" 'hl.dsp.exit()' "$CFG"
has "  and says what it does, for SUPER+K to list" 'Quit this Omarchy window' "$CFG"

# Omarchy's bindings must load first, or ours is overwritten by them rather than
# added to them.
binds_at=$(grep -n 'hypr.bindings' <<<"$CFG" | head -1 | cut -d: -f1)
superq_at=$(grep -n 'SUPER + Q' <<<"$CFG" | head -1 | cut -d: -f1)
if [[ -n $binds_at && -n $superq_at ]] && (( superq_at > binds_at )); then
  ok "adds the bind after Omarchy's own bindings, so it is not overwritten"
else
  nope "bind order wrong: bindings at ${binds_at:-?}, SUPER+Q at ${superq_at:-?}"
fi

# Omarchy binds these; overriding either would be taking a key that is in use.
for taken in 'SUPER + W' 'SUPER + CTRL + Q'; do
  if grep -qF "o.bind(\"$taken\"" <<<"$CFG"; then
    nope "config rebinds $taken, which Omarchy already uses"
  else
    ok "leaves $taken to Omarchy"
  fi
done

printf '\n\033[1;34m== no side effects\033[0m\n'

# --print-config must not borrow keys, write a KWin rule, or leave a PATH shim.
leftover=$(find "$XDG_RUNTIME_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
if (( leftover == 0 )); then ok "leaves nothing behind in XDG_RUNTIME_DIR"
else nope "left $leftover entries in XDG_RUNTIME_DIR"; find "$XDG_RUNTIME_DIR" -mindepth 1 -maxdepth 1; fi

printf '\n\033[1;34m== the dispatcher is real\033[0m\n'

# Hyprland decides Lua-vs-legacy by file extension, so the fixture must end .lua
# - without that it parses as the old format and every config looks invalid.
if command -v Hyprland >/dev/null 2>&1; then
  printf '%s\n' "$CFG" > "$WORK/nested.lua"
  if Hyprland --verify-config -c "$WORK/nested.lua" >/dev/null 2>&1; then
    ok "Hyprland accepts the generated config"
  else
    nope "Hyprland rejects the generated config"
  fi
  # Control: if a typo passed too, the check above would prove nothing.
  sed 's/hl\.dsp\.exit()/hl.dsp.nosuchthing()/' "$WORK/nested.lua" > "$WORK/bad.lua"
  if Hyprland --verify-config -c "$WORK/bad.lua" >/dev/null 2>&1; then
    nope "Hyprland accepts an unknown dispatcher, so the check above means nothing"
  else
    ok "  and rejects an unknown dispatcher, so that check has teeth"
  fi
else
  skip "Hyprland not installed - cannot verify the dispatcher here"
fi

printf '\n\033[1;34m== survives a host without KDE\033[0m\n'

# The QDBUS lookup ends on a failed `command -v` when no qdbus is installed, and
# an unguarded command substitution takes that status - so `set -e` killed the
# script there, silently, before printing anything. omarchy-window had therefore
# never started on a host without qdbus, while its own error text offered advice
# for that case. This machine has qdbus, so only CI (which does not) exercises
# the real path; the guard here is that the fix cannot be quietly removed.
# shellcheck disable=SC2016  # the literal source text, not something to expand
qline=$(grep -n 'QDBUS=\$(' "$HERE/omarchy-window" | head -1)
if [[ $qline == *"|| true"* ]]; then
  ok "the qdbus lookup cannot abort the script when qdbus is absent"
else
  nope "QDBUS assignment lost its '|| true': $qline"
fi

printf '\n\033[1;34m== the documentation cannot go stale\033[0m\n'

# The README used to state plainly that SUPER+Q was unbound. Adding the bind made
# that false, and nothing would have caught it.
readme=$(cat "$HERE/README.md")
if grep -qF 'kbd>Q</kbd>' <<<"$readme"; then ok "README documents SUPER+Q"
else nope "config binds SUPER+Q but the README never mentions it"; fi
if grep -qE '<kbd>Q</kbd>[^|]*is \*\*not\*\* bound' <<<"$readme"; then
  nope "README still claims SUPER+Q is not bound"
else
  ok "  and no longer claims it is unbound"
fi
if grep -qF 'SUPER+Q' "$HERE/omarchy-window"; then ok "omarchy-window --help mentions it"
else nope "omarchy-window's own help does not mention SUPER+Q"; fi

rm -rf "$WORK"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d   skipped: %d\n\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
