# Arrange Displays

A drag-and-drop monitor arrangement plugin for [Omarchy](https://omarchy.org/). Move your external monitors around visually, set resolution/refresh rate/scale/rotation per monitor, and switch between named layouts — the same way Windows' or macOS's display settings work, built as an [Omarchy Quickshell overlay](https://github.com/basecamp/omarchy) instead of a separate app.

## Features

- **Drag-and-drop positioning** for external monitors, with edge/center snapping. Your laptop panel is shown as a fixed reference point rather than something you drag — Omarchy already manages its position/scale/clamshell behavior, and this plugin stays out of that.
- **Per-monitor resolution, refresh rate, scale, and rotation** (0°/90°/180°/270°), picked from each monitor's actual advertised modes — not free-typed.
- **Effective logical size readout** next to the scale picker (e.g. `2560×1440 at scale 2 → 1280×720 usable`), so two monitors reporting the same resolution but different scale don't look identical.
- **Mirror-aware.** A monitor currently mirroring another display is shown non-editable, with a one-click "Stop mirroring" that hands off to Omarchy's own mirror toggle rather than fighting it.
- **Transactional apply.** Changes are applied live, then verified against the compositor's actual reported state, then held behind a 15-second "Keep these display settings?" countdown — reject or time out and it reverts automatically. Nothing is written to disk until you explicitly confirm.
- **Named layouts.** Save your current arrangement under a name and switch between saved layouts later — useful if you move between a desk setup, a single external at work, laptop-only while traveling, and so on.

## Requirements

- [Omarchy](https://omarchy.org/) on Hyprland.
- Everything else the plugin uses — `hyprctl`, `jq`, `gum` (for the layout picker) — ships with Omarchy already. No extra packages to install.

## Installation

```bash
omarchy plugin add https://github.com/dutchbase/omarchy-monitor-arrange.git --enable --yes
```

Or interactively, if you'd rather review the code before it's enabled:

```bash
omarchy plugin add https://github.com/dutchbase/omarchy-monitor-arrange.git
omarchy plugin enable dutchbase.monitor-arrange
```

This plugin is an overlay (`kind: "overlay"`), so `omarchy plugin add`/`enable` makes it available to summon, but doesn't put an entry in the Omarchy menu on its own — menu entries are user-owned config, not something a plugin can register for itself. Add these to `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"setup.monitors-arrange": {"icon":"󰍹","label":"Arrange Displays","action":"omarchy-shell shell summon dutchbase.monitor-arrange '{}'"},
"setup.monitors-restore": {"icon":"󰑙","label":"Restore Default Layout","action":"$HOME/.config/omarchy/plugins/dutchbase.monitor-arrange/bin/restore-layout default"},
"setup.monitors-switch": {"icon":"󰍹","label":"Switch Display Layout","action":"omarchy-launch-or-focus-tui $HOME/.config/omarchy/plugins/dutchbase.monitor-arrange/bin/restore-layout"}
```

(If you'd rather replace Omarchy's stock "Monitors" entry — which just opens `monitors.lua` in a text editor — reuse the id `setup.monitors` instead of `setup.monitors-arrange`.) The menu picks up JSONC edits without a restart.

## Usage

**Arrange Displays** opens the overlay: drag external monitors into position, select one to change its resolution/refresh rate/scale/rotation or turn it off, then **Apply**. You have 15 seconds to click **Keep changes**, click **Revert**, or do nothing and let it revert on its own — nothing is written to `~/.config/hypr/monitors.lua` until you keep it.

**Named layouts.** `layouts/` starts empty — nothing is saved automatically. Once you have an arrangement you want to keep:

```bash
# snapshot whatever's currently applied
~/.config/omarchy/plugins/dutchbase.monitor-arrange/bin/save-layout default

# switch to it later
~/.config/omarchy/plugins/dutchbase.monitor-arrange/bin/restore-layout default

# or pick from everything you've saved (also what "Switch Display Layout" runs)
~/.config/omarchy/plugins/dutchbase.monitor-arrange/bin/restore-layout
```

The **Restore Default Layout** menu entry above just runs `restore-layout default`, so naming your first save `default` is what makes that entry do something — pick any name for any layout, `default` isn't special beyond that. `restore-layout` with no name and nothing saved yet exits with an error rather than doing anything to your config.

## How it changes your config

Everything this plugin writes lives inside one clearly delimited block in `~/.config/hypr/monitors.lua`:

```lua
-- BEGIN dutchbase.monitor-arrange generated block
hl.monitor({ output = "DP-1", disabled = false, mode = "2560x1440@59.951Hz", position = "0x0", scale = 1, transform = 0 })
-- END dutchbase.monitor-arrange generated block
```

Anything you or Omarchy has written elsewhere in that file — comments, other monitor rules, the `GDK_SCALE` line — is left alone. Before every write, the previous `monitors.lua` is copied to a timestamped `.bak` file next to it, and the new config is verified with `hyprctl configerrors` before being kept; a bad config is rolled back automatically.

Nothing here runs on a timer or in the background. The plugin only ever touches your display configuration in direct response to something you did: opening the overlay and clicking Apply/Keep, or running `save-layout`/`restore-layout` yourself.

## What it intentionally doesn't do

- **Doesn't manage the laptop panel.** Omarchy has its own clamshell-detection watcher that reconciles the internal display's position/scale while docked; a second tool fighting it over the same output causes exactly the kind of flicker/drift that watcher exists to prevent. The panel is shown on the arrangement canvas for reference, never edited.
- **Doesn't set up mirroring.** Omarchy already has a mirror toggle (`omarchy-hyprland-monitor-internal-mirror`); this plugin detects when it's active and gets out of the way rather than reimplementing it.
- **Doesn't manage `GDK_SCALE`** or other global GTK scaling — that's a single system-wide value with no correct mapping once you have independently-scaled monitors.

## Uninstallation

```bash
omarchy plugin remove dutchbase.monitor-arrange
```

Then remove the three menu lines you added to `~/.config/omarchy/extensions/omarchy-menu.jsonc`. Uninstalling does not touch `~/.config/hypr/monitors.lua` — whatever layout is currently applied there stays applied; edit or restore-default it yourself if you want it back to Omarchy's stock catch-all.

## Contributing / issues

Open an issue or PR at [github.com/dutchbase/omarchy-monitor-arrange](https://github.com/dutchbase/omarchy-monitor-arrange).

## License

[MIT](LICENSE)
