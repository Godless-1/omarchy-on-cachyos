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

A display at 2× scale gives a logical desktop half its pixel dimensions, and less again at
higher factors — that is the number a window has to fit inside. Re-run `omarchy-window` with no
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

Confirm the encryption support survived — the check that matters on a LUKS root. Use
`lsinitcpio -l` and look for the cryptsetup machinery, **not** `-a` and a hook list
(see the next section for why):

```bash
for i in $(sudo find /boot -maxdepth 4 -name initramfs -type f); do
  echo "== $i"
  sudo lsinitcpio -l "$i" | grep -E 'systemd-cryptsetup|cryptsetup\.target'
done
```

---

## "sd-encrypt NOT in this image" (false alarm)

If a checker greps `lsinitcpio -a` output for a `Hooks:` line, **it will report a false
failure on any systemd initramfs.** There is no such line. `lsinitcpio -a` prints Image,
Created with, Kernel, Early CPIO, Size, Compressed with, and Included modules — no hook list.

`sd-encrypt` is a *build-time* hook. Its output is systemd's cryptsetup machinery, not a
runtime hook script, so the correct question is whether that machinery is in the image:

```bash
sudo lsinitcpio -l /path/to/initramfs | grep -E 'systemd-cryptsetup|cryptsetup.target'
```

A healthy systemd + LUKS image contains:

```text
usr/bin/systemd-cryptsetup
usr/lib/systemd/system-generators/systemd-cryptsetup-generator
usr/lib/systemd/system/cryptsetup.target
usr/lib/systemd/system/sysinit.target.wants/cryptsetup.target
```

That last path is the one that matters — it is what activates cryptsetup at boot.

For a **busybox** initramfs the equivalent artifact is the hook script itself:

```bash
sudo lsinitcpio -l /path/to/initramfs | grep -E '(^|/)hooks/encrypt$'
```

> [!IMPORTANT]
> A check that cannot distinguish *"absent"* from *"I looked in the wrong place"* is worse
> than no check. It produces false alarms exactly when you most need to trust the tool.
> `verify-reboot-safety.sh` now reports an unreadable image as a warning that says so,
> and never as a failure.

---

## Orphaned `/boot/<machine-id>/` directories

`kernel-install` writes to `/boot/<entry-token>/<kernel>/`, where the token defaults to
`/etc/machine-id` (overridable via `/etc/kernel/entry-token`). Reinstalling, or regenerating
the machine-id, strands the old directory: never booted, never updated, holding a few hundred
MB on an ESP that is usually small.

They are also misleading — a checker that inspects every image on disk will flag stale ones
for lacking a theme or setting that only the live images have. Identify them:

```bash
cat /etc/kernel/entry-token 2>/dev/null || cat /etc/machine-id
ls -la /boot/
```

Anything matching `[0-9a-f]{32}` that is not that token is an orphan. Clean it up safely:

```bash
./clean-stale-boot-entries.sh            # report only
./clean-stale-boot-entries.sh --archive  # move out of /boot, keep a copy
```

> [!NOTE]
> `--archive` has been exercised on exactly one machine. `--delete`, and the refusal that
> fires when the bootloader still references a directory, have never run. Prefer `--archive`,
> and keep the copy until you have rebooted successfully.
> See [what was not tested](../PROVENANCE.md#what-was-not-tested).

A real run looks like this — note that it checks bootloader references *before* touching
anything, and archives rather than deletes by default (tokens and sizes are placeholders):

```text
==> Active entry token: <active-token>
==> Orphaned entry directories (never booted):
      /boot/<stale-token>  (NNNN MB)
        linux-cachyos/initramfs
        linux-cachyos/vmlinuz
        linux-cachyos-lts/initramfs
        linux-cachyos-lts/vmlinuz
        limine_history/initramfs_sha256_...
      total: NNNN MB
==> Checking whether the bootloader still references them
==> No bootloader references. Safe to remove.
==> Archiving <stale-token> -> ~/.local/share/omarchy-cachyos/stale-boot/
```

An orphaned token often holds more than you expect — every installed kernel, its initramfs,
and `limine_history` copies kept for snapshot entries. On a small ESP that adds up quickly.

The archive is a **copy, then remove**, so nothing is destroyed. Delete it once you have
rebooted successfully and are happy:

```bash
rm -rf ~/.local/share/omarchy-cachyos/stale-boot
```

The script never touches the active token and **refuses to remove anything your bootloader
still references** — check that yourself first if you are doing it by hand:

```bash
sudo grep -c "$(basename /boot/<suspect-token>)" /boot/limine.conf
```

If it is referenced, regenerate the boot config (`sudo limine-update`) before removing
anything, or you will be left with dangling menu entries.

---

## Verifying you can still boot

```bash
./verify-reboot-safety.sh
```

Checks the guards held, re-evaluates the effective `HOOKS`, lists the **actual initramfs**
with `lsinitcpio -l` to confirm the encryption support is really inside it, checks that the
`rd.luks.uuid=` on your cmdline matches a real LUKS device, verifies the configured Plymouth
theme is baked in, and lists available snapshots. Images under an inactive entry token are
reported but not judged.

`--rebuild` additionally regenerates the initramfs and re-inspects it, refusing to run if any
check is already failing. Worth doing deliberately, while watching, rather than discovering a
broken configuration during an unattended kernel update.

If it prints **DO NOT REBOOT**, restore from the backup directory the installer reported, or
boot the pre-install snapshot from your boot menu.
