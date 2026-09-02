#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Tell you when a newer omarchy-on-cachyos has been released, and install it
# when you ask. It never installs anything on its own.
#
#   ./update-omarchy-on-cachyos.sh            # report: what you have, what is out
#   ./update-omarchy-on-cachyos.sh --notify   # one line if an update is waiting
#   ./update-omarchy-on-cachyos.sh --refresh  # ask GitHub now, update the cache
#   ./update-omarchy-on-cachyos.sh --install  # download it and hand it to pacman
#
# After an install, nested sessions still running the old code are closed and one
# is reopened on the new version. --no-restart leaves them alone.
#
# --notify NEVER touches the network. It reads a cache, so a nested window can
# mention an update without a single millisecond of startup delay, and without
# failing to start because GitHub is unreachable. The cache is refreshed in the
# background, at most once a day.
#
# Turn the whole thing off with either:
#   export OMARCHY_OC_NO_UPDATE_CHECK=1
#   touch ~/.config/omarchy-cachyos/no-update-check

set -uo pipefail

REPO="Godless-1/omarchy-on-cachyos"
PKG=omarchy-on-cachyos
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-cachyos/update.json"
OPTOUT="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-cachyos/no-update-check"
MAX_AGE=86400          # a day; a release is not urgent enough to ask more often
MODE=report
RESTART=1

for a in "$@"; do case "$a" in
  --notify) MODE=notify ;;
  --refresh) MODE=refresh ;;
  --install) MODE=install ;;
  --no-restart) RESTART=0 ;;
  -h | --help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 1 ;;
esac; done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

disabled() { [[ -n ${OMARCHY_OC_NO_UPDATE_CHECK:-} || -f $OPTOUT ]]; }

# What is installed, or failing that what this checkout is. pkgrel is dropped so
# 1.4.3.3-1 compares against a 1.4.3.3 tag as equal rather than newer.
current_version() {
  local v
  v=$(pacman -Q "$PKG" 2>/dev/null | awk '{print $2}') || true
  [[ -n ${v:-} ]] || v=$(sed -n 's/^pkgver=//p' "$HERE/PKGBUILD" 2>/dev/null | head -1)
  printf '%s' "${v%%-*}"
}

cache_field() { # cache_field <key>
  [[ -f $CACHE ]] || return 1
  python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    raise SystemExit(1)' "$CACHE" "$1" 2>/dev/null
}

# Ask GitHub. Every failure is silent and non-fatal: no network, rate limited,
# DNS down, garbage JSON - none of that is a reason to bother anyone, and none
# of it may ever stop a window from opening.
refresh_cache() {
  disabled && return 1
  local body tag asset
  body=$(curl -fsSL --max-time 8 \
          -H 'Accept: application/vnd.github+json' \
          "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) || return 1
  [[ -n $body ]] || return 1
  read -r tag asset < <(python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    raise SystemExit(1)
tag = (d.get("tag_name") or "").lstrip("v")
url = ""
for a in d.get("assets") or []:
    if str(a.get("name", "")).endswith(".pkg.tar.zst"):
        url = a.get("browser_download_url") or ""
        break
if not tag:
    raise SystemExit(1)
print(tag, url or "-")' <<<"$body" 2>/dev/null) || return 1
  [[ -n ${tag:-} ]] || return 1

  mkdir -p "$(dirname "$CACHE")"
  local tmp; tmp=$(mktemp "$CACHE.XXXXXX") || return 1
  python3 -c '
import json, sys, time
json.dump({"checked": int(time.time()), "latest": sys.argv[1],
           "asset": ("" if sys.argv[2] == "-" else sys.argv[2])}, open(sys.argv[3], "w"))' \
    "$tag" "$asset" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$CACHE"
}

cache_is_stale() {
  local checked
  checked=$(cache_field checked 2>/dev/null) || return 0
  [[ -n ${checked:-} ]] || return 0
  (( $(date +%s) - checked >= MAX_AGE ))
}

# -1 from vercmp means the installed version is older, so something newer exists.
update_available() { # update_available <current> <latest>
  [[ -n ${2:-} ]] || return 1
  [[ $(vercmp "$1" "$2" 2>/dev/null || echo 0) == "-1" ]]
}

case $MODE in
notify)
  # Cache only. Silent unless there is genuinely something newer, and it names
  # this project explicitly - an unqualified "update available" inside an
  # Omarchy window would read as an Omarchy update, or a system one.
  disabled && exit 0
  latest=$(cache_field latest 2>/dev/null) || exit 0
  cur=$(current_version)
  if update_available "$cur" "${latest:-}"; then
    printf 'omarchy-on-cachyos %s is out (you have %s) - this project, not Omarchy itself\n' \
      "$latest" "$cur"
    printf '            upgrade with:  ooc update\n'
  fi
  exit 0
  ;;

refresh)
  refresh_cache && exit 0 || exit 1
  ;;

report)
  cur=$(current_version)
  log "omarchy-on-cachyos updates"
  if disabled; then
    note "checking is turned off"
    note "  unset OMARCHY_OC_NO_UPDATE_CHECK, or rm $OPTOUT"
    exit 0
  fi
  cache_is_stale && refresh_cache
  latest=$(cache_field latest 2>/dev/null) || latest=""
  note "installed: ${cur:-unknown}"
  if [[ -z $latest ]]; then
    note "latest:    could not ask GitHub just now"
    note "  Not a problem: nothing depends on this check succeeding."
    exit 0
  fi
  note "latest:    $latest"
  if update_available "$cur" "$latest"; then
    note ""
    note "An update to THIS project is available. Omarchy itself updates separately."
    note "  notes:   https://github.com/$REPO/releases/tag/v$latest"
    note "  install: $0 --install"
  else
    note "You are up to date."
  fi
  exit 0
  ;;

install)
  cur=$(current_version)
  cache_is_stale && refresh_cache
  latest=$(cache_field latest 2>/dev/null) || latest=""
  [[ -n $latest ]] || { echo "Could not reach GitHub to find the latest release." >&2; exit 1; }
  if ! update_available "$cur" "$latest"; then
    log "Already on $cur; nothing to install."
    exit 0
  fi
  asset=$(cache_field asset 2>/dev/null) || asset=""
  [[ -n $asset ]] || { echo "Release v$latest has no package attached; build it instead:" >&2
                       echo "  git clone https://github.com/$REPO.git && cd omarchy-on-cachyos && makepkg -si" >&2
                       exit 1; }

  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  log "Downloading omarchy-on-cachyos $latest"
  note "$asset"
  curl -fL --progress-bar --max-time 120 -o "$tmp/pkg.tar.zst" "$asset" || {
    echo "Download failed. Nothing was changed." >&2; exit 1; }

  # Say exactly what is about to be installed, and prove it is what it claims.
  bsdtar -xOf "$tmp/pkg.tar.zst" .PKGINFO 2>/dev/null | grep -E '^(pkgname|pkgver) ' | sed 's/^/    /'
  note "sha256: $(sha256sum "$tmp/pkg.tar.zst" | cut -d' ' -f1)"
  name=$(bsdtar -xOf "$tmp/pkg.tar.zst" .PKGINFO 2>/dev/null | sed -n 's/^pkgname = //p')
  [[ $name == "$PKG" ]] || { echo "That file is not $PKG. Refusing to install it." >&2; exit 1; }

  # Note which sessions are running BEFORE the upgrade: they are still on the
  # old code, so anything they hold - the borrowed Meta+ keys, the PATH shims -
  # belongs to a version that is about to be replaced.
  sessions=()
  while read -r p; do
    [[ -n $p ]] || continue
    ps -o cmd= -p "$p" 2>/dev/null | grep -q 'omarchy-window-.*\.lua' && sessions+=("$p")
  done < <(pgrep -x Hyprland 2>/dev/null || true)

  log "Handing it to pacman - it will ask for your password"
  sudo pacman -U --noconfirm "$tmp/pkg.tar.zst" || {
    echo "pacman refused it. Nothing else was changed." >&2; exit 1; }
  log "Now on $(current_version)."

  (( ${#sessions[@]} )) || exit 0
  if (( ! RESTART )); then
    note "${#sessions[@]} nested session(s) are still running the old code."
    note "  Close and reopen the window to pick this up."
    exit 0
  fi

  # Restarting the session from inside a terminal that lives in that session
  # means killing our own parent, so the work is handed to a detached helper
  # that outlives this script either way. SIGTERM first, so each session's own
  # wrapper hands your keyboard shortcuts back on the way out.
  log "Restarting ${#sessions[@]} nested session(s) on the new version"
  note "your Meta+ shortcuts are returned by each session as it closes"
  # shellcheck disable=SC2016  # the pid list is expanded here on purpose;
  # everything else must stay literal for the detached shell
  setsid bash -c '
    for p in '"${sessions[*]}"'; do kill -TERM "$p" 2>/dev/null; done
    for _ in $(seq 1 20); do
      pgrep -x Hyprland >/dev/null 2>&1 || break
      sleep 1
    done
    for p in '"${sessions[*]}"'; do
      kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    done
    sleep 2
    omarchy-window --bare --detach >/dev/null 2>&1
  ' >/dev/null 2>&1 < /dev/null &
  note "a fresh window will appear in a few seconds"
  ;;
esac
