<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

<div align="center">
<img src="docs/provenance.svg" alt="Build provenance" width="100%">
</div>

# Provenance

This page exists so nobody has to guess. If you object to AI-written code, you should be able
to find that out in ten seconds rather than ten commits, and you should get enough detail to
judge the work rather than just the label.

## The short version

**The scripts and documentation in this repository were written by Claude Opus 5
(`claude-opus-5`) running in Claude Code, in a single interactive session on 2026-09-01,
directed and reviewed throughout by a human operator who ran every privileged command
personally.**

No part of this was generated unattended. No part of it was committed unread.

---

## Division of labour

| Task | Done by |
| --- | --- |
| Chose the goal, and changed it twice mid-session | Human |
| Ran every `sudo` command | Human |
| Approved each destructive step | Human |
| Decided licence, visibility, and publication | Human |
| Authenticated to GitHub | Human |
| Read Omarchy's packages and scripts | Model |
| Identified the boot hazards | Model |
| Wrote the scripts and documentation | Model |
| Designed the verification tests | Model |
| Reported failures and its own errors | Model |

The model held no credentials at any point. It could not authenticate, could not enter a
password, and could not run a privileged command — every `sudo` invocation was pasted into a
terminal by the operator, who saw the output and decided whether to continue.

## How it actually went

The session did not begin here. It started as *"add Omarchy under distrobox"*, and the
research killed that idea — Omarchy is a desktop session, not an app bundle. The operator
then redirected to a host install alongside KDE Plasma, and later asked about a VM, which the
research also argued against once it became clear Hyprland runs nested in a window with no
guest and therefore no file-sharing problem.

Roughly the order of work:

1. **Research.** Read the actual `omarchy` and `omarchy-settings` packages — file lists,
   dependency metadata, install scripts, hook drop-ins — rather than relying on documentation
   or recollection.
2. **Reconnaissance.** Inspect the target system's bootloader, initramfs hooks, encryption
   scheme, display manager, GPU and repositories before proposing anything.
3. **Hazard analysis.** Three findings, each traced to the specific file that causes it.
4. **Empirical verification.** The dangerous claim — that Omarchy's hook drop-in breaks a
   LUKS root — was *demonstrated* by evaluating the hook list with and without the file, not
   argued from first principles.
5. **Dry runs.** Every script gained a `--dry-run` and was exercised before touching anything.
6. **Iteration on real failures.** Two pacman transactions failed. Both were diagnosed from
   the actual error, fixed, and re-run.
7. **Verification tooling.** A separate script exists purely to prove the machine still boots.

## Mistakes made, and corrected

Listed because a provenance page that claims a clean run would be worth less than nothing.

| Mistake | How it surfaced | Fix |
|---|---|---|
| Claimed `omarchy-update` overwrites `pacman.conf` | Reading the script; it does not — only `omarchy-refresh-pacman` does | Corrected in the docs; the real risk (migrations) documented instead |
| Nested window defaulted to 1920×1080 | Larger than a <logical-size> logical HiDPI desktop | Queries KWin for the real work area |
| Auto-size picked a **disabled** output | A disabled output still reports geometry | Filters to enabled outputs |
| `--bare` disabled Omarchy's autostart, silently killing `SUPER+SPACE` | The menu is a shell plugin and had no backend | `--bare` now starts the shell explicitly |
| Config seeding read only one of the two packages shipping `/etc/skel` | 96 migration markers never landed | Seeds from both |
| A conflict scan reported 89 conflicts | 88 were `Replaces`/`Provides` pairs pacman handles | Rewritten to find genuine conflicts; found exactly one |
| `kscreen-doctor` parser returned empty | ANSI colour codes | Strips escapes first |
| Guard block was written once and skipped on re-run | Would have dropped a later-added guard | Rewrites the block every run |

The pattern worth noting: most were caught by *running the thing*, which is why the dry-run
and verification steps exist at all.

## What was verified rather than assumed

- The hook-list breakage, by evaluating `HOOKS` both ways
- `pacman.conf` edits, by round-tripping a copy and diffing against the original
- The KWin work area, by querying KWin instead of computing from panel settings
- The initramfs, by inspecting the image with `lsinitcpio -a`
- Package resolution, by full dependency resolution before installing
- Every internal documentation link, mechanically
- The absence of personal data, by scanning every file

## Privacy

The operator's machine is not described in this repository. Before publication every file was
scanned for the username, hostname, LUKS UUID, monitor UUIDs, email address, IP addresses and
hardware model. All are absent.

The scripts contain **no hardcoded machine values**. Geometry, work area, output names, UUIDs,
package lists and paths are all discovered at runtime, which is both why they are portable and
why they leak nothing. Commits are authored under a GitHub `noreply` address by choice.

The one identifier present is the GitHub account that owns the repository, which is
unavoidable for a public repository and was chosen deliberately.

## Auditing this yourself

Nothing here asks for trust:

```bash
# Read every line - it is 5 scripts and none are long
wc -l *.sh omarchy-window

# Watch what it would do, touching nothing, without sudo
./install-omarchy-on-cachyos.sh --dry-run

# Check the licensing metadata
pipx run reuse lint

# Verify the hazard claim on your own machine
sudo bash -c 'HOOKS=(); . /etc/mkinitcpio.conf
  for f in /etc/mkinitcpio.conf.d/*.conf; do [ -e "$f" ] && . "$f"; done
  echo "${HOOKS[*]}"'
```

Every hazard in [`docs/hazards.md`](docs/hazards.md) names the exact file that causes it, so
you can read Omarchy's source and confirm the claim independently. That is the intended
standard of evidence — not the identity of whoever typed it.

## If you would rather not use AI-written code

That is a legitimate position and this page exists to let you act on it without wasting your
time. The findings are reproducible from the commands above, and the licence is
[copyleft](COPYING.md) — you are free to reimplement any of it, and to do so knowing exactly
what the original was and was not.
