<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# The three hazards, in full

Omarchy's packages ship system configuration that is correct for a machine Omarchy owns
outright, and wrong for a host that already has its own. This documents each hazard, how it
was confirmed, and what the guard does.

---

## 1. `omarchy_hooks.conf` — initramfs replacement

**File:** `/etc/mkinitcpio.conf.d/omarchy_hooks.conf` (from `omarchy-settings`)

### The mechanism

`mkinitcpio` sources drop-ins from `/etc/mkinitcpio.conf.d/` in **sorted order**. A file
named `omarchy_hooks.conf` has no numeric prefix, so it sorts *after* conventional
`10-*.conf` drop-ins. It then does a bare assignment rather than an append:

```bash
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap \
       consolefont block encrypt filesystems fsck btrfs-overlayfs)
```

`HOOKS=` discards everything earlier drop-ins contributed. `HOOKS+=` would not.

### Why it breaks LUKS

A systemd initramfs uses the `sd-encrypt` hook, which reads `rd.luks.uuid=` from the kernel
cmdline. The busybox `encrypt` hook uses a completely different syntax
(`cryptdevice=UUID=...:name`) and simply ignores `rd.luks.uuid=`.

Reproduce the evaluation yourself:

```bash
sudo bash -c 'HOOKS=(); MODULES=(); . /etc/mkinitcpio.conf
  for f in /etc/mkinitcpio.conf.d/*.conf; do [ -e "$f" ] && . "$f"; done
  echo "${HOOKS[*]}"'
```

Observed on a CachyOS host, before and after dropping the file in:

```text
before: base systemd autodetect microcode kms modconf block keyboard \
        sd-vconsole plymouth sd-encrypt filesystems sd-btrfs-overlayfs
after:  base udev plymouth keyboard autodetect microcode modconf kms keymap \
        consolefont block encrypt filesystems fsck btrfs-overlayfs
```

`sd-encrypt` is gone. So is `sd-btrfs-overlayfs`, which limine-snapper-sync needs to boot
snapshots — meaning the recovery path breaks in the same stroke as the boot path.

### The guard

```ini
NoExtract = etc/mkinitcpio.conf.d/omarchy_hooks.conf
```

Plus a hard gate after installation that re-evaluates the hook list and aborts with
**DO NOT REBOOT** if `sd-encrypt` is missing on a LUKS system.

> [!NOTE]
> The file only takes effect when `mkinitcpio` next runs — typically a kernel update, days
> later, with no obvious connection to having installed Omarchy. That delay is what makes
> this dangerous rather than merely annoying.

---

## 2. `limine-entry-tool.d` — boot entry hijack

**Files:** `/etc/limine-entry-tool.d/omarchy-defaults.conf`, `omarchy-uki.conf`

```bash
TARGET_OS_NAME="Omarchy"
KERNEL_CMDLINE[default]+=" quiet splash loglevel=0 ..."
CUSTOM_UKI_NAME="omarchy"
ENABLE_LIMINE_FALLBACK=yes
BOOT_ORDER="*, *fallback, Snapshots"
ENABLE_UKI=yes
```

On a host that already manages limine, this renames the OS entry, switches to
Unified Kernel Image booting, appends kernel parameters, and reorders the boot menu.

### The guard

```ini
NoExtract = etc/limine-entry-tool.d/*
```

Verify it held — the directory should not exist at all:

```bash
ls /etc/limine-entry-tool.d/ 2>/dev/null || echo "guard held"
```

---

## 3. `omarchy-refresh-pacman` and `omarchy-update`

### `omarchy-refresh-pacman`

```bash
sudo cp -f "$OMARCHY_PATH/default/pacman/pacman-$channel.conf" /etc/pacman.conf
sudo cp -f "$OMARCHY_PATH/default/pacman/mirrorlist-$channel"  /etc/pacman.d/mirrorlist
sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syyuu --noconfirm
```

Omarchy's `pacman.conf` contains only `core`, `extra`, `multilib` and `omarchy`, pointed at
Omarchy's own mirror. Copying it over yours **deletes every other repository** — on CachyOS
that is `cachyos-v3`, `cachyos-core-v3`, `cachyos-extra-v3`, plus anything else you added.
`-Syyuu` then force-downgrades the optimised packages to Omarchy's snapshot.

Reached indirectly by `omarchy-channel-set` and `omarchy-reinstall-pkgs`.

### `omarchy-update`

Does **not** touch `pacman.conf` — a common misreading. Its risk is different: it calls
`omarchy-migrate`, and on a package-based install no migration is marked complete. See
[migrations.md](migrations.md).

### The guard

Both binaries are replaced with a guard script that refuses, explains, and notifies. All
four paths are covered:

```text
/usr/bin/omarchy-update
/usr/bin/omarchy-refresh-pacman
/usr/share/omarchy/bin/omarchy-update
/usr/share/omarchy/bin/omarchy-refresh-pacman
```

and each is added to `NoExtract` so pacman never restores the originals. The originals are
stashed in `/usr/local/share/omarchy-blocked/`, reachable deliberately:

```bash
OMARCHY_ALLOW_DANGEROUS=1 omarchy-update
```

This blocks the **Omarchy menu's** `Update → Omarchy` entry too, which shell aliases
would not — it launches the binary directly in a floating terminal.

**Update normally instead:** `sudo pacman -Syu`. `[omarchy]` is just another repo, so
Omarchy's own packages upgrade with everything else.
