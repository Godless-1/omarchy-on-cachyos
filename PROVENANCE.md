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
| Nested window used a fixed default size | Larger than the logical desktop on a scaled display | Queries KWin for the real work area |
| Auto-size picked a **disabled** output | A disabled output still reports geometry | Filters to enabled outputs |
| `--bare` disabled Omarchy's autostart, silently killing `SUPER+SPACE` | The menu is a shell plugin and had no backend | `--bare` now starts the shell explicitly |
| Config seeding read only one of the two packages shipping `/etc/skel` | 96 migration markers never landed | Seeds from both |
| A conflict scan reported 89 conflicts | 88 were `Replaces`/`Provides` pairs pacman handles | Rewritten to find genuine conflicts; found exactly one |
| `kscreen-doctor` parser returned empty | ANSI colour codes | Strips escapes first |
| Guard block was written once and skipped on re-run | Would have dropped a later-added guard | Rewrites the block every run |
| `verify-reboot-safety.sh` searched `/boot` at depth 2 for `initramfs*.img` | The kernel-install layout is `/boot/<token>/<kernel>/initramfs` — no extension, one level deeper — so it found nothing and still reported PASS on exit code alone | Searches both layouts |
| The same script then grepped `lsinitcpio -a` for a `Hooks` line | No such line exists for a systemd initramfs; it reported four confident failures on an intact machine | Checks for `systemd-cryptsetup` and `cryptsetup.target` instead, per init style |
| It judged every image on disk, including orphaned entry directories | Stale images from an old machine-id will always lack what the live ones have | Scoped to the active entry token; orphans reported, not judged |

The pattern worth noting: most were caught by *running the thing*, which is why the dry-run
and verification steps exist at all.

The last three deserve emphasis, because they are the worst kind. The verification script —
the one whose entire job is to be trustworthy about whether a machine still boots — was wrong
twice, and both times it failed **loudly and confidently** rather than quietly. It reported
`PASS` while silently skipping its most important check, and later reported four failures on a
system that was completely intact. A check that cannot distinguish *absent* from *I looked in
the wrong place* is worse than no check at all, because it spends your trust at exactly the
moment you need it. It now says so explicitly when it cannot inspect something.

## What was verified rather than assumed

- The hook-list breakage, by evaluating `HOOKS` both ways
- `pacman.conf` edits, by round-tripping a copy and diffing against the original
- The KWin work area, by querying KWin instead of computing from panel settings
- The initramfs, by listing it with `lsinitcpio -l` and confirming `systemd-cryptsetup`
  and `cryptsetup.target` are present (`lsinitcpio -a` was the wrong tool — see above)
- Package resolution, by full dependency resolution before installing
- Every internal documentation link, mechanically
- The absence of personal data, by scanning every file

## What was NOT tested

Stated plainly, because "written carefully" is not the same as "exercised", and the rest of
this page would be worth less if this section were missing.

| Path | Status |
| --- | --- |
| `install-omarchy-on-cachyos.sh` | **Exercised.** Dry-run plus real runs, including two failed pacman transactions that were diagnosed and fixed |
| `verify-reboot-safety.sh` | **Exercised heavily.** Four runs; two of its own bugs found and fixed that way |
| `omarchy-window --bare` | **Exercised.** Launched nested, sized to the work area |
| `block-omarchy-updates.sh` (install path) | **Exercised.** All four binaries guarded, `NoExtract` present, originals stashed |
| `clean-stale-boot-entries.sh --archive` | **Exercised once**, on one machine |
| `uninstall-omarchy-on-cachyos.sh` | **Never run.** Written and syntax-checked only |
| `block-omarchy-updates.sh --undo` | **Never run** |
| `OMARCHY_ALLOW_DANGEROUS=1` override | **Never run** |
| `clean-stale-boot-entries.sh --delete` | **Never run** |
| The "bootloader still references it" refusal | **Never triggered** — the one run had no references |
| `verify-reboot-safety.sh` on a busybox initramfs | **Never run.** That branch is reasoned, not observed |
| Any non-CachyOS base, or a non-KDE desktop | **Never run** |

The untested paths are mostly the reversal ones, which is the uncomfortable half: the code you
reach for when something has already gone wrong is the code with the least evidence behind it.
They are short and readable — read them before you rely on them, and keep the backups the
installer made.

One bug in exactly this category was found only by reading the output of a successful run: the
vault of stashed originals contained **symlinks that resolved back to the guard**, because
`/usr/share/omarchy/bin/omarchy-*` are symlinks into `/usr/bin` and `cp -a` preserved them as
such. The install path worked perfectly; `--undo` would have restored a guard over a guard.
Fixed with `cp -aL`, a repair pass for vaults written by earlier versions, and a refusal in
the guard to exec anything that is itself a guard.

## Privacy

The operator's machine is not described in this repository. Before publication every file was
scanned for the username, hostname, LUKS UUID, monitor UUIDs, email address, IP addresses and
hardware model. All are absent.

The scripts contain **no hardcoded machine values**. Geometry, work area, output names, UUIDs,
package lists and paths are all discovered at runtime, which is both why they are portable and
why they leak nothing. Commits are authored under a GitHub `noreply` address by choice.

The one identifier present is the GitHub account that owns the repository, which is
unavoidable for a public repository and was chosen deliberately.

### Data minimisation, not just secret-scrubbing

Removing secrets is the easy half. The harder one is the **mosaic effect**: individually
mundane facts that combine into a description of one machine. A form factor, a GPU vendor
pair, an exact resolution and scale factor, a partition size, a greeter, a filesystem — none
is sensitive alone, and together they describe a single computer.

So incidental specifics were generalised wherever they were not load-bearing:

| Detail | Replaced with | Why |
| --- | --- | --- |
| A named form factor | The neutral term for the component | The form factor was irrelevant to the bug being described |
| An exact resolution and scale factor | The scaling rule, plus a command to read your own | The rule is what transfers; the numbers described one machine |
| A reclaimed byte count and a partition size | A qualitative statement | Storage sizes describe hardware |
| Truncated machine-ids | `<active-token>`, `<stale-token>` | A 32-bit prefix of a real identifier is still an identifier |
| A named greeter and specific GPU vendors | Their general category | Enough to say what was exercised, not which machine |

Note that this table names *categories* rather than quoting the original strings. Documenting
a scrub by reprinting what was scrubbed would undo it.

What stays is what the project is *about* — a LUKS root on btrfs with limine and snapper —
because that is the subject matter, not an incidental detail about the author's hardware.

Documentation examples now use placeholders and teach the rule rather than reprinting one
machine's output. That is better documentation independently of the privacy benefit: a reader
should be running the command on their own system, not comparing against someone else's.

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
[copyleft](LICENSING.md) — you are free to reimplement any of it, and to do so knowing exactly
what the original was and was not.
