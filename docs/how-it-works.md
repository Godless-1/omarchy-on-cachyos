<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# How it works

## Omarchy 4 is packaged

Omarchy is no longer a curl-pipe-bash installer. It is two packages in a signed repo:

```ini
[omarchy]
SigLevel = Required DatabaseOptional
Server = https://pkgs.omarchy.org/stable/$arch
```

| Package | Contents |
|---|---|
| `omarchy` | `/usr/bin/omarchy-*`, `/usr/share/omarchy/{bin,install,migrations,shell,themes}`, skel migration markers |
| `omarchy-settings` | `/usr/share/omarchy/{config,default,applications,etc-overrides}`, `/etc/skel/.config`, system `/etc` files, the session desktop file |

`omarchy` depends on `limine`, `limine-mkinitcpio-hook`, `limine-snapper-sync`, `snapper`,
`hyprland`, `quickshell`, `uwsm`, `sddm`, `xdg-desktop-portal-hyprland`, `wireplumber`,
`pipewire`, `gnome-keyring` and friends.

The installer passes `--assume-installed sddm` so a second display manager is not pulled in.

## Keyring bootstrap without `TrustAll`

The usual pattern for a third-party repo is to add it with `SigLevel = Optional TrustAll`,
install its keyring, then tighten. That leaves a window where unsigned packages are accepted.

This installer avoids it: it fetches `omarchy-keyring` **directly over HTTPS**, installs it
with `pacman -U`, and asserts the fingerprint is trusted before the repo is ever added:

```bash
sudo pacman-key --list-keys 40DFB630FF42BCFFB047046CF0134EE680CAC571
```

If that fails the install aborts rather than lowering `SigLevel`.

## Repo ordering

`[omarchy]` is appended **last**. Pacman searches repositories in file order, so packages
that exist in both your distro's repos and Omarchy's resolve to yours. On CachyOS that keeps
the `-v3` optimised builds. Only genuinely Omarchy-exclusive packages come from `[omarchy]`.

## `NoExtract`, and its one limitation

```ini
[options]
# --- omarchy-on-cachyos guards (do not remove) ---
NoExtract = etc/mkinitcpio.conf.d/omarchy_hooks.conf
NoExtract = etc/limine-entry-tool.d/*
NoExtract = etc/docker/daemon.json
NoExtract = etc/systemd/resolved.conf.d/20-docker-dns.conf
NoExtract = etc/systemd/system/docker.service.d/no-block-boot.conf
NoExtract = etc/sddm.conf.d/*
NoExtract = etc/skel/.config/alacritty/*
NoExtract = usr/bin/omarchy-update
NoExtract = usr/bin/omarchy-refresh-pacman
NoExtract = usr/share/omarchy/bin/omarchy-update
NoExtract = usr/share/omarchy/bin/omarchy-refresh-pacman
# --- end omarchy-on-cachyos guards ---
```

These persist across `pacman -Syu`, which is what makes the protection durable rather than a
one-time cleanup. The installer rewrites this block on every run, so both scripts keep their
entries in one list.

<a name="etc-overrides"></a>
## `etc-overrides` — what `NoExtract` cannot stop

`omarchy-settings` has a **post-install script** that prints `Applying Omarchy
etc-overrides...` and *copies* files from `/usr/share/omarchy/etc-overrides/` into `/etc`.

`NoExtract` governs package extraction. It has no bearing on what a script does afterwards,
so these land regardless, and re-land on every `omarchy-settings` update:

| Override | Effect | Assessment |
|---|---|---|
| `os-release` | `ID=omarchy`; replaces the usual symlink with a regular file | Cosmetic, but distro-detection scripts will now see Omarchy |
| `nsswitch.conf` | adds `mdns_minimal` to `hosts:` | Benign — enables `.local` discovery |
| `security-faillock.conf` | `deny = 10` (Arch default is 3) | More permissive, not less |
| `plymouth/plymouthd.conf` | `Theme=omarchy` | Cosmetic; see below |
| `skel/.bashrc` | new users only | No effect on existing users |

None are boot-critical, but three of them change how the system presents itself, and
`NoExtract` cannot stop a script. Use [`preserve-cachyos-identity.sh`](../preserve-cachyos-identity.sh):

```bash
./preserve-cachyos-identity.sh            # report
./preserve-cachyos-identity.sh --apply    # restore, and keep it that way
```

It restores all three and installs a `PostTransaction` pacman hook targeting
`omarchy-settings`, so Omarchy's script overwrites them and ours puts them back, in the same
transaction.

> [!WARNING]
> Do **not** "restore" `/etc/os-release` by symlinking it to `/usr/lib/os-release`. On CachyOS
> the identity is not a packaged file at all — `cachyos-hooks` runs
> `/usr/share/libalpm/scripts/cachyos-branding`, which **sed-edits `/etc/os-release` in
> place**, which is why the file is unowned. Symlinking it yields plain Arch branding, and
> leaves the branding script editing the package-owned file under `/usr/lib`. The script
> converts it back to a regular file first, then calls `cachyos-branding` itself.

Distributions other than CachyOS will have their own equivalent; the same hook pattern
applies, with a different restore command.

The Plymouth theme only takes effect at the next initramfs rebuild, since the image carries
its own copy of the config and the theme.

### Why the plymouth change is not a boot risk

The initramfs carries **its own copy** of `plymouthd.conf` and the theme, baked in when
`mkinitcpio` ran. An existing image therefore pairs the old config with the old theme, and a
rebuilt image pairs the new config with the new theme. Both are internally consistent, so the
LUKS passphrase prompt renders either way. `verify-reboot-safety.sh` confirms the configured
theme actually exists on disk.

## Config seeding

Both packages ship `/etc/skel` content and the installer seeds from **both** — the
`.config` files from `omarchy-settings`, and the migration markers from `omarchy`.

Seeding is strictly **copy-if-absent**. An existing file is never overwritten, never backed
up over, and never merged; it is reported and left alone. Omarchy's version stays available
under `/etc/skel/` for manual comparison.

### Agent skills

Omarchy ships skills for coding agents under
`/usr/share/omarchy/default/agents/skills/` — currently `omarchy` (Hyprland, theming,
hooks, plugins, the `omarchy-*` commands) and `diagnose-crash`, which
`omarchy-agent-crash` expects to exist.

A stock Omarchy install links them into every agent's config from
`omarchy-provision-user`. **This project never runs that script**: alongside the skills it
also rewrites your XDG user directories and `rmdir`s `~/Desktop`, `~/Templates` and
`~/Public`, which is not a thing to do to a machine that already has a desktop. So the
installer links the skills itself, and nothing else from that script.

They are symlinks rather than copies, exactly as upstream makes them, so they track the
package instead of freezing at whatever version shipped the day you installed. The
destination follows `CLAUDE_CONFIG_DIR` when it is set, and is `~/.claude/skills`
otherwise.

`omarchy-on-cachyos check` reports any that are missing and can link them, so an install
made before this existed can be brought up to parity without reinstalling. The uninstaller
removes only symlinks pointing into `/usr/share/omarchy/` — anything you put there
yourself is left alone.

**This changes what the agent knows, not what it prints.** Claude Code's startup output is
byte-for-byte identical with and without them; the skills are surfaced to the model, not to
the terminal.
