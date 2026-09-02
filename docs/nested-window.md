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
screen. Scaling makes this easy to get wrong: a display at 2× scale reports a logical
desktop half its pixel width and height, and less again at higher factors. Sizing a nested
output from pixel dimensions therefore produces a window larger than the screen. Read your
own values rather than assuming:

```bash
kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Output:|Geometry|Scale|enabled'
```

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

## The keyboard

KWin claims every <kbd>Meta</kbd> combination it holds a global shortcut for *before* the
nested compositor is offered the key — which is most of Omarchy's keymap. The protocol
built for this is `zwp_keyboard_shortcuts_inhibit_v1`, but the Wayland backend never
requests it: Hyprland implements only the server half, for its own clients. So the keys
have to be taken from KDE directly.

### Why not just block everything

The obvious lever is KGlobalAccel's `blockGlobalShortcuts`, driven from a KWin script on
window focus. That is what this used to do, and it was wrong in a way that only shows up
in use: it is all-or-nothing. It also silences

- <kbd>Super</kbd> **on its own**, KWin's modifier-only launcher shortcut, and
- <kbd>Alt</kbd>+<kbd>Tab</kbd>, your window switcher,

neither of which Omarchy uses and both of which you still want from Plasma while a nested
window happens to be focused.

### What it does instead

`omarchy-window-shortcuts` clears only the combinations that carry the **Meta modifier**.
That single rule produces both exceptions for free:

| | Why it survives |
| --- | --- |
| <kbd>Super</kbd> alone | It is a KWin *modifier-only* shortcut, not a KGlobalAccel binding at all, so it is never enumerated and never touched. |
| <kbd>Alt</kbd>+<kbd>Tab</kbd> | "Walk Through Windows" is bound to **both** `Meta+Tab` and `Alt+Tab`. Only the Meta alternate is removed, so the action keeps working. |

The same is true of every other non-Meta binding that shares an action with a Meta one —
<kbd>Print</kbd> for Spectacle, the dedicated lock key, the media keys.

```bash
omarchy-window-shortcuts suppress --dry-run   # see exactly what would change
omarchy-window-shortcuts status               # what is borrowed right now
omarchy-window-shortcuts restore              # give it all back
```

### It is not focus-driven, and why

The old KWin script toggled on focus. This one cannot: a KWin script's `callDBus` marshals
a bool fine — which is all `blockGlobalShortcuts` needed — but not the integer array that
setting a shortcut requires. KWin just logs `couldn't handle call to setForeignShortcut,
no slot matched`. Driving it from focus would mean shipping a D-Bus service purely to relay
a boolean, so the keys are instead lent for as long as the window is open.

The visible cost: while an Omarchy window is open but *not* focused, Plasma's
<kbd>Meta</kbd>+<kbd>key</kbd> shortcuts do nothing. Everything else — <kbd>Super</kbd>,
<kbd>Alt</kbd>+<kbd>Tab</kbd>, media keys, <kbd>Print</kbd> — is unaffected.

### If a session dies without handing them back

Every original is written to a backup file *before* the first shortcut changes:

```
~/.local/share/omarchy-cachyos/kde-shortcuts.backup.json
```

A session killed before it can restore leaves that file behind. The next `omarchy-window`
replays it automatically, `omarchy-on-cachyos` reports it as a fault and offers to fix it,
and `omarchy-window-shortcuts restore` does it directly. Failing all of that, KDE never
touches an action's *default* column, so **System Settings → Shortcuts → Reset to
Defaults** always gets you back.

## Caveats

- The KWin rule is **forced**, so the window cannot be dragged or resized. Use `--no-rule`
  to float it.
- The rule stores today's geometry. Re-run after changing monitors or moving panels.
- Nested output renders at scale 1 inside a window the host then scales, so text looks
  softer than the real session. An artifact of nesting, not of Omarchy.
