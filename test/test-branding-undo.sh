#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME="$work/home" XDG_DATA_HOME="$work/data"
mkdir -p "$HOME/.config/omarchy/branding" "$XDG_DATA_HOME/omarchy-cachyos/branding/"{original,applied} "$work/bin"
printf '#!/bin/sh\nexit 99\n' > "$work/bin/sudo"
chmod +x "$work/bin/sudo"
export PATH="$work/bin:$PATH"
for flag in --undo --undo-branding; do
  for name in about.txt screensaver.txt; do
    printf 'original\n' > "$XDG_DATA_HOME/omarchy-cachyos/branding/original/$name"
    printf 'custom\n' > "$HOME/.config/omarchy/branding/$name"
  done
  bash "$HERE/preserve-cachyos-identity.sh" "$flag" >/dev/null
  for name in about.txt screensaver.txt; do
    cmp "$XDG_DATA_HOME/omarchy-cachyos/branding/original/$name" "$HOME/.config/omarchy/branding/$name"
  done
  echo "PASS $flag restores both files without sudo"
done
