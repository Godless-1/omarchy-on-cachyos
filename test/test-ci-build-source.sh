#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Prove .github/build-from-checkout.sh points the package build at the commit
# under test.
#
# The PKGBUILD pins its source to `#tag=v$pkgver`. That tag exists only after the
# Release workflow publishes it, so every commit that bumps the version used to
# fail the package job with `fatal: invalid reference` - an expected red, which
# is the perfect place for a real breakage to hide.
#
# Building the package end to end needs makepkg and a non-root user, neither of
# which this suite has. The package job itself is that proof. What is checked
# here is the contract the job depends on: the source ends up absolute, local,
# and tagged, and the script refuses rather than guesses when anything is off.
#
#   ./test/test-ci-build-source.sh

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TOOL="$HERE/.github/build-from-checkout.sh"
PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
nope() { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }

# `A && ok || nope` reports a pass and a fail when ok itself fails, so every
# assertion goes through one of these instead.
has()     { local d="$1" pat="$2" hay="$3"
            if grep -qF -- "$pat" <<<"$hay"; then ok "$d"; else nope "$d -- got: $hay"; fi; }
refuses() { local d="$1"; shift
            if "$@" >/dev/null 2>&1; then nope "$d -- it accepted this"; else ok "$d"; fi; }

# A checkout shaped like this repository's, at a version with no published tag.
new_checkout() {
  local d; d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  cat > "$d/PKGBUILD" <<'EOF'
pkgname=omarchy-on-cachyos
pkgver=9.9.9
url="https://github.com/Godless-1/omarchy-on-cachyos"
source=("$pkgname-$pkgver::git+$url.git#tag=v$pkgver")
EOF
  git -C "$d" add -A; git -C "$d" commit -qm init
  echo "$d"
}

printf '\n\033[1;34m== rewriting the source\033[0m\n'

D=$(new_checkout)
out=$("$TOOL" "$D" 2>&1); rc=$?
src=$(sed -n 's/^source=//p' "$D/PKGBUILD")
if (( rc == 0 )); then ok "succeeds on a well-formed checkout"
else nope "exited $rc"; printf '        %s\n' "$out"; fi
has "source points at the checkout by absolute path" "git+file://$D#" "$src"
if git -C "$D" rev-parse -q --verify refs/tags/v9.9.9 >/dev/null; then
  ok "creates the tag locally, so makepkg can resolve it"
else nope "no local tag v9.9.9"; fi
# shellcheck disable=SC2016  # the literal PKGBUILD text, not something to expand
has "leaves the tag reference intact rather than hardcoding a version" 'tag=v$pkgver' "$src"
rm -rf "$D"

# The bug this file exists for: `.` produced `git+file://.`, which git rejects
# with "no path specified". Passing a relative path must still yield an absolute
# URL. Caught by running the build, not by reading the script.
D=$(new_checkout)
( cd "$D" && "$TOOL" . >/dev/null 2>&1 )
src=$(sed -n 's/^source=//p' "$D/PKGBUILD")
has "a relative argument still yields an absolute file:// URL" "git+file://$D#" "$src"
rm -rf "$D"

# Idempotence matters: a re-run in the same checkout must not rewrite an already
# rewritten source into nonsense, and must move the tag to the current commit.
D=$(new_checkout)
"$TOOL" "$D" >/dev/null 2>&1
before=$(sed -n 's/^source=//p' "$D/PKGBUILD")
echo x > "$D/x"; git -C "$D" add -A; git -C "$D" commit -qm second
"$TOOL" "$D" >/dev/null 2>&1; rc=$?
after=$(sed -n 's/^source=//p' "$D/PKGBUILD")
if (( rc != 0 )); then
  ok "refuses a second run rather than corrupting an already-rewritten source"
elif [[ $before == "$after" ]]; then
  ok "a second run leaves the source unchanged"
else
  nope "a second run changed the source: $after"
fi
rm -rf "$D"

printf '\n\033[1;34m== refusing to guess\033[0m\n'

D=$(new_checkout)
sed -i 's|^source=.*|source=("some-tarball.tar.gz")|' "$D/PKGBUILD"
refuses "refuses a source that is not the expected git+\$url.git form" "$TOOL" "$D"
rm -rf "$D"

D=$(new_checkout); sed -i '/^pkgver=/d' "$D/PKGBUILD"
refuses "refuses a PKGBUILD with no pkgver" "$TOOL" "$D"
rm -rf "$D"

D=$(mktemp -d); printf 'pkgver=1\n' > "$D/PKGBUILD"
refuses "refuses a directory that is not a git checkout" "$TOOL" "$D"
rm -rf "$D"

D=$(mktemp -d); git -C "$D" init -q
refuses "refuses a checkout with no PKGBUILD" "$TOOL" "$D"
rm -rf "$D"

printf '\n\033[1;34m== results\033[0m\n'
printf '  passed: %d   failed: %d\n\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
