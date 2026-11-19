-- Preserve View Navigation for Xournal++  (v2.7)
-- Author: Wissam Jassim (written with Claude).
-- Copyright (c) 2026 Wissam Jassim. MIT licence, see LICENSE in the repository root.
-- SPDX-License-Identifier: MIT
--
-- Next/Previous page WITHOUT losing your place: the viewport keeps the same
-- relative position on the new page instead of snapping back to the page top.
-- Made for step-by-step slide decks, where each page is one step and the view
-- should not jump between them.
--
-- KEYS
--   Ctrl+Alt+Right / Left   next / previous page, keeping the view
--   Ctrl+Alt+Down  / Up     nudge the view by 5px (manual fine-tune)
--   Ctrl+Alt+F10            check the computed page step against a real
--                           measurement (only if hops ever look wrong)
--   Ctrl+Alt+F11            the floating window "Page step"
--
-- FLOATING WINDOW (v2.4)
--   Big Previous / Next buttons for the pen (no key chord while writing), the
--   page number and the page step check. (Nudge stays on its keys and in the
--   menu only: with the computed page step it is rarely needed.) It stays above
--   Xournal++, never takes the keyboard, is its own window and remembers
--   its place.
--   It is read by a GLib timer about 30 times a second while it is open:
--   no signal handler anywhere (a Lua signal handler crashed Xournal++ once).
--
-- SETTINGS
--   File settings.txt next to this file, lines "NAME=value", written by the
--   plugin itself. Shortcut keys: change the KEY_... lines there with
--   Xournal++ closed (GTK form, e.g. KEY_NEXT=<Control>Page_Down or none).
--
-- REQUIREMENTS
--   Xournal++ 1.3.0 or later, stable or nightly (checked on the stable 1.3.8
--   and the 1.3.8+dev nightly), with LuaGObject (shipped since 1.3.0 on
--   Windows / macOS) or lgi. The nightly's app.getScrollPos() (PR #7278) is
--   used when present; without it (stable) the scroll bars give the same
--   numbers (2.7).
--
-- HOW IT WORKS
--   A hop is a plain RELATIVE scroll of exactly one page pitch, which keeps
--   the relative view by construction. (app.scrollToPage() cannot do this: it
--   scrolls the MINIMUM amount to make the page visible, so where it lands
--   depends on the direction of approach.)
--
--   The pitch is computed, not measured. Xournal++ places page n at
--       floor(sum of the heights of the pages before it * s) + n * 15 + padding
--   (src/core/gui/Layout.cpp, XOURNAL_PADDING_BETWEEN = 15), so one hop is
--       pitch = pageHeight * s + 15           (a decimal number of pixels)
--   where s = screen pixels per page point at the current zoom.
--
--   s is NOT app.getZoom(): that is the zoom relative to 100 %, and 100 % is
--   itself (screen DPI / 72) pixels per point (v2.1 missed this and hopped
--   short). s is read from the height of the whole scroll area, which is
--       2 * 10 + (pages - 1) * 15 + (sum of all page heights) * s
--   through GTK (LuaGObject; read only, no signal handlers). If GTK cannot be
--   reached, or the number disagrees with the estimate
--   getZoom() * getDisplayDpi() / 72 by more than 3 %, the estimate is used
--   instead (close, but the DPI is rounded, so hops may drift a little).
--
--   v2.0 measured the pitch with calibration jumps to the end of the document.
--   That had two faults, both fixed by the formula:
--     * the first hop at each zoom level was slow (jump to the document end
--       and back, with the PDF pages there rendered at the working zoom);
--     * a measured pitch is a difference of whole-pixel landings, so it was up
--       to 1px off the true decimal pitch, and every hop drifted by that much.
--   The decimal part of each hop is carried into the next one (`residual`), so
--   the view stays within one pixel of the true place however many hops.
--
--   The height used is the height of the page being crossed (the current page
--   going forward, the previous page going back), so documents with pages of
--   different heights work too.
--
-- LIMITATIONS (known and accepted)
--   * On the last page a deep offset can land short of a full page-top
--     alignment: GTK will not scroll past the end of the document. The
--     shortfall is carried, so hopping back returns to the right place.
--   * Single-column layout is assumed (one page per row).

local CFG = {
    NUDGE_PX = 5,           -- one nudge, in screen pixels
    PANEL_AT_START = false, -- show the floating window when Xournal++ starts
    PANEL_X = -1,           -- floating window position (saved by itself)
    PANEL_Y = -1,
    -- shortcut keys (GTK form, e.g. <Control><Alt>Right or <Shift>F2; none = no key). Read at start only.
    KEY_NEXT = "<Control><Alt>Right",
    KEY_PREVIOUS = "<Control><Alt>Left",
    KEY_NUDGE_DOWN = "<Control><Alt>Down",
    KEY_NUDGE_UP = "<Control><Alt>Up",
    KEY_CHECK = "<Control><Alt>F10",
    KEY_PANEL = "<Control><Alt>F11",
}
local DEFAULTS = {}
for k, v in pairs(CFG) do DEFAULTS[k] = v end

local SEP = package.config:sub(1, 1)
local LOGFILE = (os.getenv("TEMP") or os.getenv("TMPDIR") or ".") .. SEP .. "preserve-view.log"
local function log(text)
    local f = io.open(LOGFILE, "a")
    if f then
        f:write(os.date("%H:%M:%S "), tostring(text), "\n")
        f:close()
    end
end

-- ------------------------------------------------------------ settings file
local function settingsPath()
    local o = rawget(_G, "PRESERVE_VIEW_SETTINGS_FILE")     -- tests
    if type(o) == "string" then return o end
    local src = (debug and debug.getinfo) and debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(.*)[/\\][^/\\]*$")
    if dir then return dir .. SEP .. "settings.txt" end
    return nil
end
local SETTINGS = settingsPath()

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
    local f = SETTINGS and io.open(SETTINGS, "r")
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
            if n and n == n then CFG[k] = n end
        end
    end
    f:close()
    CFG.NUDGE_PX = math.max(1, math.min(50, math.floor(CFG.NUDGE_PX + 0.5)))
    return seen
end

local function saveSettings()
    if not SETTINGS then return end
    local keys = {}
    for k in pairs(DEFAULTS) do keys[#keys + 1] = k end
    table.sort(keys)
    local f = io.open(SETTINGS, "w")
    if not f then log("cannot write " .. SETTINGS) return end
    f:write("# Preserve view settings. Written by the plugin.\n")
    f:write("# KEY_... = shortcut keys, e.g. <Control><Alt>Right or <Shift>F2 (none = no key). Change them with Xournal++ closed.\n")
    for _, k in ipairs(keys) do f:write(k, "=", tostring(CFG[k]), "\n") end
    f:close()
end

-- Layout constants of Xournal++ in pixels, not scaled by zoom
-- (XOURNAL_PADDING_BETWEEN and XOURNAL_PADDING in src/core/gui/Layout.cpp).
local PAGE_GAP = 15
local EDGE_PAD = 10

-- Diagnostic menu entry, off by default to keep the menu clean.
local DEBUG = false

-- msgbox() is deprecated; app.openDialog() replaces it. Every message here is
-- a plain "OK" notice, so no callback ("") and error = false.
local function notify(message)
    if app.openDialog then
        app.openDialog(message, {"OK"}, "", false)
    else
        app.msgbox(message, {[1] = "OK"})
    end
end

-- Scroll position {x, y, width, height}; set below findScrolled (it needs it).
local scrollPos, findScrolled

local warnedMissingApi = false
local function hasApi()
    -- 2.7: without app.getScrollPos (stable 1.3.x) the page area's scroll bars are read instead.
    if app.getZoom ~= nil and (app.getScrollPos ~= nil or findScrolled()) then return true end
    if not warnedMissingApi then
        warnedMissingApi = true
        notify(
            "This plugin needs app.getZoom() and either app.getScrollPos() (nightly) " ..
            "or LuaGObject / lgi to read the scroll bars.\nNeither was found in this " ..
            "Xournal++ build.\nXournal++ 1.3.0 or later (stable or nightly) has them:\n" ..
            "https://github.com/xournalpp/xournalpp/releases")
    end
    return false
end

-- Reads everything a hop needs; nil if any part is missing or malformed.
local function readState()
    local pos = scrollPos()
    local doc = app.getDocumentStructure()
    local ok, zoom = pcall(app.getZoom)
    if type(pos) ~= "table" or type(pos["y"]) ~= "number" or
       type(doc) ~= "table" or type(doc["pages"]) ~= "table" or
       not ok or type(zoom) ~= "number" or not (zoom > 0) then
        return nil
    end
    return pos, doc, zoom
end

-- The scrolled window around the page canvas ("GtkXournal"), found once.
-- false = looked and not found (do not look again on every hop).
local scrolled = nil
findScrolled = function()
    if scrolled ~= nil then return scrolled or nil end
    scrolled = false
    local ok, lgo = pcall(require, "LuaGObject")
    if not ok then ok, lgo = pcall(require, "lgi") end      -- Linux builds with lgi
    if not ok then return nil end
    local okT, Gtk = pcall(lgo.require, "Gtk", "3.0")
    if not okT then return nil end
    local function isA(class, w)
        local okI, yes = pcall(function() return class:is_type_of(w) end)
        return okI and yes
    end
    local function walk(w, parents, depth)
        parents[depth] = w
        local okN, name = pcall(function() return w:get_name() end)
        if okN and name == "GtkXournal" then
            for d = depth - 1, 0, -1 do
                if isA(Gtk.ScrolledWindow, parents[d]) then return parents[d] end
            end
            return nil
        end
        if isA(Gtk.Container, w) then
            local okC, kids = pcall(function() return w:get_children() end)
            if okC and kids then
                for _, kid in ipairs(kids) do
                    local found = walk(kid, parents, depth + 1)
                    if found then return found end
                end
            end
        end
        return nil
    end
    local okL, tops = pcall(function() return Gtk.Window.list_toplevels() end)
    if not okL or not tops then return nil end
    for _, top in ipairs(tops) do
        local okV, visible = pcall(function() return top:get_visible() end)
        if okV and visible then
            local found = walk(top, {}, 0)
            if found then scrolled = found; return found end
        end
    end
    return nil
end

-- 2.7: app.getScrollPos (nightly only, PR #7278) returns the layout's visible rectangle, which IS
-- the scroll bars: value = x / y, page size = width / height (checked live in the nightly: 0.000 px
-- difference at every zoom, scroll and page jump). The stable 1.3.x lacks it: read the scroll bars.
local spAdj = nil
scrollPos = function()
    if app.getScrollPos then return app.getScrollPos() end
    local sw = findScrolled()
    if not sw then return nil end
    if spAdj == nil or spAdj.sw ~= sw then       -- kept: 0.017 ms per read instead of 0.08 ms
        spAdj = {sw = sw, h = sw:get_hadjustment(), v = sw:get_vadjustment()}
    end
    local h, v = spAdj.h, spAdj.v
    return {x = h:get_value(), y = v:get_value(), width = h:get_page_size(), height = v:get_page_size()}
end

-- Screen pixels per page point at the current zoom, and where the number came
-- from ("scroll area" = exact, "DPI estimate" = fallback). See HOW IT WORKS.
local function pixelsPerPoint(doc, zoom)
    local estimate = nil
    local okD, dpi = pcall(function() return app.getDisplayDpi() end)
    if okD and type(dpi) == "number" and dpi > 0 then estimate = zoom * dpi / 72 end

    local exact = nil
    local sw = findScrolled()
    if sw then
        local total, count = 0, #doc["pages"]
        for i = 1, count do
            local h = doc["pages"][i]["pageHeight"]
            if type(h) ~= "number" or not (h > 0) then total = nil break end
            total = total + h
        end
        local okU, upper = pcall(function() return sw:get_vadjustment():get_upper() end)
        if total and total > 0 and okU and type(upper) == "number" then
            exact = (upper - 2 * EDGE_PAD - (count - 1) * PAGE_GAP) / total
            if not (exact > 0) then exact = nil end
        end
    end

    if exact and (not estimate or math.abs(exact / estimate - 1) <= 0.03) then
        return exact, "scroll area"
    end
    if estimate then return estimate, "DPI estimate" end
    return nil
end

-- Carry state: the part of the last hop that was not scrolled (the decimal
-- part of the pitch, or the shortfall of a GTK document-end clamp). Only
-- meaningful at the same zoom and when nothing else scrolled in between.
local residual = 0
local lastY = nil
local lastZoom = nil

local function moveKeepView(direction)
    if not hasApi() then return end
    local before, doc, zoom = readState()
    if not before then return end

    local pages = doc["pages"]
    local count = #pages
    local current = doc["currentPage"] or 1
    -- no page to go to: do nothing rather than slide inside the end page
    if direction > 0 and current >= count then return end
    if direction < 0 and current <= 1 then return end

    -- the page being crossed: the current one going forward, the one before
    -- it going back
    local crossed = pages[direction > 0 and current or current - 1]
    local height = crossed and crossed["pageHeight"]
    if type(height) ~= "number" or not (height > 0) then return end
    local scale = pixelsPerPoint(doc, zoom)
    if not scale then return end
    local pitch = height * scale + PAGE_GAP

    if lastZoom ~= zoom or lastY == nil or math.abs(before["y"] - lastY) > 1 then
        residual = 0
    end
    lastZoom = zoom

    local wanted = before["y"] + direction * pitch + residual
    -- scroll to a WHOLE pixel: at a decimal scroll position GTK draws the page
    -- between two pixel rows, which shows as a slight blur. The decimal part
    -- is not lost: it goes into `residual` below.
    app.scrollToPos(before["x"], math.floor(wanted + 0.5), false)

    local after = scrollPos()
    if type(after) ~= "table" or type(after["y"]) ~= "number" then
        residual, lastY = 0, nil
        return
    end
    if math.abs(after["y"] - before["y"]) > 0.5 then
        -- moved: carry what was not scrolled (pixel rounding, or a real clamp)
        residual = wanted - after["y"]
    end
    -- fully blocked (nothing moved): leave residual exactly as it was.
    -- Resetting it would throw away a pending shortfall, and recomputing it
    -- would bank a full pitch per extra press.
    lastY = after["y"]
end

function nextPageKeepView()
    moveKeepView(1)
end

function previousPageKeepView()
    moveKeepView(-1)
end

function nudgeDown()
    app.scrollToPos(0, CFG.NUDGE_PX, true)
end

function nudgeUp()
    app.scrollToPos(0, -CFG.NUDGE_PX, true)
end

-- Compares the computed page step with a real measurement. Two scrollToPage
-- landings, both approached from a LATER page so both are true page tops,
-- taken `span` pages apart: the whole-pixel rounding of the two landings is
-- divided by `span`. Jumps to the document end and back (a visible flash),
-- which is why it is a manual check and never part of a hop.
function recalibrate()
    if not hasApi() then return end
    local before, doc, zoom = readState()
    if not before then return end
    local pages = doc["pages"]
    local count = #pages
    if count < 4 then
        notify("The check needs a document with at least 4 pages.")
        return
    end
    local scale, source = pixelsPerPoint(doc, zoom)
    if not scale then
        notify("Could not work out the screen scale (no GTK access and no display DPI).")
        return
    end

    local span = math.min(count - 2, 30)
    local high = count - 1          -- page whose top is the upper landing
    local low = high - span         -- page whose top is the lower landing

    app.scrollToPage(count, false)  -- anchor: forces "from a later page"
    local anchor = scrollPos()
    app.scrollToPage(high, false)
    local posHigh = scrollPos()
    app.scrollToPage(count, false)  -- re-anchor
    app.scrollToPage(low, false)
    local posLow = scrollPos()
    app.scrollToPos(before["x"], before["y"], false)
    residual, lastY, lastZoom = 0, nil, nil

    if math.abs(posHigh["y"] - anchor["y"]) < 1 then
        notify("Check failed: zoomed out so far that whole pages fit in the " ..
               "window. Zoom in and try again.")
        return
    end

    local heights = 0
    for i = low, high - 1 do heights = heights + pages[i]["pageHeight"] end
    local measured = (posHigh["y"] - posLow["y"]) / span
    local computed = (heights * scale) / span + PAGE_GAP
    local diff = computed - measured
    notify(string.format(
        "%s\npage step: computed %.2f px, measured %.2f px (difference %.2f)\n" ..
        "scale %.5f px per point, from the %s; zoom %.4f",
        math.abs(diff) <= 0.2 and "Check OK." or "Check: computed and measured page step DIFFER.",
        computed, measured, diff, scale, source, zoom))
end

function debugShowScrollPos()
    if not hasApi() then return end
    local pos, doc, zoom = readState()
    if not pos then return end
    local page = doc["pages"][doc["currentPage"] or 1]
    local height = page and page["pageHeight"] or 0
    notify("currentPage=" .. tostring(doc["currentPage"]) ..
        "\nx=" .. tostring(pos["x"]) ..
        "\ny=" .. tostring(pos["y"]) ..
        "\nwidth=" .. tostring(pos["width"]) ..
        "\nheight=" .. tostring(pos["height"]) ..
        "\nzoom=" .. tostring(zoom) ..
        "\nscale=" .. tostring((pixelsPerPoint(doc, zoom))) ..
        "\nresidual=" .. tostring(residual))
end

-- ------------------------------------------------------------ floating window
local B = nil
local function bindings()
    if B then return B end
    local ok, lgo = pcall(require, "LuaGObject")
    if not ok then ok, lgo = pcall(require, "lgi") end      -- Linux builds with lgi
    if not ok then return nil, "LuaGObject / lgi not found: " .. tostring(lgo) end
    local okG, GLib = pcall(function() return lgo.GLib end)
    if not okG or not GLib then return nil, "GLib failed: " .. tostring(GLib) end
    local okD, Gdk = pcall(lgo.require, "Gdk", "3.0")
    if not okD then return nil, "Gdk 3.0 failed: " .. tostring(Gdk) end
    local okT, Gtk = pcall(lgo.require, "Gtk", "3.0")
    if not okT then return nil, "Gtk 3.0 failed: " .. tostring(Gtk) end
    B = {GLib = GLib, Gdk = Gdk, Gtk = Gtk}
    return B
end

local panel = nil           -- the floating window, when open
local timerLive = false
local dirtyAt = nil         -- settings changed at this time (ms), not yet saved
-- Everything the tests replace goes through H.
local H = {}
function H.now() return B.GLib.get_monotonic_time() / 1000 end
function H.mainWindow()
    local sw = findScrolled()
    local ok, top = pcall(function() return sw:get_toplevel() end)
    return ok and top or nil
end

local function pageText()
    local ok, doc = pcall(app.getDocumentStructure)
    if not ok or type(doc) ~= "table" or type(doc["pages"]) ~= "table" then return "" end
    return string.format("Page %d / %d", doc["currentPage"] or 1, #doc["pages"])
end

function H.ensureTimer()
    if timerLive then return end
    timerLive = true
    local n = 0
    B.GLib.timeout_add(B.GLib.PRIORITY_DEFAULT, 30, function()
        n = n + 1
        if panel then
            local ok, e = pcall(panel.poll, n)
            if not ok then
                log("window error: " .. tostring(e))
                pcall(function() panel.win:destroy() end)
                panel = nil
            end
        end
        if dirtyAt and (not panel or H.now() - dirtyAt > 800) then
            dirtyAt = nil
            pcall(saveSettings)
        end
        if not panel then
            timerLive = false
            return false
        end
        return true
    end)
end

-- Buttons are toggles that the timer reads and sets back (no signal handler).
local BUTTONS = {
    {name = "previous", label = "\u{25C0}  Previous", w = 120, h = 56, col = 0, row = 0,
     tip = "Previous page, the view stays at the same place on the page.",
     run = function() previousPageKeepView() end},
    {name = "next", label = "Next  \u{25B6}", w = 120, h = 56, col = 1, row = 0,
     tip = "Next page, the view stays at the same place on the page.",
     run = function() nextPageKeepView() end},
    {name = "check", label = "Check page step", w = 246, h = 30, col = 0, row = 2, span = 2,
     tip = "Compares the computed page step with a real measurement and shows both.\n"
        .. "Needed only if page changes ever look wrong (for example after a Xournal++ update).\n"
        .. "The view jumps to the end of the document and back.",
     run = function() recalibrate() end},
}

local function openPanel()
    if panel then
        pcall(function() panel.win:present() end)
        return true
    end
    local b, err = bindings()
    if not b then notify("Page step window cannot open.\n" .. tostring(err)) return false end
    local top = H.mainWindow()
    if not top then notify("Page step window cannot open: page area not found.") return false end
    local G = b.Gtk
    local win = G.Window {title = "Page step", resizable = false, accept_focus = false, focus_on_map = false,
                          skip_taskbar_hint = true, type_hint = b.Gdk.WindowTypeHint.UTILITY}
    win:set_transient_for(top)
    local grid = G.Grid {row_spacing = 6, column_spacing = 6, margin = 10}
    win:add(grid)
    local p = {win = win, btn = {}}
    for _, d in ipairs(BUTTONS) do
        local t = G.ToggleButton.new_with_label(d.label)
        t:set_size_request(d.w, d.h)
        t:set_tooltip_text(d.tip)
        t:set_name("pv_" .. d.name)
        p.btn[d.name] = t
        grid:attach(t, d.col, d.row, d.span or 1, 1)
    end
    p.page = G.Label {label = pageText()}
    grid:attach(p.page, 0, 1, 2, 1)
    if CFG.PANEL_X >= 0 and CFG.PANEL_Y >= 0 then win:move(CFG.PANEL_X, CFG.PANEL_Y) end
    win:show_all()

    function p.poll(n)
        if not win:get_visible() then       -- closed with its X
            panel = nil
            return
        end
        local x, y = win:get_position()
        if type(x) == "number" and type(y) == "number" and (x ~= CFG.PANEL_X or y ~= CFG.PANEL_Y) then
            CFG.PANEL_X, CFG.PANEL_Y = x, y
            dirtyAt = H.now()
        end
        local acted = false
        for _, d in ipairs(BUTTONS) do
            local t = p.btn[d.name]
            if t:get_active() then          -- the user clicked it
                t:set_active(false)
                acted = true
                local ok, e = pcall(d.run)
                if not ok then log("button " .. d.name .. ": " .. tostring(e)) end
            end
        end
        -- the page number: after a click, after a scroll (looked at about 3 times a second) and
        -- every 3 s. It needs app.getDocumentStructure, about 8 ms for 420 pages: reading it
        -- 3 times a second made the pen stutter a little (2.6). The scroll position is cheap.
        if acted or (n or 0) % 10 == 0 then
            local spKey = nil
            if not acted then
                local okS, sp = pcall(scrollPos)
                if okS and type(sp) == "table" then spKey = tostring(sp["x"]) .. "," .. tostring(sp["y"]) end
            end
            if acted or spKey == nil or spKey ~= p.lastSp or (n or 0) % 100 == 0 then
                p.lastSp = spKey
                local text = pageText()
                if text ~= p.pageText then
                    p.page:set_label(text)
                    p.pageText = text
                end
            end
        end
    end

    panel = p
    H.ensureTimer()
    return true
end

function preserveViewPanel()
    local ok, e = pcall(openPanel)
    if not ok then
        log("window error: " .. tostring(e))
        pcall(function() if panel then panel.win:destroy() end end)
        panel = nil
        notify("Page step window cannot open.\n" .. tostring(e))
    end
end

local function accel(name)
    local v = CFG[name]
    if type(v) ~= "string" or v:lower() == "none" then return nil end
    return v
end

function initUi()
    -- settings first: the shortcut keys come from the file. A missing file, or one that
    -- lacks a setting, is written once, so every setting can be seen and changed there.
    local okL, seen = pcall(loadSettings)
    local all = 0
    for _ in pairs(DEFAULTS) do all = all + 1 end
    if okL and (seen or 0) < all then pcall(saveSettings) end

    app.registerUi({
        ["menu"] = "Next Page (Keep View)",
        ["callback"] = "nextPageKeepView",
        ["accelerator"] = accel("KEY_NEXT")
    })

    app.registerUi({
        ["menu"] = "Previous Page (Keep View)",
        ["callback"] = "previousPageKeepView",
        ["accelerator"] = accel("KEY_PREVIOUS")
    })

    app.registerUi({
        ["menu"] = "Nudge View Down",
        ["callback"] = "nudgeDown",
        ["accelerator"] = accel("KEY_NUDGE_DOWN")
    })

    app.registerUi({
        ["menu"] = "Nudge View Up",
        ["callback"] = "nudgeUp",
        ["accelerator"] = accel("KEY_NUDGE_UP")
    })

    app.registerUi({
        ["menu"] = "Check Page Step",
        ["callback"] = "recalibrate",
        ["accelerator"] = accel("KEY_CHECK")
    })

    app.registerUi({
        ["menu"] = "Page Step: show the floating window",
        ["callback"] = "preserveViewPanel",
        ["accelerator"] = accel("KEY_PANEL")
    })

    -- show the window by itself, once the main window exists (a few tries)
    if CFG.PANEL_AT_START and not rawget(_G, "PRESERVE_VIEW_TEST") and bindings() then
        local tries = 0
        B.GLib.timeout_add(B.GLib.PRIORITY_DEFAULT, 1900, function()
            tries = tries + 1
            scrolled = nil                  -- look for the page area again
            local ok = pcall(function()
                if not H.mainWindow() then error("no main window yet") end
                if not openPanel() then error("window did not open") end
            end)
            if ok then log("window opened at start") end
            return not ok and tries < 6
        end)
    end

    if not DEBUG then return end

    app.registerUi({
        ["menu"] = "Debug: Show Scroll Pos",
        ["callback"] = "debugShowScrollPos"
    })
end

if rawget(_G, "PRESERVE_VIEW_TEST") then
    PRESERVE_VIEW_INTERNALS = {CFG = CFG, H = H, validKey = validKey, loadSettings = loadSettings,
                               saveSettings = saveSettings, panel = function() return panel end}
end
