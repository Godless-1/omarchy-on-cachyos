<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Licensing

This project is **copyleft**, deliberately and to the strongest degree the material allows.
If you build on it, your users get the same freedoms you got. That is the point, not an
oversight.

## The licences

| What | Licence | SPDX |
|---|---|---|
| Scripts — everything executable | **GNU AGPL v3 or later** | `AGPL-3.0-or-later` |
| Documentation, `README`, `docs/`, the SVGs | **Creative Commons BY-SA 4.0** | `CC-BY-SA-4.0` |

Full texts live in [`LICENSES/`](LICENSES/), fetched verbatim from
[gnu.org](https://www.gnu.org/licenses/agpl-3.0.txt) and
[creativecommons.org](https://creativecommons.org/licenses/by-sa/4.0/legalcode.txt).
`LICENSE` duplicates the AGPL text so GitHub's detector finds it.

## Why AGPL and not GPL

AGPL is GPL plus **section 13**: if you modify this and let people use it over a network,
those users are entitled to your source. These are local shell scripts, so §13 will rarely
fire — but it costs nothing and closes the hole in advance. The instruction was maximum
copyleft; AGPL is the FSF's strongest general-purpose copyleft licence, so that is what this
uses.

`-or-later` means you may comply with AGPLv3 or any later version the FSF publishes.

## Why CC BY-SA for the prose

The GPL family is written for software and reads awkwardly over documentation. **CC BY-SA
4.0** is the share-alike counterpart for written work: reuse the docs freely, including
commercially, but keep derivatives under BY-SA and credit the source. It is the licence
Wikipedia uses, and it is one-way compatible with GPLv3 should you ever need to fold prose
into code.

## What this means in practice

You may run, study, modify, redistribute and sell all of it. You may fold it into your own
tooling. What you may **not** do is take the scripts, improve them, and ship the result under
a licence that denies your users these same rights. Derivative scripts stay
`AGPL-3.0-or-later`; derivative prose stays `CC-BY-SA-4.0`.

There is no CLA, no copyright assignment, and no relicensing escape hatch reserved for
anyone — including the original author.

## Third-party material

This repository contains **no vendored third-party code**. The scripts are original work.

The documentation quotes short excerpts from [Omarchy](https://github.com/basecamp/omarchy)
— hook lists, a handful of lines from `omarchy-refresh-pacman`, `omarchy-menu`,
`omarchy-migrate` and `autostart.lua` — for identification and criticism. Omarchy is
MIT-licensed, which is GPL-compatible, and these excerpts are minimal, attributed, and
quoted to explain what the code does. Copyright in them remains with their authors.

Omarchy, Basecamp, DHH, CachyOS, KDE and Hyprland are unaffiliated with this project and have
not endorsed it. Their names are used descriptively.

## Machine-readable

Every file carries an `SPDX-FileCopyrightText` and `SPDX-License-Identifier` tag, and
[`REUSE.toml`](REUSE.toml) declares the rest. Verify with:

```bash
pipx run reuse lint
```
