-- Auto Zoom for Xournal++: zooms in where the pen writes, zooms out when writing stops.
-- Author: Wissam Jassim (written with Claude), 2026-11-13. Version 0.17: 2026-11-24.
-- Copyright (c) 2026 Wissam Jassim. MIT licence, see LICENSE in the repository root.
-- SPDX-License-Identifier: MIT
--
-- A REAL Xournal++ zoom: the PDF is redrawn at the new size, so the page stays sharp.
--
-- KEYS (also in the Plugin menu; change them in settings.txt: KEY_TOGGLE, KEY_NOW, KEY_PANEL,
--       with Xournal++ closed, e.g. KEY_TOGGLE=<Control><Shift>Z or none)
--   Ctrl+Alt+F5   auto zoom ON / OFF
--   Ctrl+Alt+F6   zoom in at the pen now / zoom out now   (only while ON)
--   Ctrl+Alt+F7   settings panel (a small floating window; every setting, saved by itself)
--   (no key)      pause: zoom, edge slide and follow all stop (KEY_PAUSE; also a button in the panel and on the tool dock)
--
-- HOW IT BEHAVES (while ON)
--   * Zoom in: the pen hovers still for a moment, or you simply start writing. The spot
--     under the pen stays under the pen.
--   * The view NEVER changes while the pen tip is down. Every movement happens with the
--     tip up; a zoom that starts while you write moves only in the gaps between strokes.
--   * Follow: zoomed in, writing that leaves the still zone (the middle part of the view)
--     makes the view glide after it, once the pen has been up for a moment.
--   * Edge slide: hold the pen near an edge of the page area (tip up) to slide the view.
--   * Zoom out: some seconds without writing or pen movement. The view returns to where
--     it was. If you went to another page meanwhile, it returns to the same place there.
--   * You change the zoom yourself while zoomed in (toolbar, tablet dial, Ctrl+wheel):
--     the plugin takes your zoom as the new zoom level and remembers it.
--   * Pause (0.17): everything stops. The view stays as it is: no zoom in, no zoom out, no
--     edge slide, no follow glide. Ctrl+Alt+F6 still zooms in / out by hand. Pause while OFF switches auto zoom on, paused.
--     Switching OFF ends the pause; every start of Xournal++ is unpaused.
--   * All movement uses a critically damped spring: soft start, soft stop, no overshoot,
--     and it can change direction at any moment without a jump.
--
-- HOW IT WORKS
--   The plugin API has no pen events and no timer. This build ships LuaGObject (GTK
--   bridge), which gives a GLib timer; the timer POLLS the pointer position on the page
--   canvas (widget "GtkXournal") and the tip state (button 1). The settings panel is
--   polled the same way: no signal handler anywhere.
--   NEVER connect a Lua handler to a signal: a test that did so on the canvas crashed
--   Xournal++ (stack overflow). NEVER require("ffi") here: an ffi.dll on the system path may be
--   built for another Lua version.
--
--   Keeping a point fixed while zooming needs the page layout, because the gaps between
--   pages do not scale: page i starts at  PAD + i * GAP + (heights of earlier pages) * s,
--   where s = pixels per PDF point at the current zoom. s is read back from the scroll
--   range after every zoom step, so no DPI value is needed.
--
-- LIMITS
--   * Single column of pages (the normal layout). Paired pages or extra vertical space:
--     the plugin notices the model does not fit and falls back to a simple formula.
--   * A mouse hovering still on the page also triggers the zoom.

local CFG = {
    FACTOR          = 1.6,    -- zoom in by this factor
    LEARN           = true,   -- a zoom change by hand while zoomed in becomes the new FACTOR
    ZOOM_MS         = 400,    -- zoom smoothness (spring time; the movement takes about 3 times this)
    TICK_MS         = 16,     -- timer interval
    WIN_CACHE_MS    = 250,    -- quick look at the shown Xournal++ windows this often (see windowsInfo)
    WIN_FULL_MS     = 2000,   -- full look at all ~40 windows this often
    IDLE_EVERY      = 2,      -- not zoomed and nothing moving: run every 2nd tick only (32 ms)
    ERASER_ZOOMS    = false,  -- true: the eraser starts a zoom like the pen (before 0.11 it always did)
    HOVER_TRIGGER   = true,   -- zoom in when the pen hovers still
    DWELL_MS        = 400,    --   for this long
    RADIUS          = 40,     --   within this many pixels
    ALIVE_MS        = 150,    --   and the pen was seen moving this recently (a pen lifted away is frozen)
    STALE_MS        = 500,    --   no movement at all for this long = pen lifted away, the wait starts again
    WRITE_TRIGGER   = true,   -- zoom in when writing starts
    WRITE_MS        = 200,    --   after this much pen-down time (short strokes add up)
    WRITE_GAP_MS    = 1000,   --   a pause this long resets the count
    IDLE_MS         = 3000,   -- zoom out after this long without writing or pen movement
    MOVE_PX         = 8,      -- pen movement below this is jitter, not activity
    FOLLOW          = true,   -- zoomed in: the view glides after writing that leaves the still zone
    STILL           = 60,     --   still zone, percent of the view
    FOLLOW_DELAY_MS = 350,    --   the pen must be up this long first (not between letters)
    FOLLOW_MS       = 450,    --   glide smoothness (spring time)
    PAN             = true,   -- slide the view when the pen is held near an edge (tip up)
    PAN_IDLE        = false,  --   also when not zoomed in
    EDGE            = 0.10,   --   edge zone, share of the view size
    PAN_DELAY_MS    = 500,    --   tip must be up this long first (never between strokes)
    PAN_ALIVE_MS    = 400,    --   and the pen was seen moving this recently
    PAN_SPEED       = 900,    --   pixels per second at the very edge
    START_ON        = false,  -- switch auto zoom on when Xournal++ starts
    PANEL_AT_START  = false,  -- open the settings panel when Xournal++ starts
    PANEL_X         = -1,     -- panel position (saved by itself)
    PANEL_Y         = -1,
    PANEL_W         = -1,     -- panel size (saved by itself; -1 = fit the settings)
    PANEL_H         = -1,
    PAD             = 10,     -- layout: space before the first page (pixels, does not scale)
    GAP             = 15,     -- layout: space between pages (pixels, does not scale)
    LOG             = true,   -- write state changes to %TEMP%\autozoom.log
    LEARN_MIN       = 1.25,   -- a hand zoom that ends below this factor is "zoom out", not a new level
    LEARN_SETTLE_MS = 700,    -- the hand zoom must rest this long before its level is learned
    -- shortcut keys (GTK form, e.g. <Control><Alt>F5 or <Shift>F2; none = no key). Read at start only.
    KEY_TOGGLE      = "<Control><Alt>F5",   -- auto zoom ON / OFF
    KEY_NOW         = "<Control><Alt>F6",   -- zoom in at the pen now / zoom out now
    KEY_PANEL       = "<Control><Alt>F7",   -- settings panel
    KEY_PAUSE       = "none",               -- pause zoom in / out (0.16; F5-F12 are taken by the other plugins)
}

-- The settings panel: one row each. `mult` turns the stored value into the shown one.
local CONTROLS = {
    {key = "FACTOR", group = "Zoom", label = "Zoom level (x)", min = 1.1, max = 4.0, step = 0.05, digits = 2, mult = 1,
     tip = "How much the page is enlarged when the plugin zooms in.\n1.60 = everything 1.6 times bigger. Higher = closer.\nA change here while zoomed in is applied at once."},
    {key = "ZOOM_MS", label = "Smoothness (s)", min = 0.1, max = 1.5, step = 0.05, digits = 2, mult = 0.001,
     tip = "How soft the zoom movement is. The whole movement takes about 3 to 4 times this value.\nLower = quicker and snappier. Higher = slower and softer.\nPen strokes look a little soft while the zoom is moving (Xournal++ redraws them sharp when it stops), so a lower value also means a shorter soft moment."},
    {key = "LEARN", label = "Learn the zoom level when I zoom by hand",
     tip = "Ticked: when you change the zoom yourself while zoomed in (toolbar buttons, tablet dial, Ctrl + wheel), your zoom becomes the new zoom level and is remembered.\nNot ticked: a zoom by hand makes the plugin let go and keep your view."},
    {key = "DWELL_MS", check = "HOVER_TRIGGER", group = "When to zoom", label = "Zoom in: pen hovers still (s)", min = 0.1, max = 2.0, step = 0.05, digits = 2, mult = 0.001,
     tip = "Ticked: holding the pen still just above the tablet, over the page, for this long zooms in at that spot.\nLower = reacts faster but zooms more often by accident. Higher = you must hold still longer."},
    {key = "WRITE_MS", check = "WRITE_TRIGGER", label = "Zoom in: writing (s)", min = 0.0, max = 1.0, step = 0.05, digits = 2, mult = 0.001,
     tip = "Ticked: starting to write zooms in, after this much pen-down time (short strokes add up).\nThe view never moves while the tip is down: the zoom moves when you lift the pen.\nLower = zooms on the first short stroke. Higher = a dot or a tick does not zoom."},
    {key = "IDLE_MS", label = "Zoom out after (s)", min = 0.5, max = 15.0, step = 0.5, digits = 1, mult = 0.001,
     tip = "The plugin zooms back out after this long without writing and without pen movement.\nHigher = stays zoomed in longer while you talk."},
    {key = "STILL", check = "FOLLOW", group = "Follow writing", label = "On: still zone (%)", min = 0, max = 90, step = 5, digits = 0, mult = 1,
     tip = "Ticked: while zoomed in, the view glides after your writing when it leaves the still zone.\nThe still zone is the middle part of the view, this many percent of its width and height. Writing inside it does not move the view.\nLower = the view follows sooner and more often. Higher = the view moves only when you write near the edge."},
    {key = "FOLLOW_DELAY_MS", label = "After the pen is up (s)", min = 0.1, max = 1.5, step = 0.05, digits = 2, mult = 0.001,
     tip = "The follow glide starts only after the pen has been up this long.\nKeep it longer than your pause between letters, so the page does not move inside a word."},
    {key = "FOLLOW_MS", label = "Smoothness (s)", min = 0.1, max = 1.5, step = 0.05, digits = 2, mult = 0.001,
     tip = "How soft the follow glide is. Lower = quicker. Higher = slower and softer."},
    {key = "EDGE", check = "PAN", group = "Edge slide", label = "On: edge zone (%)", min = 5, max = 30, step = 1, digits = 0, mult = 100,
     tip = "Ticked: holding the pen (tip up) near an edge of the page area slides the view that way: up, down, left or right.\nThe edge zone is this many percent of the view on each side. Higher = a wider zone, easier to reach, but it starts sliding sooner."},
    {key = "PAN_SPEED", label = "Speed (pixels / s)", min = 200, max = 3000, step = 50, digits = 0, mult = 1,
     tip = "Slide speed with the pen at the very edge. Nearer the inner side of the edge zone it is slower."},
    {key = "PAN_IDLE", label = "Also when not zoomed in",
     tip = "Ticked: the edge slide also works when the page is not zoomed in, so the pen can scroll the page at any time."},
    {key = "START_ON", group = "Start-up", label = "Switch on when Xournal++ starts",
     tip = "Ticked: auto zoom is ON by itself every time Xournal++ starts.\nFirst check that Xournal++ closes without a crash while auto zoom is ON."},
    {key = "PANEL_AT_START", label = "Open this panel when Xournal++ starts",
     tip = "Ticked: this panel opens by itself every time Xournal++ starts, at the place where you left it."},
}

local DEFAULTS = {}
for k, v in pairs(CFG) do DEFAULTS[k] = v end

local LOGFILE = rawget(_G, "AUTOZOOM_LOG_FILE") or ((os.getenv("TEMP") or ".") .. "\\autozoom.log")

local function log(s)
    if not CFG.LOG then return end
    local f = io.open(LOGFILE, "a")
    if f then
        f:write(os.date("%H:%M:%S "), tostring(s), "\n")
        f:close()
    end
end

local function notify(message)
    log((message:gsub("\n", " | ")))
    if app.openDialog then
        app.openDialog(message, {"OK"}, "", false)
    else
        app.msgbox(message, {[1] = "OK"})
    end
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- ------------------------------------------------------------------ settings file
local function settingsPath()
    local o = rawget(_G, "AUTOZOOM_SETTINGS_FILE")
    if type(o) == "string" then return o end
    local src = (debug and debug.getinfo) and debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(%a:[/\\].*)[/\\][^/\\]*$")
    if dir then return dir .. "\\settings.txt" end
    return (os.getenv("LOCALAPPDATA") or ".") .. "\\xournalpp\\autozoom-settings.txt"
end
local SETTINGS = settingsPath()

local function limits(key)
    for _, c in ipairs(CONTROLS) do
        if c.key == key and c.min then return c.min / c.mult, c.max / c.mult end
    end
end

-- A shortcut text is taken only in the GTK form: <Modifier>...Key. Anything else: default.
local MODS = {control = true, ctrl = true, primary = true, alt = true, shift = true, super = true, meta = true}
local function validKey(v)
    if v:lower() == "none" then return true end
    local rest = v
    while true do
        local m, r = rest:match("^<(%a+)>(.*)$")
        if not m then break end
        if not MODS[m:lower()] then return false end
        rest = r
    end
    return rest:match("^[%w_]+$") ~= nil
end

-- Returns the number of settings found in the file (nil = no file).
local function loadSettings()
    local f = io.open(SETTINGS, "r")
    if not f then return nil end
    local seen = 0
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        local d = k and DEFAULTS[k]
        if d ~= nil then seen = seen + 1 end
        if type(d) == "string" then
            if validKey(v) then CFG[k] = v else log("settings: bad shortcut " .. k .. "=" .. v .. ", default kept") end
        elseif type(d) == "boolean" then
            if v == "true" then CFG[k] = true elseif v == "false" then CFG[k] = false end
        elseif type(d) == "number" then
            local n = tonumber(v)
            if n and n == n then
                local lo, hi = limits(k)
                if lo then n = clamp(n, lo, hi) end
                CFG[k] = n
            end
        end
    end
    f:close()
    return seen
end

local function saveSettings()
    local keys = {}
    for k in pairs(DEFAULTS) do keys[#keys + 1] = k end
    table.sort(keys)
    local f = io.open(SETTINGS, "w")
    if not f then log("cannot write " .. SETTINGS) return end
    f:write("# Auto zoom settings. Written by the plugin (settings panel).\n")
    f:write("# KEY_... = shortcut keys, e.g. <Control><Alt>F5 or <Shift>F2 (none = no key). Change them with Xournal++ closed.\n")
    for _, k in ipairs(keys) do f:write(k, "=", tostring(CFG[k]), "\n") end
    f:close()
end

local dirtyAt = nil     -- settings changed at this time (ms), not yet saved

-- ------------------------------------------------------------------ GTK bridge
local B = nil
local function bindings()
    if B then return B end
    local ok, lgo = pcall(require, "LuaGObject")
    if not ok then                 -- many Linux builds have lgi (LuaGObject began as a copy of it)
        local okL, l = pcall(require, "lgi")
        if not okL then return nil, "LuaGObject / lgi not found: " .. tostring(lgo) end
        ok, lgo = true, l
    end
    local okG, GLib = pcall(function() return lgo.GLib end)
    if not okG then return nil, "GLib failed: " .. tostring(GLib) end
    local okD, Gdk = pcall(lgo.require, "Gdk", "3.0")
    if not okD then return nil, "Gdk 3.0 failed: " .. tostring(Gdk) end
    local okT, Gtk = pcall(lgo.require, "Gtk", "3.0")
    if not okT then return nil, "Gtk 3.0 failed: " .. tostring(Gtk) end
    B = {GLib = GLib, Gdk = Gdk, Gtk = Gtk}
    return B
end

local function walk(b, w, depth, visit)
    visit(w, depth)
    local okC, isC = pcall(function() return b.Gtk.Container:is_type_of(w) end)
    if okC and isC then
        local okL, kids = pcall(function() return w:get_children() end)
        if okL and kids then
            for _, k in ipairs(kids) do walk(b, k, depth + 1, visit) end
        end
    end
end

-- The page canvas ("GtkXournal"), its scrolled window and the main window.
local function findCanvas(b)
    local res = {}
    for _, top in ipairs(b.Gtk.Window.list_toplevels()) do
        local okV, vis = pcall(function() return top:get_visible() end)
        if okV and vis and not res.canvas then
            local parents = {}
            walk(b, top, 0, function(w, depth)
                parents[depth] = w
                local okN, n = pcall(function() return w:get_name() end)
                if okN and n == "GtkXournal" and not res.canvas then
                    res.canvas, res.top = w, top
                    for d = depth - 1, 0, -1 do
                        local p = parents[d]
                        local okS, isS = pcall(function() return b.Gtk.ScrolledWindow:is_type_of(p) end)
                        if okS and isS then res.scrolled = p break end
                    end
                end
            end)
        end
    end
    return res
end

-- ------------------------------------------------------------------ state
local st = {mode = "OFF"}
local ui = nil          -- {canvas, scrolled, top, gdkwin, pointer}

-- Scroll position {x, y, width, height} of the page area, in layout pixels.
-- 0.14: the stable Xournal++ 1.3.x has no app.getScrollPos (nightly only, PR #7278). That function
-- returns the layout's visible rectangle, which IS the page area's scroll bars: value = x / y,
-- page size = width / height (checked live in the nightly: 0.000 px difference at every zoom,
-- scroll and page jump, also right after setZoom). So without it the scroll bars are read.
local function scrollPos()
    if app.getScrollPos then return app.getScrollPos() end
    if not ui.hadj then ui.hadj, ui.vadj = ui.scrolled:get_hadjustment(), ui.scrolled:get_vadjustment() end
    local h, v = ui.hadj, ui.vadj    -- kept: 0.017 ms per read instead of 0.08 ms (measured)
    return {x = h:get_value(), y = v:get_value(), width = h:get_page_size(), height = v:get_page_size()}
end
local panel = nil       -- the settings panel, when open
local timerGen, timerLive = 0, false
local costLog = nil     -- tick cost totals for the log

local function nowMs() return B.GLib.get_monotonic_time() / 1000 end

local function markDirty() dirtyAt = B and nowMs() or 0 end

-- 0.13: ON / OFF is published in the process environment (XOPP_AUTOZOOM_ON = 1 / 0), so the
-- tool dock plugin (its own Lua state) can light its "Auto zoom" button. Set only when it changes.
local publishedOn = nil
local function publishOn(on)
    if on == publishedOn or not B then return end
    publishedOn = on
    pcall(function() B.GLib.setenv("XOPP_AUTOZOOM_ON", on and "1" or "0", true) end)
end

-- 0.16: pause. 0.17: the pause stops everything: no zoom in, no zoom out, no edge slide, no follow
-- glide (a zoom in / out already under way finishes, so the view never stops half way). Published as
-- XOPP_AUTOZOOM_PAUSED = 1 / 0 for tool-dock. Not saved: every start is unpaused; OFF ends it.
local paused = false
local publishedPaused = nil
local function publishPaused()
    if paused == publishedPaused or not B then return end
    publishedPaused = paused
    pcall(function() B.GLib.setenv("XOPP_AUTOZOOM_PAUSED", paused and "1" or "0", true) end)
end

local function setMode(m, why)
    if st.mode ~= m then log(st.mode .. " -> " .. m .. (why and ("  (" .. why .. ")") or "")) end
    st.mode = m
    if m == "OFF" then paused = false end
    publishOn(m ~= "OFF")
    publishPaused()
end

-- Finds the page area and the pointer. Returns true, or false + reason.
local function attach()
    local b, err = bindings()
    if not b then return false, tostring(err) end
    local ok, res = pcall(findCanvas, b)
    if not ok or not res.canvas or not res.scrolled then
        return false, "page area not found. " .. tostring(ok and "" or res)
    end
    local okW, gdkwin = pcall(function() return res.canvas:get_window() end)
    local okP, pointer = pcall(function() return b.Gdk.Display.get_default():get_default_seat():get_pointer() end)
    if not okW or not gdkwin or not okP or not pointer then return false, "pointer not available." end
    ui = {canvas = res.canvas, scrolled = res.scrolled, top = res.top, gdkwin = gdkwin, pointer = pointer}
    return true
end

-- Is the pointer over the settings panel (which floats above the page)?
local function overPanel()
    if not panel then return false end
    local ok, over = pcall(function()
        local gw = panel.win:get_window()
        if not gw then return false end
        local _, x, y = gw:get_device_position(ui.pointer)
        if type(x) ~= "number" or type(y) ~= "number" then return false end
        return x >= -12 and y >= -45 and x < gw:get_width() + 12 and y < gw:get_height() + 12
    end)
    return ok and over or false
end

-- One look at all windows of Xournal++, kept for WIN_CACHE_MS. Xournal++ has about 40 of them
-- (most are hidden menus), and asking each one costs time: done at every tick (16 ms) it took
-- about 6 ms, a third of the app's time, which made Xournal++ slow (0.10, measured). Gives:
-- active = a window of Xournal++ is the active window of the desktop (`is_active` is a property
-- in LuaGObject, a plain boolean: calling it as a method fails; unknown counts as "yes");
-- frames = outer rectangles (title bar included) of the other shown windows.
local winCache = nil
-- Looks at a list of windows; returns the result table and the windows that were shown.
local function scanWindows(list, now)
    local res = {at = now, active = true, frames = {}, shown = {}}
    local known, active, broken = false, false, false
    for _, t in ipairs(list) do
        local ok = pcall(function()
            if t:get_visible() then
                res.shown[#res.shown + 1] = t
                local a = t.is_active
                if a == true then active = true end
                if a == false then known = true end
                if ui and t ~= ui.top then
                    local gw = t:get_window()
                    if gw and gw:is_viewable() then
                        local r = gw:get_frame_extents()
                        res.frames[#res.frames + 1] = {x = r.x, y = r.y, width = r.width, height = r.height}
                    end
                end
            end
        end)
        if not ok then broken = true end
    end
    res.active = active or not known
    return res, broken
end

-- Two speeds (0.12): a FULL look at all ~40 windows every WIN_FULL_MS (about 6 ms), and in between
-- a quick look (every WIN_CACHE_MS) at only the windows that were shown last time (usually 2 to 4).
-- A new window shows up within WIN_FULL_MS; when the quick look finds no active window (a new
-- dialog in front, or another program), the full look runs at once.
local function windowsInfo()
    local now = nowMs()
    if winCache and now - winCache.at < CFG.WIN_CACHE_MS then return winCache end
    local okW = pcall(function()
        local res, broken
        if winCache and winCache.fullAt and now - winCache.fullAt < CFG.WIN_FULL_MS then
            res, broken = scanWindows(winCache.shown, now)
            res.fullAt = winCache.fullAt
            if broken or not res.active then res = nil end
        end
        if not res then
            res = scanWindows(B.Gtk.Window.list_toplevels(), now)
            res.fullAt = now
        end
        winCache = res
    end)
    if not okW or not winCache then winCache = {at = now, active = true, frames = {}, shown = {}} end
    return winCache
end

-- Is something of Xournal++ in front of the page at the pointer? An open menu (menu bar,
-- right-click menu, a drop-down list), a dialog, or another floating window (Snapshot,
-- Page step). The pointer is then not on the page, even though its position lies inside
-- the page area. Two separate questions; one that cannot be answered counts as "no".
local function coveredPage()
    local okG, grab = pcall(function()
        local g = B.Gtk.grab_get_current()      -- an open menu or a modal dialog holds the grab
        if not g then return false end
        local t = g:get_toplevel()
        return t ~= nil and t ~= ui.top
    end)
    if okG and grab == true then return true end
    local okW, other = pcall(function()
        local w = ui.pointer:get_window_at_position()   -- the window of this program under the pointer
        if not w then return false end
        if not ui.topGdk then ui.topGdk = ui.top:get_window() end
        local t, main = w:get_effective_toplevel(), ui.topGdk
        return t ~= nil and main ~= nil and t ~= main
    end)
    if okW and other == true then return true end
    -- The title bar and border of a floating window (Snapshot, this panel, a dialog) are
    -- drawn by Windows, not GTK: there the question above answers "no window". So: is the
    -- pointer inside the OUTER rectangle (frame) of any other shown window of Xournal++?
    local info = windowsInfo()
    if #info.frames == 0 then return false end
    local okF, inFrame = pcall(function()
        local _, rx, ry = ui.pointer:get_position()      -- screen place of the pointer
        if type(rx) ~= "number" or type(ry) ~= "number" then return false end
        for _, r in ipairs(info.frames) do
            if rx >= r.x and ry >= r.y and rx < r.x + r.width and ry < r.y + r.height then return true end
        end
        return false
    end)
    return okF and inFrame == true
end

-- Is a window of Xournal++ (main window, settings panel, Snapshot, a dialog) the active
-- window of the desktop? False while another program is in front. Unknown counts as "yes".
local function appActive()
    return windowsInfo().active
end

-- Pen on the page canvas: x, y in view pixels, tip down, inside the page area.
local function readPen(sp)
    if not appActive() then return nil end
    local okQ, _, x, y, mask = pcall(function() return ui.gdkwin:get_device_position(ui.pointer) end)
    if not okQ or type(x) ~= "number" or type(y) ~= "number" then return nil end
    local down = false
    pcall(function() down = mask and mask.BUTTON1_MASK and true or false end)
    local inside = x >= 0 and y >= 0 and x < sp["width"] and y < sp["height"] and not overPanel()
                   and not coveredPage()
    -- A press that starts off the page (dragging the Tool dock or a window by its title bar,
    -- a scroll bar, the toolbar) stays "off the page" until the tip lifts, even when the
    -- pen then crosses the page.
    if down then
        if not st.penWasDown then st.downOff = not inside end
        if st.downOff then inside = false end
    else
        st.downOff = false
    end
    st.penWasDown = down
    return {x = x, y = y, down = down, inside = inside}
end

-- Critically damped spring towards a target (no overshoot). Returns new value, new speed.
local function damp(cur, target, vel, time, dt)
    local omega = 2 / math.max(time, 0.01)
    local x = omega * dt
    local decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
    local change = cur - target
    local temp = (vel + omega * change) * dt
    vel = (vel - omega * temp) * decay
    return target + (change + temp) * decay, vel
end

-- One spring step of the zoom (in log zoom) towards `target`. A spring alone creeps for a
-- long time over the last few percent, and Xournal++ redraws the page sharp only once the
-- zoom stands still. So over the last 5 % the speed never drops below a small floor: the
-- zoom arrives about 0.4 s sooner, and the sharp redraw comes that much earlier.
local function zoomSpring(target, dts)
    local T = CFG.ZOOM_MS / 1000
    local cur = math.log(app.getZoom())
    local lz
    lz, st.zv = damp(cur, target, st.zv or 0, T, dts)
    local rem = target - cur
    local floor = 0.06 / math.max(T, 0.01) * dts
    if math.abs(rem) < 0.05 and math.abs(lz - cur) < floor then
        if math.abs(rem) <= floor then
            lz = target
        else
            lz = cur + (rem > 0 and floor or -floor)
        end
        st.zv = (dts > 0) and (lz - cur) / dts or 0
    end
    return lz
end

-- ------------------------------------------------------------------ layout model
-- model = {n, cum[1..n] = heights of earlier pages (pt), w[i], h[i], total}
local function buildModel()
    local doc = app.getDocumentStructure()
    if type(doc) ~= "table" or type(doc["pages"]) ~= "table" then return nil end
    local pages = doc["pages"]
    local m = {n = #pages, cum = {}, w = {}, h = {}, total = 0}
    if m.n < 1 then return nil end
    for i = 1, m.n do
        local h, w = pages[i]["pageHeight"], pages[i]["pageWidth"]
        if type(h) ~= "number" or type(w) ~= "number" or h <= 0 or w <= 0 then return nil end
        m.cum[i], m.h[i], m.w[i] = m.total, h, w
        m.total = m.total + h
    end
    return m
end

-- Scroll range now -> layout {s = pixels per point, uh = scroll width, oy = empty space above the
-- first page}. nil when it cannot be read.
-- When the whole document fits in the view (zoom fit on a short document), the scroll area is the
-- view itself, not the pages, and Xournal++ centres the pages in it (0.15). s then comes from
-- zoom x DPI / 72 (the DPI is rounded, so it can be a few tenths of a percent off).
local function readLayout(m)
    local ok, uv, uh = pcall(function()
        return ui.scrolled:get_vadjustment():get_upper(), ui.scrolled:get_hadjustment():get_upper()
    end)
    if not ok or type(uv) ~= "number" or type(uh) ~= "number" then return nil end
    local s = (uv - 2 * CFG.PAD - (m.n - 1) * CFG.GAP) / m.total
    local oy = 0
    local okP, vp = pcall(function() return ui.scrolled:get_vadjustment():get_page_size() end)
    if okP and type(vp) == "number" and uv <= vp + 0.5 then
        local okE, est = pcall(function() return app.getZoom() * app.getDisplayDpi() / 72 end)
        if okE and type(est) == "number" and est > 0 then
            s = est
            oy = math.max(0, math.floor((uv - 2 * CFG.PAD - (m.n - 1) * CFG.GAP - m.total * s) / 2))
        end
    end
    if not (s > 0) then return nil end
    return {s = s, uh = uh, oy = oy}
end

local function pageTop(m, lay, i)   -- i is 1-based
    return (lay.oy or 0) + CFG.PAD + (i - 1) * CFG.GAP + m.cum[i] * lay.s
end

-- layout pixel (X, Y) -> document point {i, u, ux} (page, points down, points across)
local function toDoc(m, lay, X, Y)
    local lo, hi = 1, m.n
    while lo < hi do
        local mid = (lo + hi + 1) // 2
        if pageTop(m, lay, mid) <= Y then lo = mid else hi = mid - 1 end
    end
    local i = lo
    return {i = i, u = (Y - pageTop(m, lay, i)) / lay.s,
            ux = (X - (lay.uh - m.w[i] * lay.s) / 2) / lay.s}
end

local function fromDoc(m, lay, d)
    return (lay.uh - m.w[d.i] * lay.s) / 2 + d.ux * lay.s, pageTop(m, lay, d.i) + d.u * lay.s
end

-- Document point at the middle of the view.
local function centreDoc(sp)
    local m = st.model
    local lay = m and readLayout(m)
    if not lay then return nil end
    return toDoc(m, lay, sp["x"] + sp["width"] / 2, sp["y"] + sp["height"] / 2)
end

-- ------------------------------------------------------------------ camera (scroll position)
-- Our own scroll position with fractions (Xournal++ may round what it reports), valid
-- while only the plugin moves the view. Second result: the user scrolled by hand.
local function camPos(sp)
    local ls = st.lastSet
    local byHand = ls ~= nil and (math.abs(sp["x"] - ls.x) > 1 or math.abs(sp["y"] - ls.y) > 1)
    if not st.cam or not ls or byHand then
        st.cam = {x = sp["x"], y = sp["y"]}
        st.lastSet = {x = sp["x"], y = sp["y"]}
    end
    return st.cam, byHand
end

-- Every scroll goes to a WHOLE pixel. At a decimal scroll position GTK draws the page
-- between two pixel rows, which shows as a slight blur of the PDF. The camera itself
-- (st.cam, the springs) keeps its decimal position, so slow movement is not lost.
local function scrollTo(x, y)
    app.scrollToPos(math.floor(x + 0.5), math.floor(y + 0.5), false)
end

-- Scrolls to (x, y). Returns: stopped at the page edge in x, in y.
local function camSet(x, y)
    scrollTo(x, y)
    local a = scrollPos()
    local cx, cy = math.abs(a["x"] - x) > 1.5, math.abs(a["y"] - y) > 1.5
    st.cam = {x = cx and a["x"] or x, y = cy and a["y"] or y}
    st.lastSet = {x = a["x"], y = a["y"]}
    return cx, cy
end

-- ------------------------------------------------------------------ zoom steps
-- One zoom step to z. The document point st.d (taken once, when the zoom starts) is put
-- back under the view point st.q after every step. Taking it once matters: while the page
-- is narrower than the view it cannot be scrolled sideways, and a point taken again at
-- every step would drift. A scroll by hand during the movement takes a new point.
local function zoomStep(z)
    local sp, zc = scrollPos(), app.getZoom()
    local qx, qy = st.q.x, st.q.y
    local m = st.model
    local lay = m and readLayout(m)
    if lay and st.ratio and math.abs((lay.s / zc) / st.ratio - 1) > 0.01 then
        log("layout model does not fit (ratio changed); simple formula from here")
        st.model, m, lay = nil, nil, nil
    end
    if lay then
        local ls = st.lastSet
        if not st.d or (ls and (math.abs(sp["x"] - ls.x) > 1 or math.abs(sp["y"] - ls.y) > 1)) then
            st.d = toDoc(m, lay, sp["x"] + qx, sp["y"] + qy)
        end
        app.setZoom(z)
        local lay2 = readLayout(m)
        if lay2 then
            local X, Y = fromDoc(m, lay2, st.d)
            scrollTo(X - qx, Y - qy)
        end
    else
        local f = z / zc
        app.setZoom(z)
        scrollTo((sp["x"] + qx) * f - qx, (sp["y"] + qy) * f - qy)
    end
    local after = scrollPos()
    st.lastSet = {x = after["x"], y = after["y"]}
    st.cam = nil
    st.expectZoom = app.getZoom()
end

-- Self-check of the layout maths: the scale read from the scroll area must agree with
-- zoom x screen DPI / 72 (the DPI is rounded, so only roughly). A big difference means
-- Xournal++ changed its page layout (PAD / GAP): the zoom may then not hold the pen spot.
local function checkScale(s, z)
    local ok, est = pcall(function() return z * app.getDisplayDpi() / 72 end)
    if not ok or type(est) ~= "number" or not (est > 0) then return end
    local bad = math.abs(s / est - 1) > 0.05
    if bad and not st.scaleBad then
        log(string.format("WARNING layout check: scale %.4f from the scroll area, %.4f from zoom and DPI. "
            .. "Xournal++ may have changed its page layout (PAD / GAP in settings.txt).", s, est))
    end
    st.scaleBad = bad
end

local function startIn(pen, why)
    local z, sp = app.getZoom(), scrollPos()
    st.model = buildModel()
    local lay = st.model and readLayout(st.model)
    if lay then checkScale(lay.s, z) end
    st.ratio = lay and (lay.s / z) or nil
    if not lay then
        st.model = nil
        log("no layout model; simple formula")
    end
    st.saved = {zoom = z, x = sp["x"], y = sp["y"], s = lay and lay.s or nil, uh = lay and lay.uh or nil}
    st.zTo, st.zv = z * CFG.FACTOR, 0
    st.expectZoom = z
    -- one fixed anchor for the whole movement (pen jitter must not drag the page)
    if pen and pen.inside then st.q = {x = pen.x, y = pen.y} else st.q = {x = sp["width"] / 2, y = sp["height"] / 2} end
    st.d, st.lastSet, st.cam = nil, nil, nil
    st.inDoc, st.inScroll, st.fT, st.ink = nil, nil, nil, nil
    st.pvx, st.pvy = 0, 0
    local tool = nil
    pcall(function() tool = app.getActionState("select-tool") end)
    setMode("IN", tostring(why) .. ", tool " .. tostring(tool))
end

-- Where the view must end after zooming out. The saved view, as long as the middle of
-- the zoomed view is still inside it. After a move further away (another page, by
-- scrolling or preserve-view): the same place there.
local function outTarget(sp)
    local sv = st.saved
    if not st.inScroll then return sv.x, sv.y end
    local m = st.model
    local b = centreDoc(sp)
    if b and st.inDoc and sv.s and sv.uh then
        local a = st.inDoc
        local function y0(d) return CFG.PAD + (d.i - 1) * CFG.GAP + (m.cum[d.i] + d.u) * sv.s end
        local bx, by = (sv.uh - m.w[b.i] * sv.s) / 2 + b.ux * sv.s, y0(b)
        if bx >= sv.x - 1 and bx <= sv.x + sp["width"] + 1 and by >= sv.y - 1 and by <= sv.y + sp["height"] + 1 then
            return sv.x, sv.y
        end
        return sv.x + (b.ux - a.ux) * sv.s, sv.y + y0(b) - y0(a)
    end
    local ins, zc = st.inScroll, app.getZoom()
    -- no layout model: the same rule with plain scaling
    local hw, hh = sp["width"] / 2, sp["height"] / 2
    local bx, by = (sp["x"] + hw) / zc * sv.zoom, (sp["y"] + hh) / zc * sv.zoom
    if bx >= sv.x - 1 and bx <= sv.x + sp["width"] + 1 and by >= sv.y - 1 and by <= sv.y + sp["height"] + 1 then
        return sv.x, sv.y
    end
    return sv.x + bx - (ins.x + hw) / ins.zoom * sv.zoom, sv.y + by - (ins.y + hh) / ins.zoom * sv.zoom
end

local function startOut(why)
    local sp = scrollPos()
    st.outX, st.outY = outTarget(sp)
    st.zFrom, st.fromX, st.fromY = app.getZoom(), sp["x"], sp["y"]
    if st.mode ~= "IN" then st.zv = 0 end
    st.fT, st.ink, st.pvx, st.pvy = nil, nil, 0, 0
    setMode("OUT", why)
end

local function toIdle(pen, why)
    st.saved, st.inScroll, st.inDoc, st.expectZoom = nil, nil, nil, nil
    st.fT, st.ink, st.cam, st.lastSet = nil, nil, nil, nil
    st.pvx, st.pvy, st.zv = 0, 0, 0
    st.armed, st.disarm = false, pen and {x = pen.x, y = pen.y} or nil
    st.writeAcc, st.anchor, st.learn = 0, nil, nil
    setMode("IDLE", why)
end

local function finishOut(pen)
    app.setZoom(st.saved.zoom)
    scrollTo(st.outX, st.outY)
    toIdle(pen, "zoomed out")
end

local function dist(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- The zoom level was changed in the panel while zoomed in: go to it smoothly.
local function retarget()
    if not st.saved or (st.mode ~= "ZOOMED" and st.mode ~= "IN") then return end
    st.zTo = st.saved.zoom * CFG.FACTOR
    if st.mode == "ZOOMED" then
        local sp = scrollPos()
        st.q = {x = sp["width"] / 2, y = sp["height"] / 2}
        st.d, st.lastSet, st.cam, st.fT, st.ink = nil, nil, nil, nil, nil
        st.zv = 0
        setMode("IN", "zoom level changed")
    end
end

-- ------------------------------------------------------------------ edge slide and follow
local function inEdge(sp, pen)
    local ex, ey = sp["width"] * CFG.EDGE, sp["height"] * CFG.EDGE
    return pen.x < ex or pen.x > sp["width"] - ex or pen.y < ey or pen.y > sp["height"] - ey
end

-- Pen held near an edge (tip up): slide the view. The speed changes softly.
-- Not with the hand or a selection tool (st.toolOk): there the pen moves the page or picks
-- things, and a slide under it is in the way.
-- Returns true while the pen asks for a slide.
local function edgeSlide(sp, pen, now, dts, alive)
    if pen and pen.down then st.pvx, st.pvy = 0, 0 return false end
    local tx, ty = 0, 0
    if CFG.PAN and pen and pen.inside and not st.fT and st.toolOk ~= false
       and now - (st.lastDown or -math.huge) >= CFG.PAN_DELAY_MS and alive <= CFG.PAN_ALIVE_MS then
        local ex, ey = sp["width"] * CFG.EDGE, sp["height"] * CFG.EDGE
        if pen.x < ex then tx = -(ex - pen.x) / ex elseif pen.x > sp["width"] - ex then tx = (pen.x - (sp["width"] - ex)) / ex end
        if pen.y < ey then ty = -(ey - pen.y) / ey elseif pen.y > sp["height"] - ey then ty = (pen.y - (sp["height"] - ey)) / ey end
        tx, ty = tx * CFG.PAN_SPEED, ty * CFG.PAN_SPEED
    end
    local k = 1 - math.exp(-dts / 0.12)
    st.pvx = (st.pvx or 0) + (tx - (st.pvx or 0)) * k
    st.pvy = (st.pvy or 0) + (ty - (st.pvy or 0)) * k
    if tx == 0 and ty == 0 and math.abs(st.pvx) < 5 and math.abs(st.pvy) < 5 then
        st.pvx, st.pvy = 0, 0
        return false
    end
    local cam = camPos(sp)
    local cx, cy = camSet(cam.x + st.pvx * dts, cam.y + st.pvy * dts)
    if cx then st.pvx = 0 end
    if cy then st.pvy = 0 end
    return tx ~= 0 or ty ~= 0
end

-- The last writing left the still zone: set where the view must glide to.
local function followStart(sp, now)
    local ink = st.ink
    if not (CFG.FOLLOW and ink) or st.fT then return end
    if now - (st.lastDown or -math.huge) < CFG.FOLLOW_DELAY_MS then return end
    st.ink = nil
    local hw, hh = sp["width"] * CFG.STILL / 200, sp["height"] * CFG.STILL / 200
    local cx, cy = sp["width"] / 2, sp["height"] / 2
    local dx, dy = 0, 0
    if ink.x > cx + hw then dx = ink.x - (cx + hw) elseif ink.x < cx - hw then dx = ink.x - (cx - hw) end
    if ink.y > cy + hh then dy = ink.y - (cy + hh) elseif ink.y < cy - hh then dy = ink.y - (cy - hh) end
    if math.abs(dx) < 2 and math.abs(dy) < 2 then return end
    local cam = camPos(sp)
    st.fT = {x = cam.x + dx, y = cam.y + dy}
    st.fvx, st.fvy = 0, 0
end

local function followStep(sp, dts)
    local cam = camPos(sp)
    local t = st.fT
    local nx, ny
    nx, st.fvx = damp(cam.x, t.x, st.fvx, CFG.FOLLOW_MS / 1000, dts)
    ny, st.fvy = damp(cam.y, t.y, st.fvy, CFG.FOLLOW_MS / 1000, dts)
    local done = math.abs(nx - t.x) < 0.5 and math.abs(ny - t.y) < 0.5
    if done then nx, ny = t.x, t.y end
    local cx, cy = camSet(nx, ny)
    if cx then t.x, st.fvx = st.cam.x, 0 end      -- page edge reached
    if cy then t.y, st.fvy = st.cam.y, 0 end
    if done then st.fT = nil end
end

-- ------------------------------------------------------------------ the tick
-- Does the current tool write or point (pen, highlighter, laser pointer, shapes, text ...)?
-- The selection tools and the hand do not: with them the pen selects or moves things, so it
-- must not zoom. The eraser does not either, unless ERASER_ZOOMS (0.11: rubbing out
-- should not zoom). Unknown tool or unknown answer: yes.
local NOT_WRITING = {"Tool_selectRect", "Tool_selectRegion", "Tool_selectMultiLayerRect",
                     "Tool_selectMultiLayerRegion", "Tool_selectObject", "Tool_selectPdfTextLinear",
                     "Tool_selectPdfTextRect", "Tool_hand", "Tool_eraser"}
local NOT_WRITING_NO = {6, 7, 8, 9, 10, 21, 22, 13, 2}    -- the same tools, when app.C is missing
local function writingTool()
    if not app.getActionState then return true end
    local ok, t = pcall(app.getActionState, "select-tool")
    if not ok or type(t) ~= "number" then return true end
    local c = type(app.C) == "table" and app.C or nil
    for k, name in ipairs(NOT_WRITING) do
        if name == "Tool_eraser" and CFG.ERASER_ZOOMS then break end
        local v
        if c then v = c[name] else v = NOT_WRITING_NO[k] end
        if v ~= nil and t == v then return false end
    end
    return true
end

-- Is something selected on the page (a picture or strokes that the pen is about to drag)?
local function selectionExists()
    for _, name in ipairs({"getStrokes", "getTexts", "getImages"}) do
        local fn = app[name]
        if fn then
            local ok, t = pcall(fn, "selection")
            if ok and type(t) == "table" and #t > 0 then return true end
        end
    end
    return false
end

-- Does the pointer count as writing now? Asked once per pen-down and once per hover spot
-- (reading a selected picture costs time, so never at every tick).
local function countsAsWriting()
    return writingTool() and not selectionExists()
end

local function tick()
    local now = nowMs()
    local dt = math.min(100, math.max(0, now - (st.lastTick or now)))
    st.lastTick = now
    local dts = dt / 1000
    local sp = scrollPos()
    local pen = readPen(sp)

    if pen then
        if not st.lastPos or pen.x ~= st.lastPos.x or pen.y ~= st.lastPos.y then st.lastChange = now end
        st.lastPos = {x = pen.x, y = pen.y}
    end
    local down = pen and pen.down and pen.inside or false
    -- a press with a non-writing tool, or one that drags a selection, is not writing
    if down and not st.wasDown then st.skipDown = not countsAsWriting() end
    st.wasDown = down
    if not down then st.skipDown = false end
    if st.skipDown then down = false end
    if down then st.lastDown = now end
    local alive = st.lastChange and (now - st.lastChange) or math.huge

    -- the user changed the zoom by hand while we hold a zoom
    if st.mode ~= "IDLE" and st.expectZoom then
        local z = app.getZoom()
        if math.abs(z - st.expectZoom) > 1e-4 * z then
            local f = st.saved and (z / st.saved.zoom) or 0
            if st.mode == "ZOOMED" and CFG.LEARN and f > 1.05 then
                -- keep the user's zoom. It becomes the new zoom level only once the hand
                -- zoom has come to rest (below): the steps on the way are not levels, and
                -- zooming most of the way out by hand means "out", not "a tiny level".
                st.learn = {f = f, t = now}
                st.zTo, st.expectZoom, st.idleSince = z, z, now
                st.fT, st.ink, st.cam, st.lastSet = nil, nil, nil, nil
                if not st.inDoc then st.inScroll = {x = sp["x"], y = sp["y"], zoom = z} end
            else
                toIdle(pen, "zoom changed by hand")
                return
            end
        end
    end

    if st.learn and st.mode ~= "ZOOMED" then st.learn = nil end
    if st.learn and now - st.learn.t >= CFG.LEARN_SETTLE_MS then
        local f = st.learn.f
        st.learn = nil
        if f >= CFG.LEARN_MIN then
            CFG.FACTOR = clamp(math.floor(f * 100 + 0.5) / 100, 1.1, 4.0)
            markDirty()
            log(string.format("zoom level learned: %.2f", CFG.FACTOR))
        else
            log(string.format("hand zoom ended at x %.2f: taken as zoom out, level stays %.2f", f, CFG.FACTOR))
            toIdle(pen, "zoomed out by hand")
            return
        end
    end

    -- which tool is in use: asked 4 times a second (not at every tick)
    if not st.toolAt or now - st.toolAt >= 250 then st.toolAt, st.toolOk = now, writingTool() end

    if st.mode == "IDLE" then
        if down then
            st.writeAcc = (st.writeAcc or 0) + dt
            st.anchor = nil
        elseif now - (st.lastDown or -math.huge) > CFG.WRITE_GAP_MS then
            st.writeAcc = 0
        end
        if alive > CFG.STALE_MS then st.anchor = nil end
        local sliding = false
        if CFG.PAN and CFG.PAN_IDLE and not paused then
            sliding = edgeSlide(sp, pen, now, dts, alive) or (pen ~= nil and pen.inside and inEdge(sp, pen))
        end
        st.idleFast = sliding
        if pen and pen.inside and not pen.down and not sliding then
            if not st.armed and (not st.disarm or dist(pen, st.disarm) > CFG.RADIUS) then st.armed = true end
            if not st.anchor or dist(pen, st.anchor) > CFG.RADIUS then
                st.anchor = {x = pen.x, y = pen.y, t = now}
            end
        elseif not down then
            st.anchor = nil
        end
        if paused then
            -- no zoom in; a fresh start for the hover wait once the pause ends
            st.writeAcc, st.anchor = 0, nil
        elseif CFG.WRITE_TRIGGER and (st.writeAcc or 0) >= CFG.WRITE_MS and down then
            startIn(pen, "writing")
        elseif CFG.HOVER_TRIGGER and st.armed and st.anchor and now - st.anchor.t >= CFG.DWELL_MS
               and alive <= CFG.ALIVE_MS then
            if st.anchor.writes == nil then st.anchor.writes = countsAsWriting() end
            if st.anchor.writes then startIn(pen, "hover") end
        end

    elseif st.mode == "IN" then
        if not down and not (pen and pen.down) then
            local target = math.log(st.zTo)
            local lz
            lz = zoomSpring(target, dts)
            if math.abs(lz - target) < 0.002 then
                zoomStep(st.zTo)
                local after = scrollPos()
                if not st.inScroll then
                    st.inScroll = {x = after["x"], y = after["y"], zoom = app.getZoom()}
                    st.inDoc = centreDoc(after)
                end
                st.idleSince, st.rest = now, pen and {x = pen.x, y = pen.y} or nil
                st.zv = 0
                setMode("ZOOMED")
            else
                zoomStep(math.exp(lz))
            end
        end

    elseif st.mode == "ZOOMED" then
        local _, byHand = camPos(sp)
        if byHand then st.fT, st.ink = nil, nil end
        if paused then
            -- 0.17: paused, nothing moves by itself (no follow, no edge slide, no zoom out)
            st.fT, st.ink, st.pvx, st.pvy = nil, nil, 0, 0
        elseif pen and pen.down then
            -- tip down: nothing moves. Any press on the page counts as busy, also one that is not
            -- writing (a Select Rectangle drag for a snapshot), so no zoom out waits for its release.
            if pen.inside then st.idleSince = now end
            if down then st.ink = {x = pen.x, y = pen.y} end
            st.fT, st.pvx, st.pvy = nil, 0, 0
        else
            if pen and (not st.rest or dist(pen, st.rest) > CFG.MOVE_PX) then
                st.rest, st.idleSince = {x = pen.x, y = pen.y}, now
            end
            followStart(sp, now)
            if st.fT then
                followStep(sp, dts)
                st.idleSince = now
            elseif edgeSlide(sp, pen, now, dts, alive) then
                st.idleSince = now
            end
        end
        if paused then
            st.idleSince = now      -- no zoom out; the wait starts again once the pause ends
        elseif now - (st.idleSince or now) >= CFG.IDLE_MS then
            startOut("idle")
        end

    elseif st.mode == "OUT" then
        if down then
            -- writing again: go back in from here
            st.zTo = st.saved.zoom * CFG.FACTOR
            st.q = {x = pen.x, y = pen.y}
            st.d, st.lastSet, st.cam = nil, nil, nil
            setMode("IN", "writing during zoom out")
        elseif not (pen and pen.down) then
            local z0 = st.saved.zoom
            local target = math.log(z0)
            local lz
            lz = zoomSpring(target, dts)
            if math.abs(lz - target) < 0.002 then
                finishOut(pen)
            else
                local z = math.exp(lz)
                local f = (math.abs(z0 - st.zFrom) > 1e-9) and clamp((z - st.zFrom) / (z0 - st.zFrom), 0, 1) or 1
                app.setZoom(z)
                scrollTo(st.fromX + (st.outX - st.fromX) * f, st.fromY + (st.outY - st.fromY) * f)
                st.expectZoom = app.getZoom()
            end
        end
    end
end

-- ------------------------------------------------------------------ on / off
local function hasApi()
    return app.getZoom and app.setZoom and app.scrollToPos and app.getDocumentStructure and true or false
end

-- A small note that shows for a moment and goes away by itself (no button to click).
local function toast(text)
    if panel or not ui then return end      -- the panel shows the state already
    pcall(function()
        local G = B.Gtk
        local win = G.Window {type = G.WindowType.POPUP, accept_focus = false, focus_on_map = false}
        win:set_transient_for(ui.top)
        win:add(G.Label {label = text, margin = 12})
        local r = {ui.gdkwin:get_origin()}
        local ox, oy = r[#r - 1], r[#r]
        if type(ox) == "number" and type(oy) == "number" then win:move(ox + 24, oy + 24) end
        win:show_all()
        B.GLib.timeout_add(B.GLib.PRIORITY_DEFAULT, 1300, function()
            pcall(function() win:destroy() end)
            return false
        end)
    end)
end

local turnOff

local function ensureTimer()
    if timerLive then return end
    timerGen = timerGen + 1
    timerLive = true
    local gen, n = timerGen, 0
    B.GLib.timeout_add(B.GLib.PRIORITY_DEFAULT, CFG.TICK_MS, function()
        if gen ~= timerGen then return false end
        n = n + 1
        -- not zoomed, no edge slide: every IDLE_EVERY-th tick is enough (hover needs 400 ms,
        -- writing is noticed 16 ms later): half the cost while nothing happens (0.12)
        local skip = st.mode == "IDLE" and not st.idleFast and CFG.IDLE_EVERY > 1 and n % CFG.IDLE_EVERY ~= 0
        if st.mode ~= "OFF" and not skip then
            local t0 = nowMs()
            local okT, e = pcall(tick)
            if not okT then
                log("tick error: " .. tostring(e))
                turnOff("error")
            end
            -- cost check: one log line a minute, average and longest tick (time taken from Xournal++)
            local c = costLog or {n = 0, sum = 0, max = 0, since = t0}
            local d = nowMs() - t0
            c.n, c.sum, c.max = c.n + 1, c.sum + d, math.max(c.max, d)
            if t0 - c.since >= 60000 then
                log(string.format("tick cost: average %.2f ms, longest %.1f ms (%d ticks)", c.sum / c.n, c.max, c.n))
                c = {n = 0, sum = 0, max = 0, since = t0}
            end
            costLog = c
        end
        if panel and n % 6 == 0 then
            local okP, e = pcall(panel.poll)
            if not okP then
                log("panel error: " .. tostring(e))
                pcall(function() panel.win:destroy() end)
                panel = nil
            end
        end
        local stop = st.mode == "OFF" and not panel
        if dirtyAt and (stop or nowMs() - dirtyAt > 800) then
            dirtyAt = nil
            pcall(saveSettings)
        end
        if stop then
            timerLive = false
            return false
        end
        return true
    end)
end

turnOff = function(why)
    if st.mode == "OFF" then return end
    if st.saved then
        pcall(function()
            if st.mode ~= "OUT" then st.outX, st.outY = outTarget(scrollPos()) end
            app.setZoom(st.saved.zoom)
            scrollTo(st.outX, st.outY)
        end)
    end
    st = {mode = st.mode}
    setMode("OFF", why)
end

local loggedNoSp = false
local function turnOn(quiet)
    if st.mode ~= "OFF" then return true end
    local ok, err = hasApi(), "this Xournal++ build lacks getZoom / setZoom / scrollToPos / getDocumentStructure."
    if ok then ok, err = attach() end
    if not ok then
        if quiet then log("cannot run: " .. tostring(err)) else notify("Auto zoom cannot run: " .. tostring(err)) end
        return false
    end
    if not app.getScrollPos and not loggedNoSp then
        loggedNoSp = true
        log("no app.getScrollPos in this Xournal++ (stable): the scroll bars give the same numbers")
    end
    st = {mode = "OFF", armed = true, writeAcc = 0}
    setMode("IDLE", "switched on")
    ensureTimer()
    return true
end

-- ------------------------------------------------------------------ settings panel
local STATE_TEXT = {OFF = "off", IDLE = "on: waiting for the pen", IN = "zooming in",
                    ZOOMED = "zoomed in", OUT = "zooming out"}

-- The work area (screen minus task bar) of the monitor at x, y (or the main monitor). nil if GTK cannot tell.
local function workArea(x, y)
    local ok, r = pcall(function()
        local d = B.Gdk.Display.get_default()
        local m = (x and y and y >= 0) and d:get_monitor_at_point(x, y) or d:get_primary_monitor() or d:get_monitor(0)
        return m:get_workarea()
    end)
    if ok and r and r.width and r.width > 0 then return r end
    if not ok then log("panel: work area unknown: " .. tostring(r)) end
end

-- A saved place from a bigger or second screen can be off this screen: pull the panel back inside.
local function keepOnScreen(win)
    local x, y = win:get_position()
    local w, h = win:get_size()
    if type(x) ~= "number" or type(w) ~= "number" then return end
    local wa = workArea(x + w // 2, y + 10) or workArea()
    if not wa then return end
    local nx = math.max(wa.x, math.min(x, wa.x + wa.width - w))
    local ny = math.max(wa.y, math.min(y, wa.y + wa.height - h))
    if nx ~= x or ny ~= y then
        win:move(nx, ny)
        log(string.format("panel moved back on screen: %d,%d -> %d,%d", x, y, nx, ny))
    end
end

local function openPanel()
    if panel then
        pcall(function() panel.win:present() end)
        return true
    end
    if not ui then
        local ok, err = attach()
        if not ok then notify("Auto zoom panel cannot open: " .. tostring(err)) return false end
    end
    local G = B.Gtk
    local win = G.Window {title = "Auto zoom", resizable = true, accept_focus = false, focus_on_map = false,
                          skip_taskbar_hint = true, type_hint = B.Gdk.WindowTypeHint.UTILITY}
    win:set_transient_for(ui.top)
    local grid = G.Grid {row_spacing = 6, column_spacing = 12, margin = 12}
    -- scroll bar only when the screen is too short for the panel
    local sw = G.ScrolledWindow {hscrollbar_policy = G.PolicyType.NEVER, vscrollbar_policy = G.PolicyType.AUTOMATIC,
                                 propagate_natural_width = true, propagate_natural_height = true,
                                 overlay_scrolling = false}   -- a real bar, easy to grab with the pen
    sw:add(grid)
    win:add(sw)
    local wa = workArea(CFG.PANEL_X >= 0 and CFG.PANEL_X or nil, CFG.PANEL_Y)
    if wa then sw.max_content_height = math.max(200, wa.height - 80) end

    local p = {win = win, w = {}, shown = {}}
    local row = 0
    p.onBtn = G.ToggleButton.new_with_label("Auto zoom: OFF")
    p.state = G.Label {label = "", xalign = 0}
    p.onBtn:set_tooltip_text("Switches auto zoom on or off (same as Ctrl+Alt+F5).\nThe text beside it shows what the plugin is doing now.\nHold the pen over any setting to read what it does.")
    grid:attach(p.onBtn, 0, row, 1, 1)
    grid:attach(p.state, 1, row, 2, 1)
    row = row + 1
    p.pauseBtn = G.ToggleButton.new_with_label("Pause auto zoom")
    p.pauseBtn:set_name("az_pause")
    p.pauseBtn:set_tooltip_text("Pressed: everything stops and the view stays as it is.\n"
        .. "No zoom in, no zoom out, no edge slide, no follow glide.\n"
        .. "Ctrl+Alt+F6 still zooms in or out by hand. Press again and auto zoom works by itself again.\n"
        .. "If auto zoom is off, this switches it on, paused. Switching it off ends the pause.")
    grid:attach(p.pauseBtn, 0, row, 1, 1)
    row = row + 1

    -- The info text of a setting shows on its caption and on the small (i) mark beside it,
    -- not on the slider (a text box over the slider is in the way while dragging).
    local function infoMark(c)
        local m = G.Label {label = "\u{24D8}"}
        m:set_name("az_tip_" .. c.key)
        m:set_tooltip_text(c.tip)
        return m
    end

    local firstGroup = true
    for _, c in ipairs(CONTROLS) do
        if c.group then                 -- group heading, a thin line above it (not above the first)
            if not firstGroup then
                local line = G.Separator {orientation = G.Orientation.HORIZONTAL, margin_top = 6}
                grid:attach(line, 0, row, 3, 1)
                row = row + 1
            end
            local h = G.Label {xalign = 0}
            h:set_markup("<b>" .. c.group .. "</b>")
            h:set_name("az_group_" .. c.group)
            grid:attach(h, 0, row, 3, 1)
            row = row + 1
            firstGroup = false
        end
        if c.min then
            local left
            if c.check then
                left = G.CheckButton.new_with_label(c.label)
                p.w[c.check] = left
            else
                left = G.Label {label = c.label, xalign = 0, margin_start = 24}   -- text in line with tick-box texts
            end
            local sc = G.Scale.new_with_range(G.Orientation.HORIZONTAL, c.min, c.max, c.step)
            sc:set_digits(c.digits)
            sc:set_value_pos(G.PositionType.RIGHT)
            sc:set_size_request(210, -1)
            sc.hexpand = true           -- a wider panel gives wider sliders
            sc:set_name("az_" .. c.key)
            p.w[c.key] = sc
            left:set_tooltip_text(c.tip)
            grid:attach(left, 0, row, 1, 1)
            grid:attach(infoMark(c), 1, row, 1, 1)
            grid:attach(sc, 2, row, 1, 1)
        else
            local cb = G.CheckButton.new_with_label(c.label)
            cb:set_name("az_" .. c.key)
            p.w[c.key] = cb
            cb:set_tooltip_text(c.tip)
            local box = G.Box {orientation = G.Orientation.HORIZONTAL, spacing = 10}
            box:add(cb)
            box:add(infoMark(c))
            grid:attach(box, 0, row, 3, 1)
        end
        row = row + 1
    end
    p.defaults = G.ToggleButton.new_with_label("Back to the default settings")
    p.defaults:set_name("az_defaults")
    p.defaults:set_tooltip_text("Puts every setting back to its first value. The place and size of the panel stay.")
    p.defaults.margin_top = 6
    grid:attach(p.defaults, 0, row, 3, 1)

    local function mult(key)
        for _, c in ipairs(CONTROLS) do if c.key == key then return c.mult end end
    end
    -- widget <- CFG, for every control whose CFG value is not what the widget shows
    local function push(all)
        for key, w in pairs(p.w) do
            local v = CFG[key]
            if type(v) == "boolean" then
                if all or p.shown[key] ~= v then
                    w:set_active(v)
                    p.shown[key] = v
                end
            else
                local want = v * mult(key)
                if all or math.abs((p.shown[key] or 0) - want) > 1e-6 then
                    w:set_value(want)
                    p.shown[key] = w:get_value()
                    CFG[key] = p.shown[key] / mult(key)
                end
            end
        end
    end
    push(true)
    p.shownOn = st.mode ~= "OFF"
    p.onBtn:set_active(p.shownOn)
    p.shownPaused = paused
    p.pauseBtn:set_active(paused)

    if CFG.PANEL_W > 0 and CFG.PANEL_H > 0 then win:set_default_size(CFG.PANEL_W, CFG.PANEL_H) end
    if CFG.PANEL_X >= 0 and CFG.PANEL_Y >= 0 then win:move(CFG.PANEL_X, CFG.PANEL_Y) end
    win:show_all()
    keepOnScreen(win)

    function p.poll()
        local vis = win:get_visible()
        if not vis then         -- closed with its X
            panel = nil
            return
        end
        local x, y = win:get_position()
        if type(x) == "number" and type(y) == "number" and (x ~= CFG.PANEL_X or y ~= CFG.PANEL_Y) then
            CFG.PANEL_X, CFG.PANEL_Y = x, y
            markDirty()
        end
        local pw, ph = win:get_size()
        if type(pw) == "number" and type(ph) == "number" and (pw ~= CFG.PANEL_W or ph ~= CFG.PANEL_H) then
            CFG.PANEL_W, CFG.PANEL_H = pw, ph
            markDirty()
        end
        -- "defaults" button (a toggle that springs back)
        if p.defaults:get_active() then
            for k, v in pairs(DEFAULTS) do
                if not k:find("^PANEL_[XYWH]$") and type(v) ~= "string" then CFG[k] = v end
            end
            p.defaults:set_active(false)
            push(true)
            retarget()
            markDirty()
            log("settings back to defaults")
        end
        -- the user moved a control: widget -> CFG
        for key, w in pairs(p.w) do
            if type(CFG[key]) == "boolean" then
                local a = w:get_active()
                if a ~= p.shown[key] then
                    p.shown[key], CFG[key] = a, a
                    markDirty()
                end
            else
                local a = w:get_value()
                if math.abs(a - p.shown[key]) > 1e-6 then
                    p.shown[key], CFG[key] = a, a / mult(key)
                    markDirty()
                    if key == "FACTOR" then retarget() end
                end
            end
        end
        -- CFG changed elsewhere (zoom level learned): CFG -> widget
        push(false)
        -- on / off button
        local a = p.onBtn:get_active()
        if a ~= p.shownOn then
            if a then turnOn(false) else turnOff("switched off") end
        end
        local on = st.mode ~= "OFF"
        if p.onBtn:get_active() ~= on then p.onBtn:set_active(on) end
        if p.shownOn ~= on or not p.labelSet then
            p.onBtn:set_label(on and "Auto zoom: ON" or "Auto zoom: OFF")
            p.labelSet = true
        end
        p.shownOn = on
        -- pause button (after on / off: switching off ends the pause)
        local pa = p.pauseBtn:get_active()
        if pa ~= p.shownPaused and pa ~= paused then autozoomPause() end
        if p.pauseBtn:get_active() ~= paused then p.pauseBtn:set_active(paused) end
        if p.shownPaused ~= paused or not p.pauseLabelSet then
            p.pauseBtn:set_label(paused and "Auto zoom paused" or "Pause auto zoom")
            p.pauseLabelSet = true
        end
        p.shownPaused = paused
        local text = STATE_TEXT[st.mode] or st.mode
        if st.mode == "ZOOMED" and st.saved then
            text = string.format("zoomed in  x %.2f", app.getZoom() / st.saved.zoom)
        end
        if paused and st.mode ~= "OFF" then text = text .. ", paused" end
        if st.scaleBad then text = text .. "  (layout check failed, see the log)" end
        if text ~= p.stateText then
            p.state:set_label(text)
            p.stateText = text
        end
    end

    panel = p
    ensureTimer()
    return true
end

-- ------------------------------------------------------------------ menu callbacks
function autozoomToggle()
    if st.mode == "OFF" then
        if turnOn(false) then toast("Auto zoom ON") end
    else
        turnOff("switched off")
        toast("Auto zoom OFF")
    end
end

function autozoomNow()
    if st.mode == "OFF" then
        notify("Auto zoom is OFF. Switch it on first (" .. tostring(CFG.KEY_TOGGLE) .. ").")
        return
    end
    local ok, e = pcall(function()
        if st.mode == "IDLE" then
            startIn(readPen(scrollPos()), "key")
        elseif st.mode == "IN" or st.mode == "ZOOMED" then
            startOut("key")
        end
    end)
    if not ok then log("key error: " .. tostring(e)) end
end

-- 0.16: pause (0.17: stops everything, also the edge slide and follow). While OFF: switch on, paused.
function autozoomPause()
    if st.mode == "OFF" and not turnOn(false) then return end
    paused = not paused
    publishPaused()
    log(paused and "zoom paused" or "zoom pause ended")
    toast(paused and "Auto zoom: paused (no zoom, no edge slide)" or "Auto zoom: works by itself again")
end

function autozoomPanel()
    local ok, e = pcall(openPanel)
    if not ok then
        log("panel error: " .. tostring(e))
        pcall(function() if panel then panel.win:destroy() end end)
        panel = nil
        notify("Auto zoom panel cannot open.\n" .. tostring(e))
    end
end

local function accel(name)
    local v = CFG[name]
    if type(v) ~= "string" or v:lower() == "none" then return nil end
    return v
end

function initUi()
    -- settings first: the shortcut keys come from the file. A file that lacks a setting
    -- (older version) is rewritten once, so every setting can be seen and changed there.
    local okL, seen = pcall(loadSettings)
    local all = 0
    for _ in pairs(DEFAULTS) do all = all + 1 end
    if okL and (seen or 0) < all then pcall(saveSettings) end
    app.registerUi({["menu"] = "Auto zoom: ON / OFF", ["callback"] = "autozoomToggle",
                    ["accelerator"] = accel("KEY_TOGGLE")})
    app.registerUi({["menu"] = "Auto zoom: zoom in at the pen / zoom out now", ["callback"] = "autozoomNow",
                    ["accelerator"] = accel("KEY_NOW")})
    app.registerUi({["menu"] = "Auto zoom: settings panel", ["callback"] = "autozoomPanel",
                    ["accelerator"] = accel("KEY_PANEL")})
    app.registerUi({["menu"] = "Auto zoom: pause zoom in / out", ["callback"] = "autozoomPause",
                    ["accelerator"] = accel("KEY_PAUSE")})
    -- start by itself, once the main window exists (a few tries)
    if (CFG.START_ON or CFG.PANEL_AT_START) and bindings() then
        local tries = 0
        B.GLib.timeout_add(B.GLib.PRIORITY_DEFAULT, 1500, function()
            tries = tries + 1
            local ok = pcall(function()
                local okA, err = attach()
                if not okA then error(err) end
                if CFG.START_ON then turnOn(true) end
                if CFG.PANEL_AT_START then openPanel() end
            end)
            return not ok and tries < 6
        end)
    end
end
