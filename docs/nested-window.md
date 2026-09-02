<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# The nested window

## Why this works

Hyprland's Aquamarine backend selects a **Wayland backend** when `WAYLAND_DISPLAY` is set,
rather than taking over a DRM device. The whole Omarchy desktop then runs as an ordinary
window on your existing session:

```text
Output WAYLAND-1: initialized
reopenDRMNode: opening node /dev/dri/renderD128
Created a GBM allocator with drm fd 17
```

Same kernel, same `$HOME`, same files. There is no guest, so there is no file sharing to
configure — the reason a VM was considered and rejected for this use case.

## Exact fitting

A nested output larger than the host's **logical** desktop produces a window bigger than the
screen. On HiDPI this bites hard: a <width>×<height> display at 2× scale has a logical desktop of
only <logical-size>, so a naive `1920x1080` default does not fit.

The script asks KWin for the authoritative work area — screen minus panels — via its
scripting API:

```js
var a = workspace.clientArea(KWin.MaximizeArea, workspace.activeScreen, workspace.currentDesktop);
print("OMARCHY_WA " + a.x + " " + a.y + " " + a.width + " " + a.height);
```

The nested output is sized to exactly that, and a KWin rule pins the window there with no
decoration — a titlebar would shrink the client area below the output size and reintroduce
scaling:

```ini
[omarchy-nested-window]
wmclass=aquamarine
wmclassmatch=1
position=<x>,<y>
positionrule=2
size=<w>,<h>
sizerule=2
noborder=true
noborderrule=2
```

`aquamarine` is the window class Hyprland's backend registers.

Outside KDE the script falls back to the largest **enabled** output — enabled matters,
because a disabled output still reports geometry.

## `--bare`

Omarchy's `default/hypr/autostart.lua` runs on session start:

```lua
hl.exec_cmd("systemctl --user import-environment $(env | cut -d'=' -f 1)")
hl.exec_cmd("dbus-update-activation-environment --systemd --all")
hl.exec_cmd("omarchy-launch-shell")
...
```

The first two lines push the **nested** session's `WAYLAND_DISPLAY` into your user systemd
manager, which then misdirects apps launched later from your host session.

There is no config flag to disable autostart — `default.hypr.omarchy` requires it
unconditionally. `--bare` pre-seeds Lua's module cache so `require` becomes a no-op, then
starts only the shell:

```lua
package.loaded["default.hypr.autostart"] = true
require("default.hypr.omarchy")
hl.on("hyprland.start", function() hl.exec_cmd("omarchy-launch-shell") end)
```

Starting the shell matters: `omarchy-menu` is a thin IPC wrapper —

```bash
exec omarchy-shell shell toggle omarchy.menu "$(menu_payload "$route")"
```

— so without `omarchy-launch-shell` running, `SUPER+SPACE` has no backend and silently does
nothing. The binding itself is fine.

## Caveats

- The KWin rule is **forced**, so the window cannot be dragged or resized. Use `--no-rule`
  to float it.
- The rule stores today's geometry. Re-run after changing monitors or moving panels.
- Nested output renders at scale 1 inside a window the host then scales, so text looks
  softer than the real session. An artifact of nesting, not of Omarchy.
