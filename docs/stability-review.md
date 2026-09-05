<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Stability and recovery

Both modes use your existing files and installed applications: a nested window in Plasma, or a dedicated Omarchy login session. Neither requires a VM. The nested browser normally uses a separate profile to prevent an existing host browser from capturing its windows; this also means separate browser logins.

## Recovery fixes after 1.4.6

- Uninstall stops when package removal fails or cannot be verified. It retains the repository and guards; a failed package-removal transaction also leaves session files intact. Resolve the reported pacman error and rerun uninstall. Do not remove guards to work around a dependency conflict.
- Package removal uses one nonrecursive transaction for the Omarchy packages. Applications and dependencies are not recursively removed. Package scripts may still make changes; this is not a byte-for-byte restoration of the host.
- `ooc uninstall --keep-apps` removes the session entry while retaining packages, the repository and protective guards. This deliberately retains update protection for those packages.
- `ooc uninstall --dry-run` preserves empty skills directories and does not request sudo authentication. It may query installed-package state.
- `ooc preserve-identity --undo-branding` restores saved Omarchy artwork without removing host identity protection. `--undo` is an alias for this narrow operation. To deliberately remove host protection, use `--remove-protection`; it does not restore session artwork. Reapply protection with `--apply`.

Saved artwork is required for artwork restoration. Keep the install backups and your own backups. The uninstaller retains personal configurations and applications; it is not a complete machine rollback. A package removal or install can run third-party scripts that these fixture tests do not simulate.

## Evidence and limits

CI and fixture tests cover command routing, package layout, failed removal, retained guards, empty-directory previews, artwork restoration, shortcut bookkeeping, generated configuration and watchdog behavior. Fixtures test recovery without removing packages or changing the bootloader on the host. The host filesystem should be mounted read-only when running the suites, with temporary storage writable and desktop connections disabled.

Boot inspection checks known prerequisites and image contents. It cannot prove firmware behavior, successful root unlocking or a future reboot. A real reboot and interactive desktop checks remain separate validation steps.

Before declaring another release stable, exercise panel-close and Super+Q, multiple nested windows, shortcut restoration, browser placement and surviving unrelated applications. Record what actually happened, including skipped checks. Do not infer that every child process exits merely because the compositor exits.

## Privacy correction

A review found a real machine identifier reused in three test fixtures. The current fixtures now use visibly synthetic values, and a regression check enforces that convention for the named machine-identifier variables. This check is narrow; it is not a general secret scanner.

Older commits, source archives and binary packages may retain the original value. Updating the working tree does not scrub history, third-party clones or downloaded artifacts. Historical cleanup needs a coordinated rewrite and replacement of affected published artifacts, with no promise of retracting copies already downloaded. Never quote the identifier in an issue, changelog or test failure.

## Release housekeeping

GitHub releases older than 1.4.6 were privately archived before removal at the maintainer's request. Source tags remain available for historical inspection. Do not treat an old tag as a recommended installation. The original 1.4.6 package does not include the subsequent fixes described here.
