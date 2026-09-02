<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Troubleshooting

Real failures encountered bringing Omarchy up on a populated CachyOS system, and their fixes.

---

## `error: failed to commit transaction (conflicting files)`

```text
omarchy-settings: /etc/skel/.config/alacritty/alacritty.toml exists in filesystem
                  (owned by cachyos-alacritty-config)
```

**Do not remove the CachyOS package.** `cachyos-alacritty-config` is `Required By:
cachyos-kde-settings` — removing it cascades into your Plasma configuration.

The file only affects *newly created users*, so skipping it costs nothing:

```ini
NoExtract = etc/skel/.config/alacritty/*
```

The installer also passes `--overwrite '/etc/skel/.config/alacritty/*'`, because the manual
does not promise that `NoExtract` suppresses the **conflict check** — only extraction. With
both, the transaction proceeds and the CachyOS file is never overwritten.

Find every such conflict before installing:

```bash
bsdtar -tf <package>.pkg.tar.zst | grep -v '/$' | while read -r f; do
  [ -e "/$f" ] && echo "CONFLICT /$f <- $(pacman -Qoq "/$f" 2>/dev/null)"
done
```

---

## `error: unresolvable package conflicts detected`

```text
:: tldr-3.4.4-1 and tealdeer-1.9.0-1.1 are in conflict
```

`tealdeer` already provides `/usr/bin/tldr` and is required by `cachyos-fish-config`, so
Omarchy's `tldr` is skipped. Nothing is lost.

> [!TIP]
> A scan of Omarchy's package list against a populated system flagged 89 apparent conflicts,
> but **88 were `Replaces`/`Provides` pairs pacman resolves by itself** — `clang` replacing
> `clang-analyzer`, `ruby` replacing the `ruby-*` splits. Only genuine `Conflicts` where the
> new package does not *provide* what it displaces will block a transaction. Filter for those:

```bash
pacman -Si "$pkg" | awk -F' *: *' '/^Conflicts With/{print $2}'
```

Also check the **reverse** direction — an installed package declaring a conflict with a
candidate. That is how the `tealdeer` case presents, and a forward-only scan misses it.

---

## `pacman -Si <name>` says "package not found" but installation works

`pacman -Si` does not resolve **virtual provides**. `nvim` is not a package; `neovim`
*provides* it. Validate with real resolution instead:

```bash
pacman -Sp --needed --noconfirm "${pkgs[@]}"
```

> [!NOTE]
> `-Sp` resolves dependencies but does **not** perform the installed-package conflict check,
> so it will not catch the `tealdeer` class of failure. Use both checks.

---

## `SUPER+SPACE` does nothing

The Omarchy menu is a plugin of the Omarchy **shell**. `omarchy-menu` only sends IPC:

```bash
exec omarchy-shell shell toggle omarchy.menu "$(menu_payload "$route")"
```

Confirm the shell is running:

```bash
pgrep -af 'aether|quickshell'
omarchy-launch-shell    # if not
```

In the nested window this is what `--bare` handles.

---

## The nested window is larger than the screen

Your logical desktop is smaller than your pixel resolution when scaling is active:

```bash
kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Output:|Geometry|Scale|enabled'
```

A <width>×<height> display at 2× is a <logical-size> logical desktop. Re-run `omarchy-window` with no
`-s` and it fits itself, or pass an explicit `-s 1400x800`.

---

## "no initramfs*.img found under /boot"

There are two initramfs layouts, and only one uses that filename:

| Layout | Path |
| --- | --- |
| classic mkinitcpio | `/boot/initramfs-<kernel>.img` |
| kernel-install (CachyOS + limine, systemd-boot) | `/boot/<machine-id>/<kernel>/initramfs` |

The second has **no extension** and sits a level deeper. Find yours with:

```bash
sudo find /boot -maxdepth 4 \( -name 'initramfs*.img' -o -name 'initramfs' \) -type f
```

On such a system `mkinitcpio -P` also reports `No presets found in /etc/mkinitcpio.d` and
defers to `limine-mkinitcpio`, which is what actually writes the images and updates
`limine.conf`. Call that directly rather than relying on the prompt:

```bash
sudo limine-mkinitcpio
```

Confirm the encryption hook survived — this is the check that matters on a LUKS root:

```bash
for i in $(sudo find /boot -maxdepth 4 -name initramfs -type f); do
  sudo lsinitcpio -a "$i" | grep -i '^ *Hooks'
done
```

---

## Verifying you can still boot

```bash
./verify-reboot-safety.sh
```

Checks the guards held, re-evaluates the effective `HOOKS`, inspects the **actual initramfs**
with `lsinitcpio -a` for `sd-encrypt`, confirms the `rd.luks.uuid=` on your cmdline matches a
real LUKS device, and lists available snapshots.

`--rebuild` additionally regenerates the initramfs and re-inspects it, refusing to run if any
check is already failing. Worth doing deliberately, while watching, rather than discovering a
broken configuration during an unattended kernel update.

If it prints **DO NOT REBOOT**, restore from the backup directory the installer reported, or
boot the pre-install snapshot from your boot menu.
