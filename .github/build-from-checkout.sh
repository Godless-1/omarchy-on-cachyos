#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Point a PKGBUILD's git source at the checkout it sits in, so CI builds the
# commit under test rather than a published tag.
#
#   .github/build-from-checkout.sh [<repo-dir>]
#
# The PKGBUILD pins its source to `#tag=v$pkgver`, which only exists once the
# Release workflow has published it. That makes `makepkg` fail with
# `fatal: invalid reference` on every commit that bumps the version - a red CI
# run that is expected, self-resolving, and therefore the perfect place for a
# real breakage to hide.
#
# It is also the wrong thing to build. CI's job is to check *this commit*; a tag
# is by definition something that already shipped. So the source is rewritten to
# the local clone and the tag is created locally at HEAD. The release workflow
# still builds from the real tag, which is where that guarantee belongs.
#
# Only the working copy of PKGBUILD is touched, and only in a CI checkout - the
# change is never committed. Run .SRCINFO validation and `namcap PKGBUILD`
# BEFORE this, while the file still says what the repository says.

set -euo pipefail

# Resolved rather than trusted: a caller passing a relative path would otherwise
# produce `git+file://.`, which git rejects with "no path specified". Found by
# running this end to end rather than by reading it.
repo=$(cd "${1:-$PWD}" && pwd)
cd "$repo"

[[ -f PKGBUILD ]] || { echo "no PKGBUILD in $repo" >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "$repo is not a git checkout" >&2; exit 1; }

ver=$(sed -n 's/^pkgver=//p' PKGBUILD)
[[ -n $ver ]] || { echo "no pkgver in PKGBUILD" >&2; exit 1; }

# Force, because a previous run in the same checkout may have made it already,
# and because a stale tag pointing at an older commit would build the wrong tree.
git tag -f "v$ver" >/dev/null

# The literal text is `git+$url.git`; $url is a PKGBUILD variable, not a shell
# one, so it is matched as the characters it is rather than expanded here.
# shellcheck disable=SC2016  # matching the literal text, not expanding it
if ! grep -qF 'git+$url.git' PKGBUILD; then
  echo "PKGBUILD source is not the expected 'git+\$url.git' form; refusing to guess" >&2
  exit 1
fi
python3 - "$repo" <<'PY'
import pathlib, sys
repo = sys.argv[1]
p = pathlib.Path(repo) / "PKGBUILD"
s = p.read_text()
# file:// needs an absolute path; the caller's argument was resolved above.
p.write_text(s.replace('git+$url.git', f'git+file://{repo}', 1))
PY

echo "building v$ver from this checkout, not from a published tag"
grep -n '^source=' PKGBUILD
