-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
-- List current monitors and supported resolutions with: hyprctl monitors all

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 1.6

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })

-- Configure a specific monitor.
-- hl.monitor({ output = "DP-2", mode = "2560x1440@144", position = "0x0", scale = 1 })

-- Portrait/rotated secondary monitor (transform: 1 = 90°, 3 = 270°).
-- hl.monitor({ output = "DP-2", mode = "preferred", position = "auto", scale = 1, transform = 1 })

-- The laptop panel needs an EXPLICIT position, not the catch-all's "auto".
-- With it on "auto" while the externals carry absolute coordinates, Hyprland
-- re-places it on every reload, nudges the externals, and each monitor-change
-- event retriggers the clamshell watcher's 1/3/7s resync -- coordinates drift
-- outward forever and the plugin's post-apply verification then fails.
-- Laptop sits on the lower row, centred under the seam between the two
-- externals: its logical width is 3840/1.6 = 2400, so 2560 - 1200 = 1360.
hl.monitor({ output = "eDP-1", mode = "preferred", position = "1360x1440", scale = 1.6 })
-- BEGIN dutchbase.monitor-arrange generated block
hl.monitor({ output = "DP-7", disabled = false, mode = "2560x1440@59.951Hz", position = "0x0", scale = 1, transform = 0 })
hl.monitor({ output = "DP-1", disabled = false, mode = "2560x1440@59.951Hz", position = "2560x0", scale = 1, transform = 0 })
-- END dutchbase.monitor-arrange generated block
