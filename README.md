<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

<div align="center">

<img src="docs/banner.svg" width="100%"
     alt="omarchy-on-cachyos. Hyprland beside Plasma, your bootloader untouched. Styled as a terminal showing the command ./install-omarchy-on-cachyos.sh --dry-run. Licensed AGPL-3.0-or-later.">

</div>

# omarchy-on-cachyos

**Install [Omarchy](https://omarchy.org) alongside your existing desktop on CachyOS or Arch —
without letting it near your bootloader, your initramfs, or your repos.**

<a href="install-omarchy-on-cachyos.sh"><img src="docs/badges/bash.svg" alt="Written in Bash 5.x"></a>
<a href="https://omarchy.org"><img src="docs/badges/omarchy.svg" alt="Targets Omarchy 4.0.2"></a>
<a href="https://cachyos.org"><img src="docs/badges/base.svg" alt="Base: CachyOS or Arch"></a>
<a href="LICENSES/AGPL-3.0-or-later.txt"><img src="docs/badges/code.svg" alt="Code licensed AGPL-3.0-or-later"></a>
<a href="LICENSES/CC-BY-SA-4.0.txt"><img src="docs/badges/docs.svg" alt="Documentation licensed CC BY-SA 4.0"></a>
<a href="PROVENANCE.md"><img src="docs/badges/provenance.svg" alt="Build provenance disclosed"></a>

---

## At a glance

**What it does.** Puts Omarchy 4's Hyprland desktop in your greeter's session list, next to
the desktop you already use. You pick one at login. No VM, no container, no second disk.

**Why not just install Omarchy directly.** Omarchy's packages assume they own the
machine. Unguarded, they rewrite your initramfs hooks, your bootloader entries, and your
package repositories. On a LUKS-encrypted root, that means **root stops unlocking**.

**What this adds.** Guards that survive `pacman -Syu`, a hard gate that aborts mid-install if
your encryption hook has vanished, and a verifier that proves you can still boot.

| Property | What to expect |
| --- | --- |
| Time | ~10 minutes plus download |
| Download | ~750 MB (`--minimal` is much less) |
| Touches your bootloader | **No** — guarded |
| Touches your initramfs hooks | **No** — guarded, and verified after |
| Touches your repositories | Adds one, ordered **last**, so it never overrides yours |
| Your existing desktop | Untouched — still there, still your default if you prefer |
| Reversible | Yes — uninstaller, config backups, and a bootable snapshot |
| Needs a reboot | No. Log out and back in |

**The whole flow, start to finish:**

```bash
./install-omarchy-on-cachyos.sh --dry-run   # changes nothing, needs no sudo
./install-omarchy-on-cachyos.sh             # the real thing
./block-omarchy-updates.sh                  # fence off two destructive commands
./verify-reboot-safety.sh                   # prove the machine still boots
```

Then log out and pick **Omarchy (Hyprland uwsm)**. Not ready to hand over your whole
session? Run [`./omarchy-window`](#the-nested-window) and get the desktop in a window instead.

> [!CAUTION]
> On a LUKS-encrypted system, installing Omarchy's packages **unguarded** can leave you unable
> to unlock your root filesystem. Read [The three hazards](#the-three-hazards) before running
> anything — even if you decide not to use these scripts.

---

<div align="center">

<a href="PROVENANCE.md"><img src="docs/provenance.svg" width="100%"
  alt="Build provenance. Written by Claude Opus 5, model claude-opus-5, via Claude Code. Directed by a human who set the scope, reviewed the work, and ran every privileged command. Method: research, then dry-run, then verify empirically, then iterate. Claims were tested on real hardware, not asserted. No secrets, hostnames, UUIDs or personal data were published. Full disclosure in the provenance document."></a>

</div>

> **Build provenance.** The scripts and documentation here were **written by Claude Opus 5
> (`claude-opus-5`) in Claude Code**, on 2026-09-01, directed and reviewed throughout by a
> human operator who ran every privileged command personally. Nothing was generated
> unattended or committed unread. [**PROVENANCE.md**](PROVENANCE.md) gives the full account,
> including [the mistakes made and corrected](PROVENANCE.md#mistakes-made-and-corrected)
> along the way, and [how to verify every claim yourself](PROVENANCE.md#auditing-this-yourself).

---

## What this is

Omarchy 4 is no longer an install script — it ships as **pacman packages** (`omarchy`,
`omarchy-settings`) in its own signed repo, and it installs a session file:

```ini
Exec=uwsm start -g -1 -e -D Hyprland hyprland.desktop
```

That means Omarchy can live in your greeter's session list **next to Plasma**, and you pick
one at login.

The catch is that those packages assume they own the machine. On an existing Arch/CachyOS
install they will reconfigure your initramfs, your bootloader, and your package repositories.
This repo installs Omarchy **with those specific behaviours fenced off**, and gives you a way
to verify your machine still boots afterwards.

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

| Component | Before | After |
| --- | --- | --- |
| init system | `systemd` | `udev` |
| LUKS unlock | `sd-encrypt` — works | `encrypt` — **cannot parse `rd.luks.uuid=`** |
| Snapshot boot | `sd-btrfs-overlayfs` — works | `btrfs-overlayfs` — **broken** |

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
| --- | --- |
| `NoExtract` in `pacman.conf` | Hazards 1 and 2, **durably** — survives package updates |
| Hard gate after install | Aborts with *DO NOT REBOOT* if `sd-encrypt` has vanished |
| Binary guards plus `NoExtract` | Hazard 3, from every shell, both sessions, and the Omarchy menu |
| Snapper snapshot and backups | Rollback if anything else surprises you |

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

Log out and pick **Omarchy (Hyprland uwsm)** at your greeter. Plasma is untouched, and
always one logout away.

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
so the menu (<kbd>Super</kbd>+<kbd>Space</kbd>) and bar work.

This is the gentlest way to learn Hyprland's keybindings.

| Key | Action |
| --- | --- |
| <kbd>Super</kbd>+<kbd>Space</kbd> | Omarchy menu |
| <kbd>Super</kbd>+<kbd>K</kbd> | Omarchy's own keybinding cheatsheet |
| <kbd>Super</kbd>+<kbd>Q</kbd> | Terminal |
| <kbd>Super</kbd>+<kbd>Escape</kbd> | Exit the nested session |

---

## Scripts

| Script | Purpose |
| --- | --- |
| [`install-omarchy-on-cachyos.sh`](install-omarchy-on-cachyos.sh) | Guarded install. `--dry-run`, `--minimal` |
| [`uninstall-omarchy-on-cachyos.sh`](uninstall-omarchy-on-cachyos.sh) | Reverse it. `--keep-apps` |
| [`block-omarchy-updates.sh`](block-omarchy-updates.sh) | Fence off the destructive commands. `--undo`, `--status` |
| [`verify-reboot-safety.sh`](verify-reboot-safety.sh) | Prove you can still boot. `--rebuild` |
| [`omarchy-window`](omarchy-window) | Omarchy in a window. `--bare`, `-s WxH`, `--no-rule` |
| [`clean-stale-boot-entries.sh`](clean-stale-boot-entries.sh) | Reclaim orphaned `/boot/<machine-id>/` dirs. `--archive`, `--delete` |

## Documentation

- **[The hazards, in full](docs/hazards.md)** — what each one does and why the guard works
- **[How it works](docs/how-it-works.md)** — packaging, `NoExtract`, `etc-overrides`
- **[The nested window](docs/nested-window.md)** — sizing, KWin rules, `--bare`
- **[Migrations](docs/migrations.md)** — the 96 markers and why they matter
- **[Troubleshooting](docs/troubleshooting.md)** — real conflicts and their fixes
- **[Licensing](LICENSING.md)** — why AGPL for code and CC BY-SA for prose
- **[Provenance](PROVENANCE.md)** — how this was built, the mistakes made doing it, and
  [which code paths have never been run](PROVENANCE.md#what-was-not-tested)

---

## Requirements

Arch or an Arch derivative with a working desktop session, `pacman`, `curl`, `bsdtar`,
`python3`, and internet access. The nested window also needs a Wayland session;
exact work-area fitting is KDE-specific (`kscreen-doctor`, KWin scripting) and degrades
gracefully elsewhere.

Developed against **Omarchy 4.0.2** on **CachyOS**, with a LUKS root on btrfs, limine and
snapper, a greetd-based greeter, and more than one GPU. Other bases should work; the guards
are written defensively and the verifier will tell you the truth either way.

## Accessibility and theming

The two banners are decoration. Everything they say is also written as ordinary text beside
them, so nothing is lost if images are off, and each carries descriptive `alt` text rather
than a filename.

Colour contrast was **measured, not eyeballed** — every foreground meets WCAG 2.1 AA against
its background. Two colours from the original palette failed (2.9:1 and 2.0:1) and were
replaced. No meaning is carried by colour alone, tables have real headers, and no link points
at a placeholder.

**Badges.** The badges are hand-made SVGs in this repository, not shields.io images. Shields.io
hardcodes white text (`fill="#fff"`) on both halves of a badge, and the Tokyo Night accents are
light tones meant for dark backgrounds — white on `#9ece6a` measures **1.83:1**, which is close
to invisible. Inverting the relationship (accent text on a dark plate) puts every badge between
**5.5:1 and 9.0:1**. It also means the header makes no external requests, so nothing about who
reads this page is sent to a third party.

**Theming.** The banners are deliberately dark in both GitHub themes rather than swapping with
`prefers-color-scheme`. That is a considered choice, not an oversight: a theme-swapped light
variant is exactly what an extension like **Dark Reader** would invert, producing a glaring
card on an otherwise dark page. A card that is already dark is left alone. Both have a subtle
border so they read as intentional on GitHub's light theme too. Everything else — alerts,
tables, `<kbd>` keys, code blocks — uses GitHub's own theme-aware styling.

If something reads badly in a screen reader, or looks wrong in a theme or with a contrast
extension, that is a bug. Please open an issue.

---

<div align="center">

**Copyleft.** Scripts are [AGPL-3.0-or-later](LICENSES/AGPL-3.0-or-later.txt); prose and
artwork are [CC BY-SA 4.0](LICENSES/CC-BY-SA-4.0.txt). Improve it and your users keep every
freedom you were given. No CLA, no assignment, no relicensing escape hatch. — [Licensing](LICENSING.md)

**Unofficial.** Not affiliated with, endorsed by, or supported by Omarchy, Basecamp, DHH,
or CachyOS. Omarchy is [MIT-licensed](https://github.com/basecamp/omarchy) and excellent —
this repo just helps it share a machine.

<sub>No warranty. It edits <code>pacman.conf</code> and replaces two binaries. Read the scripts.</sub>

</div>
