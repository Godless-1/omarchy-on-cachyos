# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
# Maintainer: Godless-1 <19769978+Godless-1@users.noreply.github.com>

pkgname=omarchy-on-cachyos
pkgver=1.0.0
pkgrel=1
pkgdesc="Run Omarchy in a window or as a login session beside your existing desktop, without touching your bootloader, initramfs or repos"
arch=('any')
url="https://github.com/Godless-1/omarchy-on-cachyos"
license=('AGPL-3.0-or-later' 'CC-BY-SA-4.0')
depends=('bash' 'pacman' 'curl' 'libarchive' 'python')
optdepends=(
  'gum: styled menu for omarchy-on-cachyos'
  'omarchy: the desktop this manages'
  'hyprland: required for omarchy-window'
  'kscreen: exact work-area fitting for omarchy-window on KDE'
  'snapper: pre-install snapshots'
  'mkinitcpio: initramfs inspection in omarchy-verify-boot'
)
install=omarchy-on-cachyos.install
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('6bb09bf0ee0d9168af5d620c1e9fb70c75df3dedc8a64dc07cb40a28cec8f54f')

# Scripts keep their repository names in /usr/lib, and get short, prefixed
# commands on PATH. Renaming them in place would break every reference in the
# documentation, and bare names like `install-...sh` do not belong in /usr/bin.
# A plain indexed array of "command:target" pairs. An associative array does not
# survive makepkg re-sourcing the PKGBUILD inside fakeroot, and the symlinks are
# silently skipped - the build still succeeds, with an empty /usr/bin.
_libdir=/usr/lib/$pkgname
_cmds=(
  'omarchy-on-cachyos:omarchy-on-cachyos'
  'omarchy-window:omarchy-window'
  'omarchy-oc-install:install-omarchy-on-cachyos.sh'
  'omarchy-oc-uninstall:uninstall-omarchy-on-cachyos.sh'
  'omarchy-oc-block-updates:block-omarchy-updates.sh'
  'omarchy-oc-verify-boot:verify-reboot-safety.sh'
  'omarchy-oc-preserve-identity:preserve-cachyos-identity.sh'
  'omarchy-oc-clean-boot:clean-stale-boot-entries.sh'
)

package() {
  cd "$pkgname-$pkgver"

  install -dm755 "$pkgdir$_libdir"
  for f in omarchy-on-cachyos omarchy-window *.sh; do
    install -Dm755 "$f" "$pkgdir$_libdir/$f"
  done

  install -dm755 "$pkgdir/usr/bin"
  local pair cmd target
  for pair in "${_cmds[@]}"; do
    cmd=${pair%%:*}; target=${pair#*:}
    [[ -f $pkgdir$_libdir/$target ]] || { echo "missing $target" >&2; return 1; }
    ln -sf "$_libdir/$target" "$pkgdir/usr/bin/$cmd"
  done

  install -Dm644 README.md      "$pkgdir/usr/share/doc/$pkgname/README.md"
  install -Dm644 PROVENANCE.md  "$pkgdir/usr/share/doc/$pkgname/PROVENANCE.md"
  install -Dm644 LICENSING.md   "$pkgdir/usr/share/doc/$pkgname/LICENSING.md"
  for d in docs/*.md; do
    install -Dm644 "$d" "$pkgdir/usr/share/doc/$pkgname/$d"
  done

  install -Dm644 LICENSES/AGPL-3.0-or-later.txt \
    "$pkgdir/usr/share/licenses/$pkgname/AGPL-3.0-or-later.txt"
  install -Dm644 LICENSES/CC-BY-SA-4.0.txt \
    "$pkgdir/usr/share/licenses/$pkgname/CC-BY-SA-4.0.txt"
}
