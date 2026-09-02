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

None are boot-critical. Restore your OS identity if you want it back:

```bash
sudo ln -sf ../usr/lib/os-release /etc/os-release
```

Expect it to return after the next `omarchy-settings` update.

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
