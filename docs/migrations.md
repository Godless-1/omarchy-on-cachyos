<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Migrations

## The problem

Omarchy ships migration scripts in `/usr/share/omarchy/migrations/` — 96 of them in 4.0.2.
`omarchy-migrate` runs any whose marker file is absent:

```bash
STATE_DIR="${OMARCHY_MIGRATION_STATE:-$HOME/.local/state/omarchy/migrations}"
...
if [[ ! -f $marker ]]; then printf '%s\n' "$name"; fi
```

A marker is simply a zero-byte file named after the migration.

On an **ISO install**, `omarchy-provision-user --first-install` marks every shipped migration
complete, because a fresh install has nothing to migrate *from*:

```bash
for migration in "$OMARCHY_PATH"/migrations/*.sh; do
  [[ -f $migration ]] && touch "$state_dir/migrations/$(basename "$migration")"
done
```

On a **package-based install** that never runs. Every migration is pending, and
`omarchy-update` would execute all 96 against a system they were not written for.

## Why running them is wrong

Migrations are upgrade paths from older Omarchy versions. Representative examples:

```bash
# 1778623107.sh
echo "Install MPRIS support for mpv"
omarchy-pkg-add mpv-mpris
```

```bash
# 1785511354.sh
echo "Install qrencode for Wi-Fi QR sharing"
omarchy-pkg-add qrencode
```

Both packages are already in `omarchy-base.packages`, so a 4.0.2 install has them. The
migration is a no-op at best.

Others make real system changes:

```bash
# 1788124236.sh
echo "Disable SSH password authentication, or sshd itself when no key is authorized"
config=/etc/ssh/sshd_config.d/10-omarchy-hardening.conf
```

That one writes an sshd config and can disable the service. Reasonable as an upgrade step for
an Omarchy user; not something that should fire unannounced on someone else's machine.

## The fix

The markers ship in `/etc/skel/.local/state/omarchy/migrations/` — 96 zero-byte files, in the
**`omarchy`** package (not `omarchy-settings`). The installer seeds skel from both packages,
so a fresh install lands in the same state the ISO would produce.

To correct an install that already missed them:

```bash
mkdir -p ~/.local/state/omarchy/migrations
for m in /usr/share/omarchy/migrations/*.sh; do
  touch ~/.local/state/omarchy/migrations/"$(basename "$m")"
done
```

Confirm:

```bash
omarchy-migrate --pending    # expect no output
```

## Going forward

Future Omarchy releases ship *new* migrations, which will legitimately be pending and may
legitimately need to run. This is not a "mark everything forever" policy — it is a one-time
correction of first-install state. Review new ones individually:

```bash
omarchy-migrate --pending
cat /usr/share/omarchy/migrations/<name>.sh
```
