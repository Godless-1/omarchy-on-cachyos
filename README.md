<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

<div align="center">

<img src="docs/banner.svg" alt="omarchy-on-cachyos" width="100%">

<br>

**Install [Omarchy](https://omarchy.org) alongside your existing desktop on CachyOS or Arch —
without letting it near your bootloader, your initramfs, or your repos.**

<br>

[![Shell](https://img.shields.io/badge/bash-5.x-9ece6a?style=flat-square&logo=gnubash&logoColor=1a1b26&labelColor=24283b)](#)
[![Omarchy](https://img.shields.io/badge/omarchy-4.0.2-7aa2f7?style=flat-square&labelColor=24283b)](https://omarchy.org)
[![Base](https://img.shields.io/badge/base-CachyOS%20%2F%20Arch-bb9af7?style=flat-square&labelColor=24283b)](https://cachyos.org)
[![Code](https://img.shields.io/badge/code-AGPL--3.0--or--later-f7768e?style=flat-square&labelColor=24283b)](LICENSES/AGPL-3.0-or-later.txt)
[![Docs](https://img.shields.io/badge/docs-CC%20BY--SA%204.0-ff9e64?style=flat-square&labelColor=24283b)](LICENSES/CC-BY-SA-4.0.txt)
[![Provenance](https://img.shields.io/badge/provenance-disclosed-565f89?style=flat-square&labelColor=24283b)](PROVENANCE.md)

</div>

---

<div align="center">

<a href="PROVENANCE.md"><img src="docs/provenance.svg" alt="Build provenance: written by Claude Opus 5, directed and executed by a human. Full disclosure in PROVENANCE.md" width="100%"></a>

<sub>Every claim below is reproducible from your own shell — see
<a href="PROVENANCE.md#auditing-this-yourself">Auditing this yourself</a>.</sub>

</div>

---

## What this is

Omarchy 4 is no longer an install script — it ships as **pacman packages** (`omarchy`,
`omarchy-settings`) in its own signed repo, and it installs a session file:

```ini
Exec=uwsm start -g -1 -e -D Hyprland hyprland.desktop
```

Which means Omarchy can live in your greeter's session list **next to Plasma**, and you pick
one at login. No VM, no container, no second disk.

The catch is that those packages assume they own the machine. On an existing Arch/CachyOS
install they will reconfigure your initramfs, your bootloader, and your package repositories.
This repo installs Omarchy **with those specific behaviours fenced off**, and gives you a way
to verify your machine still boots afterwards.

> [!CAUTION]
> On a LUKS-encrypted system, installing Omarchy's packages unguarded can leave you
> **unable to unlock your root filesystem**. See [The three hazards](#the-three-hazards).
> Read that section before running anything.

---

## The three hazards

Omarchy ships system configuration that is correct for Omarchy and wrong for a host that
already has its own. These are the three that actually matter.

### 1. It replaces your initramfs hook list

`/etc/mkinitcpio.conf.d/omarchy_hooks.conf` contains a **bare assignment**:

```bash
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap \
       consolefont block encrypt filesystems fsck btrfs-overlayfs)
```

It has no numeric prefix, so it sorts *after* drop-ins like `10-chwd.conf` and
`10-limine-snapper-sync.conf` and **replaces** them rather than extending them.

On a systemd-initramfs system this swaps `sd-encrypt` → `encrypt` and
`sd-btrfs-overlayfs` → `btrfs-overlayfs`. The busybox `encrypt` hook **does not parse
`rd.luks.uuid=`**, which is the syntax a systemd initramfs puts on your kernel cmdline.

| | before | after |
|---|---|---|
| init | `systemd` | `udev` |
| LUKS | `sd-encrypt` ✅ | `encrypt` ❌ |
| snapshots | `sd-btrfs-overlayfs` ✅ | `btrfs-overlayfs` ❌ |

Result: root does not unlock, and booting a snapshot breaks. Verified empirically, not
theorised.

### 2. It hijacks your boot entries

`/etc/limine-entry-tool.d/omarchy-{defaults,uki}.conf` sets `ENABLE_UKI=yes`,
`CUSTOM_UKI_NAME="omarchy"`, renames your OS entry to `Omarchy`, appends kernel parameters,
and rewrites `BOOT_ORDER`.

### 3. Two commands delete your repositories

`omarchy-refresh-pacman` does exactly this:

```bash
sudo cp -f "$OMARCHY_PATH/default/pacman/pacman-$channel.conf" /etc/pacman.conf
sudo cp -f "$OMARCHY_PATH/default/pacman/mirrorlist-$channel"  /etc/pacman.d/mirrorlist
sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syyuu --noconfirm
```

On CachyOS that removes `cachyos-v3`, `cachyos-core-v3`, `cachyos-extra-v3` and anything else
you had, then force-downgrades every optimised package. `omarchy-channel-set` and
`omarchy-reinstall-pkgs` both call it.

`omarchy-update` is a separate problem: it runs `omarchy-migrate`, and migrations are
*upgrade paths from older Omarchy versions*. A package-based install never marks them
complete, so all of them are pending — including one that disables `sshd`.
See [docs/migrations.md](docs/migrations.md).

---

## How it protects you

| Mechanism | Protects against |
|---|---|
| `NoExtract` in `pacman.conf` | Hazards 1 & 2, **durably** — survives package updates |
| Hard gate after install | Aborts with *DO NOT REBOOT* if `sd-encrypt` vanished |
| Binary guards + `NoExtract` | Hazard 3, from every shell, both sessions, and the Omarchy menu |
| Snapper snapshot + backups | Rollback if anything else surprises you |

`NoExtract` is the key idea: pacman never extracts those paths, so the protection **survives
`pacman -Syu`** instead of being undone by the next update.

> [!WARNING]
> `NoExtract` blocks package *extraction*. It cannot block a package's **post-install
> script**, and `omarchy-settings` has one that copies `etc-overrides/` into `/etc`.
> Five files land that way regardless. They are documented and none are boot-critical —
> see [docs/how-it-works.md](docs/how-it-works.md#etc-overrides).

---

## Install

> [!IMPORTANT]
> Read [The three hazards](#the-three-hazards) first. Then dry-run. Then install.

```bash
git clone https://github.com/Godless-1/omarchy-on-cachyos.git
cd omarchy-on-cachyos
./install-omarchy-on-cachyos.sh --dry-run
```

The dry run needs no `sudo` and changes nothing. When you're happy:

```bash
./install-omarchy-on-cachyos.sh
```

Then make the destructive commands unrunnable, and verify you can still boot:

```bash
./block-omarchy-updates.sh
./verify-reboot-safety.sh
```

Log out and pick **Omarchy (Hyprland uwsm)** at your greeter. Plasma is untouched and
one logout away, always.

### What the installer actually does

1. Backs up `pacman.conf`, `mkinitcpio.conf`, drop-ins and your package list
2. Takes a snapper snapshot, bootable from your boot menu
3. Writes the `NoExtract` guards **before** installing anything
4. Installs `omarchy-keyring` over HTTPS and **verifies fingerprint
   `40DFB630FF42BCFFB047046CF0134EE680CAC571`** — it never lowers `SigLevel` to `TrustAll`
5. Adds `[omarchy]` **last**, so it can never override your distro's packages
6. Installs `omarchy` with `--assume-installed sddm` (keeps your display manager)
7. **Hard gate**: recomputes effective `HOOKS`; aborts if `sd-encrypt` is gone
8. Installs the Omarchy userspace, skipping packages that conflict with your system
9. Symlinks the session file where your greeter will find it
10. Seeds `~/.config` **copy-if-absent** — your files always win

---

## The nested window

Hyprland's Aquamarine backend runs nested when `WAYLAND_DISPLAY` is set. So you can run the
whole Omarchy desktop **in a window on your existing session** — same machine, same
filesystem, nothing to share:

```bash
./omarchy-window --bare
```

It queries KWin for the real work area (your screen minus panels), sizes the nested output to
match exactly, and installs a KWin rule so it lands there with no titlebar.

`--bare` skips Omarchy's `systemctl --user import-environment`, which would otherwise
overwrite `WAYLAND_DISPLAY` in your **host** session — while still starting the Omarchy shell
so the menu (`SUPER+SPACE`) and bar work.

This is the gentlest way to learn Hyprland's keybindings. `SUPER+K` opens Omarchy's own
cheatsheet. `SUPER+ESCAPE` exits.

<div align="center"><br><code>SUPER+SPACE</code> menu · <code>SUPER+K</code> keybindings · <code>SUPER+Q</code> terminal · <code>SUPER+ESCAPE</code> exit<br><br></div>

---

## Scripts

| Script | Purpose |
|---|---|
| [`install-omarchy-on-cachyos.sh`](install-omarchy-on-cachyos.sh) | Guarded install. `--dry-run`, `--minimal` |
| [`uninstall-omarchy-on-cachyos.sh`](uninstall-omarchy-on-cachyos.sh) | Reverse it. `--keep-apps` |
| [`block-omarchy-updates.sh`](block-omarchy-updates.sh) | Fence off the destructive commands. `--undo`, `--status` |
| [`verify-reboot-safety.sh`](verify-reboot-safety.sh) | Prove you can still boot. `--rebuild` |
| [`omarchy-window`](omarchy-window) | Omarchy in a window. `--bare`, `-s WxH`, `--no-rule` |

## Documentation

- **[The hazards, in full](docs/hazards.md)** — what each one does and why the guard works
- **[How it works](docs/how-it-works.md)** — packaging, `NoExtract`, `etc-overrides`
- **[The nested window](docs/nested-window.md)** — sizing, KWin rules, `--bare`
- **[Migrations](docs/migrations.md)** — the 96 markers and why they matter
- **[Troubleshooting](docs/troubleshooting.md)** — real conflicts and their fixes
- **[Copying](COPYING.md)** — why AGPL for code and CC BY-SA for prose
- **[Provenance](PROVENANCE.md)** — how this was built, and the mistakes made doing it

---

## Requirements

Arch or an Arch derivative with a working desktop session, `pacman`, `curl`, `bsdtar`,
`python3`, and internet access. The nested window additionally wants a Wayland session;
exact work-area fitting is KDE-specific (`kscreen-doctor`, KWin scripting) and degrades
gracefully elsewhere.

Developed against **Omarchy 4.0.2** on **CachyOS** with LUKS root on btrfs, limine + snapper,
a greetd-based greeter, and more than one GPU. Other bases should work; the guards are
written defensively and the verifier will tell you the truth either way.

---

<div align="center">

**Copyleft.** Scripts are [AGPL-3.0-or-later](LICENSES/AGPL-3.0-or-later.txt); prose and
artwork are [CC BY-SA 4.0](LICENSES/CC-BY-SA-4.0.txt). Improve it and your users keep every
freedom you were given. No CLA, no assignment, no relicensing escape hatch. — [Copying](COPYING.md)

**Unofficial.** Not affiliated with, endorsed by, or supported by Omarchy, Basecamp, DHH,
or CachyOS. Omarchy is [MIT-licensed](https://github.com/basecamp/omarchy) and excellent —
this repo just helps it share a machine.

<sub>No warranty. It edits <code>pacman.conf</code> and replaces two binaries. Read the scripts.</sub>

</div>
