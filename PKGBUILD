# SPDX-FileCopyrightText: 2026 Godless-1
# SPDX-License-Identifier: AGPL-3.0-or-later
# Maintainer: Godless-1 <19769978+Godless-1@users.noreply.github.com>

pkgname=omarchy-on-cachyos
pkgver=1.3.0
pkgrel=1
pkgdesc="Run Omarchy in a window or as a login session beside your existing desktop, without touching your bootloader, initramfs or repos"
arch=('any')
url="https://github.com/Godless-1/omarchy-on-cachyos"
license=('AGPL-3.0-or-later' 'CC-BY-SA-4.0')
# curl and libarchive arrive with base/pacman and are not declared. bash is
# declared because namcap resolves the shebangs to it; hicolor-icon-theme owns
# the directory hierarchy the icon is installed into; python is invoked from
# heredocs to edit kwinrulesrc and pacman.conf structurally rather than with
# fragile sed, which namcap cannot see from a static scan; glib2 provides the
# gdbus that omarchy-window-shortcuts talks to KDE with.
depends=('bash' 'python' 'hicolor-icon-theme' 'glib2')
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
sha256sums=('84edc13409b51312a6a8aef0b738f4b4cdb554a579a01224d7d747148f7a1528')

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
  'omarchy-window-shortcuts:omarchy-window-shortcuts'
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
  for f in omarchy-on-cachyos omarchy-window omarchy-window-shortcuts *.sh; do
    install -Dm755 "$f" "$pkgdir$_libdir/$f"
  done

  install -dm755 "$pkgdir/usr/bin"
  local pair cmd target
  for pair in "${_cmds[@]}"; do
    cmd=${pair%%:*}; target=${pair#*:}
    [[ -f $pkgdir$_libdir/$target ]] || { echo "missing $target" >&2; return 1; }
    ln -sf "$_libdir/$target" "$pkgdir/usr/bin/$cmd"
  done

  install -Dm644 docs/icons/omarchy-on-cachyos.svg \
    "$pkgdir/usr/share/icons/hicolor/scalable/apps/omarchy-on-cachyos.svg"
  install -Dm644 /dev/stdin "$pkgdir/usr/share/applications/omarchy-on-cachyos.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Omarchy on CachyOS
GenericName=Omarchy setup and health checks
Comment=Install, guard, verify and repair an Omarchy install alongside your desktop
Exec=omarchy-on-cachyos
Icon=omarchy-on-cachyos
Terminal=true
Categories=System;Settings;PackageManager;
Keywords=omarchy;hyprland;pacman;boot;initramfs;
StartupNotify=false
DESKTOP

  install -Dm644 README.md      "$pkgdir/usr/share/doc/$pkgname/README.md"
  install -Dm644 PROVENANCE.md  "$pkgdir/usr/share/doc/$pkgname/PROVENANCE.md"
  install -Dm644 LICENSING.md   "$pkgdir/usr/share/doc/$pkgname/LICENSING.md"
  for d in docs/*.md; do
    install -Dm644 "$d" "$pkgdir/usr/share/doc/$pkgname/$d"
  done

  for t in test/*.sh; do
    install -Dm755 "$t" "$pkgdir$_libdir/$t"
  done

  install -Dm644 LICENSES/AGPL-3.0-or-later.txt \
    "$pkgdir/usr/share/licenses/$pkgname/AGPL-3.0-or-later.txt"
  install -Dm644 LICENSES/CC-BY-SA-4.0.txt \
    "$pkgdir/usr/share/licenses/$pkgname/CC-BY-SA-4.0.txt"
}
