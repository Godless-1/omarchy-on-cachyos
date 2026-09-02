<!--
SPDX-FileCopyrightText: 2026 Godless-1
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# The nested window

## What it is for

Running Omarchy in a window is not a degraded mode of the login session. It exists so that
learning Hyprland costs you nothing you cannot walk away from.

A tiling compositor asks you to relearn how you open a terminal, move between windows and
place things on screen. Done as a login session, that means every one of those small
frustrations arrives while it is also the only desktop you have — and the escape hatch is a
logout. In a window, the escape hatch is moving the mouse. Your usual session is still
running behind it, still logged in, tabs and editor untouched.

So the window is where you build the muscle memory, and the login session is where you use
it once you have. The same install gives you both; nothing has to be decided up front.

Two consequences worth knowing, both covered below: the nested session has to be *given*
Omarchy's keyboard shortcuts, because your host desktop claims most of them first, and
anything Omarchy launches has to be kept inside the window rather than escaping to the host.

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

## Where launched apps end up

Omarchy does not start apps directly. Every launcher — the agent keybinding, the
terminal, the file manager, 31 call sites in all — goes through `uwsm-app`, which
hands the command to `wayland-wm-app-daemon.service`.

That is a systemd **user** unit. It carries the environment of whichever session
last imported one, which on a Plasma host is Plasma's. Probing it on this machine,
from a shell that had every nested variable set:

```console
$ uwsm-app -- sh -c 'echo "$WAYLAND_DISPLAY $XDG_CURRENT_DESKTOP ${HYPRLAND_INSTANCE_SIGNATURE:-none}"'
wayland-0 KDE none
```

`wayland-0` is Plasma. So anything Omarchy launches from inside the nested window
opens **on the host desktop**, detached from the compositor that asked for it —
which looks exactly like the launcher being broken, because nothing appears where
you are looking.

`uwsm-app` has no bypass flag, so `omarchy-window` writes a `uwsm-app` of its own
into a temporary directory and puts it first on the nested session's `PATH`. It
runs the command in place, so it inherits the nested compositor. Hyprland's
children inherit that `PATH`, so it covers a terminal you open by hand as well as
anything the bindings start.

The shim only models `uwsm-app -- <command>`, which is the form all 31 call sites
use. Anything else — options that take a separate value, where guessing would
`exec` the *value* as a command — is handed to the real `uwsm-app` rather than
parsed on a guess. `uwsm app --` (the separate binary, used only by
`omarchy-windows-vm`) is not shimmed and still goes to the host.
[`test/test-uwsm-shim.sh`](../test/test-uwsm-shim.sh) extracts the shim from
`omarchy-window` itself and exercises every one of those cases.

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

### More than one window at a time

Each nested window wants the same Meta+ keys, so the borrow is **reference counted**. A
window claims when it opens and releases when it closes, and the keys go back to Plasma only
when the last holder lets go. Before that, the first window to close handed everything back
while the others were still using them — their Omarchy bindings simply stopped responding,
with nothing on screen to say why.

A holder is a pid *plus that process's start time*, so a recycled pid cannot be mistaken for
a session that is still running. Dead holders are pruned on every operation, which is what
makes a killed session heal instead of stranding the keys:

```bash
omarchy-window-shortcuts suppress --claim $$    # a window opening
omarchy-window-shortcuts restore --release $$   # a window closing
omarchy-window-shortcuts restore                # the escape hatch: ignores holders
```

`suppress` never re-scans while a backup exists. The live state is already suppressed, so a
re-scan would record the *suppressed* values as if they were the originals, and the real ones
would be gone for good.

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
