-- Snapshot region plugin for Xournal++  (v0.11)
-- Author: Wissam Jassim (written with Claude).
-- Copyright (c) 2026 Wissam Jassim. MIT licence, see LICENSE in the repository root.
-- SPDX-License-Identifier: MIT
--
-- WHAT IT DOES
--   Copies a part of the page as a picture you can drag: the PDF background and everything
--   written on it (pen, highlighter, text, pictures, all visible layers).
--
-- HOW TO USE
--   1. Click "Snapshot" in the small floating window (or press Ctrl+Alt+F8).
--      The tool changes to Select Rectangle.
--   2. Drag a rectangle over the part you want.
--   3. On release a copy sits on top of the original, already selected, and your earlier
--      tool is back. Drag the copy where you need it. Ctrl+Z removes it.
--      The copy is also on the clipboard: Ctrl+V in Word, PowerPoint, Paint ... (CLIPBOARD).
--      "Transparent background" (tick box in the window): the page colour around the
--      writing is see-through, so the copy does not hide what lies under it.
--   Click the button (or press the key) again to leave the mode without copying.
--   Ctrl+Alt+F9 shows the floating window again after it was closed.
--
-- HOW IT WORKS
--   The plugin API has no mouse events. This build ships LuaGObject (GTK bridge), which
--   gives a GLib timer; the timer POLLS the pointer on the page canvas ("GtkXournal") and
--   notes where the drag starts and ends, while Xournal++'s own Select Rectangle tool draws
--   the rectangle. The two points are turned into page points with the page layout (same
--   maths as the autozoom plugin), the page is exported to a PNG in the temp folder, the
--   region is cut out with GdkPixbuf, its background is made see-through (TRANSPARENT),
--   and the picture is inserted with app.addImages, selected, and put on the clipboard.
--   The floating window is polled the same way: no signal handler anywhere.
--   SPEED (0.8): the page list (app.getDocumentStructure, about 8 ms for 420 pages) is read
--   once when the mode starts, never at every timer tick, so the rectangle follows the pen
--   smoothly. The page is exported and loaded as soon as the mode starts (EARLY_EXPORT),
--   while the pen travels to the page; on release only the cut is left to do.
--   NEVER connect a Lua handler to a signal (crashed Xournal++ once), NEVER require("ffi").
--
-- SETTINGS
--   File settings.txt next to this file, lines "KEY=value" (see CFG below). The plugin
--   writes it itself when the floating window is moved.
--   Shortcut keys: change KEY_RECT / KEY_PANEL there (close Xournal++ first, the plugin
--   reads them when Xournal++ starts). Example: KEY_RECT=<Control><Shift>S

local CFG = {
    PX_PER_PT = 4,          -- sharpness: picture pixels per page point (960 pt wide page -> 3840 px). 0.11: was 6;
                            -- 4 looks the same zoomed in and halves the hold-up (0.39 -> 0.19 s, measured)
    ZOOM_HEADROOM = 1.25,   -- zoomed in further than PX_PER_PT: picture pixels = screen pixels x this
    MAX_PAGE_PX = 8000,     -- upper limit for the exported page width in pixels
    MIN_SIZE = 10,          -- smaller rectangles (page points, either side) are ignored
    OFFSET_X = 0,           -- where the copy lands relative to the original (page points)
    OFFSET_Y = 0,
    TRANSPARENT = true,     -- the copy has no background: the page colour around the writing becomes see-through
    FAINT_CUT = 20,         --   what is left less solid than this (percent) goes too: pale card outlines (0 = keep)
    BG_SHARE = 5,           --   a second background colour must fill this share of the copy (percent)
    BG_NEAR = 60,           --   and lie this near the main one (0 .. 255; 0 = one background colour only)
    CLIPBOARD = true,       -- every copy also goes to the Windows clipboard (paste into Word, PowerPoint, Paint ...)
    EARLY_EXPORT = true,    -- export the page as soon as the mode starts, so the copy appears at once on release
    EARLY_DELAY_MS = 200,   --   that long after the press, so the lit button is drawn first (ms)
    SETTLE_MS = 80,        -- wait after the release, so Xournal++ finishes its own selection first
    TICK_MS = 16,           -- timer interval
    LATE_MS = 100,          -- a press first seen after a longer break than this (Xournal++ was busy) is not used
    PANEL_AT_START = false, -- show the floating window when Xournal++ starts (Ctrl+Alt+F9 shows it any time)
    PANEL_X = -1,           -- floating window position (saved by itself)
    PANEL_Y = -1,
    PAD = 10,               -- layout: space before the first page (pixels, does not scale)
    GAP = 15,               -- layout: space between pages (pixels, does not scale)
    LOG = true,             -- write %TEMP%\snapshot.log
    -- shortcut keys (GTK form, e.g. <Control><Alt>F8 or <Shift>F2; none = no key). Read at start only.
    KEY_RECT = "<Control><Alt>F8",      -- rectangle mode on / off
    KEY_PANEL = "<Control><Alt>F9",     -- show the floating window
}

local DEFAULTS = {}
for k, v in pairs(CFG) do DEFAULTS[k] = v end

local TEMP = os.getenv("TEMP") or os.getenv("TMPDIR") or "."
local SEP = package.config:sub(1, 1)
local LOGFILE = rawget(_G, "SNAPSHOT_LOG_FILE") or (TEMP .. SEP .. "snapshot.log")

local function log(s)
    if not CFG.LOG then return end
    local f = io.open(LOGFILE, "a")
    if f then
        f:write(os.date("%H:%M:%S "), tostring(s), "\n")
        f:close()
    end
end

-- ------------------------------------------------------------------ settings file
local function settingsPath()
    local o = rawget(_G, "SNAPSHOT_SETTINGS_FILE")
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
    if CFG.PX_PER_PT < 1 then CFG.PX_PER_PT = 1 end
    if CFG.ZOOM_HEADROOM < 1 then CFG.ZOOM_HEADROOM = 1 end
    if CFG.MAX_PAGE_PX < 500 then CFG.MAX_PAGE_PX = 500 end
    if CFG.MIN_SIZE < 1 then CFG.MIN_SIZE = 1 end
    if CFG.TICK_MS < 5 then CFG.TICK_MS = 5 end
    if CFG.EARLY_DELAY_MS < 0 then CFG.EARLY_DELAY_MS = 0 end
    CFG.FAINT_CUT = math.max(0, math.min(90, CFG.FAINT_CUT))
    CFG.BG_SHARE = math.max(1, math.min(100, CFG.BG_SHARE))
    CFG.BG_NEAR = math.max(0, math.min(255, CFG.BG_NEAR))
    return seen
end

local function saveSettings()
    if not SETTINGS then return end
    local keys = {}
    for k in pairs(DEFAULTS) do keys[#keys + 1] = k end
    table.sort(keys)
    local f = io.open(SETTINGS, "w")
    if not f then log("cannot write " .. SETTINGS) return end
    f:write("# Snapshot settings. The plugin rewrites this file when its window is moved.\n")
    f:write("# KEY_... = shortcut keys, e.g. <Control><Alt>F8 or <Shift>F2 (none = no key). Change them with Xournal++ closed.\n")
    for _, k in ipairs(keys) do f:write(k, "=", tostring(CFG[k]), "\n") end
    f:close()
end

-- ------------------------------------------------------------------ pure helpers
-- Bounds of a list of points, snapped outwards to whole page points and clipped to the page.
-- Returns nil when the box is too small.
local function strokeBox(stroke, pageW, pageH, minSize)
    local xs, ys = stroke and stroke.x, stroke and stroke.y
    if type(xs) ~= "table" or type(ys) ~= "table" or #xs == 0 or #ys == 0 then return nil end
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, v in ipairs(xs) do if v < x0 then x0 = v end if v > x1 then x1 = v end end
    for _, v in ipairs(ys) do if v < y0 then y0 = v end if v > y1 then y1 = v end end
    x0, y0 = math.max(0, math.floor(x0)), math.max(0, math.floor(y0))
    x1, y1 = math.min(math.floor(pageW), math.ceil(x1)), math.min(math.floor(pageH), math.ceil(y1))
    local w, h = x1 - x0, y1 - y0
    if w < minSize or h < minSize then return nil end
    return {x = x0, y = y0, w = w, h = h}
end

-- Pixel rectangle of a page box inside a page picture of pixW x pixH pixels.
local function pixelRect(box, pageW, pageH, pixW, pixH)
    local sx, sy = pixW / pageW, pixH / pageH
    local px = math.max(0, math.min(pixW - 1, math.floor(box.x * sx + 0.5)))
    local py = math.max(0, math.min(pixH - 1, math.floor(box.y * sy + 0.5)))
    local pw = math.max(1, math.min(pixW - px, math.floor(box.w * sx + 0.5)))
    local ph = math.max(1, math.min(pixH - py, math.floor(box.h * sy + 0.5)))
    return {x = px, y = py, w = pw, h = ph}
end

-- Width of the exported page picture. `s` = screen pixels per page point now (nil = unknown):
-- when the view is zoomed in further than PX_PER_PT, the picture follows the zoom, so the
-- copy is as sharp as the page around it (up to MAX_PAGE_PX).
local function exportWidth(pageW, s)
    local perPt = CFG.PX_PER_PT
    if type(s) == "number" and s * CFG.ZOOM_HEADROOM > perPt then perPt = s * CFG.ZOOM_HEADROOM end
    local w = math.floor(pageW * perPt + 0.5)
    if w > CFG.MAX_PAGE_PX then w = math.floor(CFG.MAX_PAGE_PX) end
    return w
end

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

-- ------------------------------------------------------------------ GTK bridge
local B = nil
local function bindings()
    if B then return B end
    local ok, lgo = pcall(require, "LuaGObject")
    if not ok then
        ok, lgo = pcall(require, "lgi")
        if not ok then return nil, "LuaGObject / lgi not found: " .. tostring(lgo) end
    end
    local okG, GLib = pcall(function() return lgo.GLib end)
    if not okG then return nil, "GLib failed: " .. tostring(GLib) end
    local okD, Gdk = pcall(lgo.require, "Gdk", "3.0")
    if not okD then return nil, "Gdk 3.0 failed: " .. tostring(Gdk) end
    local okT, Gtk = pcall(lgo.require, "Gtk", "3.0")
    if not okT then return nil, "Gtk 3.0 failed: " .. tostring(Gtk) end
    B = {GLib = GLib, Gdk = Gdk, Gtk = Gtk, lgo = lgo}
    return B
end

local PB = nil
local function pixbufLib()
    if PB then return PB end
    local o = rawget(_G, "SNAPSHOT_PIXBUF")          -- tests put a fake here
    if o then PB = o return PB end
    local b, err = bindings()
    if not b then return nil, err end
    local okP, lib = pcall(b.lgo.require, "GdkPixbuf", "2.0")
    if not okP then return nil, "GdkPixbuf 2.0 failed: " .. tostring(lib) end
    PB = lib
    return PB
end

-- ------------------------------------------------------------------ transparent background
-- The background colours of a picture, most frequent first: {{r, g, b}, ...}.
-- Counted on a grid of points over the whole picture (about 150 x 150). Not the border
-- alone: a rectangle dragged along the frame of a box would give the frame colour.
-- The most frequent colour is always a background. Further ones (a snap that holds a
-- tinted card AND the white page around it) must each fill BG_SHARE percent of the picture
-- and lie near the first one (no channel further than BG_NEAR), so a large strongly
-- coloured shape is never taken for background. At most 4.
-- px = the pixels as one string, 4 bytes each (red, green, blue, alpha), rows of `stride` bytes.
local function backgroundColours(px, w, h, stride)
    local count, keys, total = {}, {}, 0
    local stepX, stepY = math.max(1, w // 150), math.max(1, h // 150)
    for y = stepY // 2, h - 1, stepY do
        local row = y * stride
        for x = stepX // 2, w - 1, stepX do
            local off = row + x * 4
            local k = px:sub(off + 1, off + 3)
            local n = count[k]
            if not n then n = 0 keys[#keys + 1] = k end
            count[k] = n + 1
            total = total + 1
        end
    end
    table.sort(keys, function(p, q) if count[p] ~= count[q] then return count[p] > count[q] end return p < q end)
    local r0, g0, b0 = keys[1]:byte(1, 3)
    local list = {{r0, g0, b0}}
    for i = 2, #keys do
        if #list >= 4 or count[keys[i]] * 100 < CFG.BG_SHARE * total then break end
        local r, g, b = keys[i]:byte(1, 3)
        if math.max(math.abs(r - r0), math.abs(g - g0), math.abs(b - b0)) <= CFG.BG_NEAR then
            list[#list + 1] = {r, g, b}
        end
    end
    return list
end

-- "Colour to alpha": a table that gives, for every pixel (4-byte string), the pixel without
-- the background colours `list`. For each pixel the background that explains it best (the
-- one that leaves it least solid) is used. A pixel of exactly that colour becomes fully
-- see-through; a pixel between the background and a letter (the soft edge of the letter)
-- becomes partly see-through with the letter's own colour, so no light rim is left; a pixel
-- far from the background stays solid. Laid back on the same background the picture looks
-- exactly as before.
-- `cut` (0 .. 1): what would be left less solid than this is pale decoration (the thin
-- outline of a card, a faint tint) and becomes fully see-through too.
-- A see-through pixel keeps its own colour, so a program that ignores transparency
-- (Paint) shows the picture as it was. Each colour is worked out once, then looked up.
local function fadeTable(list, cut)
    cut = cut or 0
    local function need(p, b)       -- how solid this channel must be
        if p > b then return (p - b) / (255 - b) elseif p < b then return (b - p) / b end
        return 0
    end
    local function chan(p, b, a)
        local v = math.floor(b + (p - b) / a + 0.5)
        if v < 0 then return 0 elseif v > 255 then return 255 end
        return v
    end
    return setmetatable({}, {__index = function(t, k)
        local r, g, b, a0 = k:byte(1, 4)
        local a, bk = math.huge, nil
        for _, c in ipairs(list) do
            local ac = math.max(need(r, c[1]), need(g, c[2]), need(b, c[3]))
            if ac < a then a, bk = ac, c end
        end
        local v
        if a <= 0 or a < cut then
            v = string.char(r, g, b, 0)
        else
            v = string.char(chan(r, bk[1], a), chan(g, bk[2], a), chan(b, bk[3], a), math.floor(a * a0 + 0.5))
        end
        t[k] = v
        return v
    end})
end

-- A copy of the picture `pb` with its background colour made see-through.
local function transparentCopy(lib, pb)
    local src = pb:add_alpha(false, 0, 0, 0)        -- own copy, 4 bytes per pixel
    local w, h, stride = src:get_width(), src:get_height(), src:get_rowstride()
    if stride ~= w * 4 then error("unexpected row length " .. tostring(stride)) end
    local px = src:get_pixels()
    if type(px) ~= "string" then px = src:read_pixel_bytes().data end
    if type(px) ~= "string" or #px < h * stride then error("pixels cannot be read") end
    if #px > h * stride then px = px:sub(1, h * stride) end
    local list = backgroundColours(px, w, h, stride)
    local new = px:gsub("....", fadeTable(list, CFG.FAINT_CUT / 100))
    local bytes = bindings().lgo.GLib.Bytes(new)
    local res = lib.Pixbuf.new_from_bytes(bytes, lib.Colorspace.RGB, true, 8, w, h, stride)
    if not res then error("picture cannot be built") end
    local names = {}
    for i, c in ipairs(list) do names[i] = string.format("%d,%d,%d", c[1], c[2], c[3]) end
    return res, "background " .. table.concat(names, " + ") .. " removed"
end

-- Cuts box out of the page picture pb (in memory), writes it to dstPath. Returns the pixel
-- rectangle and the cut picture, or nil + error.
local function cropPixbuf(lib, pb, dstPath, box, pageW, pageH)
    local ok, res, pic = pcall(function()
        local r = pixelRect(box, pageW, pageH, pb:get_width(), pb:get_height())
        local sub = pb:new_subpixbuf(r.x, r.y, r.w, r.h)
        if not sub then error("crop failed") end
        local cut = sub
        if CFG.TRANSPARENT then
            local okT, t, note = pcall(transparentCopy, lib, sub)
            if okT and t then
                cut, r.note = t, note
            else
                log("transparent background failed, plain copy made: " .. tostring(t))
            end
        end
        local saved = cut:savev(dstPath, "png", {}, {})
        if not saved then error("cannot write " .. dstPath) end
        return r, cut
    end)
    if not ok then return nil, tostring(res) end
    return res, pic
end

-- Cuts box out of the page picture file srcPath (see cropPixbuf).
local function cropFile(srcPath, dstPath, box, pageW, pageH)
    local lib, err = pixbufLib()
    if not lib then return nil, err end
    local okR, pb = pcall(lib.Pixbuf.new_from_file, srcPath)
    if not okR or not pb then return nil, "cannot read " .. srcPath end
    return cropPixbuf(lib, pb, dstPath, box, pageW, pageH)
end

-- Everything that touches GTK goes through H, so the tests can put fakes in.
local H = {}

-- Puts the picture on the clipboard of Windows. Returns true when it went there.
function H.toClipboard(pic)
    local ok, e = pcall(function()
        local b = bindings()
        local own = pic
        if pic.copy then own = pic:copy() or pic end    -- its own pixels (a cut shares the whole page picture)
        local cb = b.Gtk.Clipboard.get_default(b.Gdk.Display.get_default())
        cb:set_image(own)
    end)
    if not ok then log("clipboard failed: " .. tostring(e)) end
    return ok
end

-- ------------------------------------------------------------------ copy a page box
-- Exports the page to a PNG and returns the path of the file that was written.
local function exportPage(pageNo, pageW, s)
    local stem = TEMP .. SEP .. "xournalpp_snapshot_page"
    local out = stem .. ".png"
    local numbered = stem .. "-" .. pageNo .. ".png"
    os.remove(out)
    os.remove(numbered)
    local ok, err = pcall(app.export, {["outputFile"] = out, ["range"] = tostring(pageNo),
                                       ["background"] = "all", ["pngWidth"] = exportWidth(pageW, s)})
    if not ok then return nil, "export failed: " .. tostring(err) end
    if fileExists(out) then return out end
    if fileExists(numbered) then return numbered end
    return nil, "export wrote no file"
end

-- Exports page pageNo and loads it: {page, width, pb}, or nil + reason. The file is removed.
local function loadPage(lib, pageNo, pageW, s)
    local path, err = exportPage(pageNo, pageW, s)
    if not path then return nil, err end
    local ok, pb = pcall(lib.Pixbuf.new_from_file, path)
    os.remove(path)
    if not ok or not pb then return nil, "cannot read the page picture: " .. tostring(pb) end
    return {page = pageNo, width = exportWidth(pageW, s), pb = pb}
end

-- Puts a selected picture of `box` (page points, whole numbers) on the current page.
-- `pre` = the page made in advance ({page, width, pb}), used when it is that page at the
-- same sharpness. `upAt` = time of the release (ms), for the log.
-- Returns a text for the log, or nil + reason.
local function copyBox(box, pageNo, pageW, pageH, s, pre, upAt)
    if app.clearSelection then pcall(app.clearSelection) end
    local lib, lerr = pixbufLib()
    if not lib then return nil, lerr end
    local t0 = os.clock()
    local page, how = nil, nil
    if pre and pre.pb and pre.page == pageNo and pre.width == exportWidth(pageW, s) then
        page, how = pre, "page made in advance"
    else
        local err
        page, err = loadPage(lib, pageNo, pageW, s)
        if not page then return nil, err end
        how = string.format("export + load %.2f s", os.clock() - t0)
    end
    local t1 = os.clock()
    local cut = TEMP .. SEP .. "xournalpp_snapshot_cut.png"
    os.remove(cut)
    local rect, pic = cropPixbuf(lib, page.pb, cut, box, pageW, pageH)
    if not rect then return nil, pic end
    local t2 = os.clock()
    local onClip = CFG.CLIPBOARD and pic ~= nil and H.toClipboard(pic) or false
    local t3 = os.clock()

    local okA, refs = pcall(app.addImages, {
        images = {{path = cut, x = box.x + CFG.OFFSET_X, y = box.y + CFG.OFFSET_Y,
                   maxWidth = math.tointeger(box.w) or box.w, maxHeight = math.tointeger(box.h) or box.h,
                   aspectRatio = false}},
        allowUndoRedoAction = "grouped"})
    os.remove(cut)
    if not okA then return nil, "addImages failed: " .. tostring(refs) end
    local good = {}
    for _, r in ipairs(type(refs) == "table" and refs or {}) do
        if type(r) == "userdata" then good[#good + 1] = r
        else return nil, "addImages: " .. tostring(r) end
    end
    if #good > 0 and app.addToSelection then pcall(app.addToSelection, good) end
    if app.refreshPage then pcall(app.refreshPage) end
    local t4 = os.clock()
    local since = ""
    if type(upAt) == "number" then since = string.format(", %.2f s after the release", (H.now() - upAt) / 1000) end
    return string.format("copied %dx%d pt at (%d, %d) on page %d, picture %dx%d px, %s, cut %.2f s, "
                         .. "clipboard %.2f s, add %.2f s%s%s%s",
                         box.w, box.h, box.x, box.y, pageNo, rect.w, rect.h, how, t2 - t1, t3 - t2, t4 - t3, since,
                         rect.note and (", " .. rect.note) or "", onClip and ", on the clipboard" or ""), onClip
end

local function hasApi()
    return app.export and app.addImages and app.getDocumentStructure and true or false
end

-- ------------------------------------------------------------------ page area and pointer
local scaleLooksRight
local ui = nil          -- {canvas, scrolled, top, gdkwin, pointer}

-- Scroll position {x, y, width, height} of the page area, in layout pixels.
-- 0.9: the stable Xournal++ 1.3.x has no app.getScrollPos (nightly only, PR #7278). That function
-- returns the layout's visible rectangle, which IS the page area's scroll bars: value = x / y,
-- page size = width / height (checked live in the nightly: 0.000 px difference at every zoom,
-- scroll and page jump, also right after setZoom). So without it the scroll bars are read.
local function scrollPos()
    if app.getScrollPos then return app.getScrollPos() end
    if not ui.hadj then ui.hadj, ui.vadj = ui.scrolled:get_hadjustment(), ui.scrolled:get_vadjustment() end
    local h, v = ui.hadj, ui.vadj    -- kept: 0.017 ms per read instead of 0.08 ms (measured)
    return {x = h:get_value(), y = v:get_value(), width = h:get_page_size(), height = v:get_page_size()}
end
local panel = nil       -- the floating window, when open

-- 0.11: the mode is published in the process environment (XOPP_SNAPSHOT_ON = 1 while it waits for
-- a drag, until the copy is made; 0 otherwise), so tool-dock (its own Lua state) can light its
-- snapshot button, as it does for auto zoom. Set only when it changes.
local publishedOn = nil
function H.publish(on)
    if on == publishedOn then return end
    publishedOn = on
    pcall(function() bindings().GLib.setenv("XOPP_SNAPSHOT_ON", on and "1" or "0", true) end)
end

-- 0.11: a small note beside the pen that goes away by itself (no button to click). Only when the
-- floating window is closed: when it is open, its status line says the same.
function H.toast(text, pen)
    if panel or not ui or not ui.gdkwin then return end
    pcall(function()
        local G = bindings().Gtk
        local win = G.Window {type = G.WindowType.POPUP, accept_focus = false, focus_on_map = false}
        if ui.top then win:set_transient_for(ui.top) end
        win:add(G.Label {label = text, margin = 12})
        local r = {ui.gdkwin:get_origin()}
        local ox, oy = r[#r - 1], r[#r]
        if type(ox) == "number" and type(oy) == "number" then
            local px, py = 24, 24
            if pen and type(pen.x) == "number" and type(pen.y) == "number" then px, py = pen.x + 24, pen.y + 24 end
            win:move(math.floor(ox + px), math.floor(oy + py))
        end
        win:show_all()
        bindings().GLib.timeout_add(bindings().GLib.PRIORITY_DEFAULT, 2000, function()
            pcall(function() win:destroy() end)
            return false
        end)
    end)
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

function H.attach()
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

function H.now() return bindings().GLib.get_monotonic_time() / 1000 end

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

-- Pointer on the page canvas: x, y in view pixels, button down, inside the page area.
function H.readPen(sp)
    local okQ, _, x, y, mask = pcall(function() return ui.gdkwin:get_device_position(ui.pointer) end)
    if not okQ or type(x) ~= "number" or type(y) ~= "number" then return nil end
    local down = false
    pcall(function() down = mask and mask.BUTTON1_MASK and true or false end)
    local inside = x >= 0 and y >= 0 and x < sp["width"] and y < sp["height"] and not overPanel()
    return {x = x, y = y, down = down, inside = inside}
end

-- Is a window of Xournal++ (main window, this floating window, a dialog) the active window
-- of the desktop? False while another program is in front. `is_active` is a property in
-- LuaGObject (a plain boolean): calling it as a method fails. Unknown counts as "yes".
-- The answer is kept for 250 ms: Xournal++ has about 40 windows (most are hidden menus) and
-- asking all of them took about 2 ms, at every tick (16 ms) while the mode waits (0.7, measured).
local activeCache = nil
function H.appActive()
    local now = H.now()
    if activeCache and now - activeCache.at < 250 then return activeCache.res end
    local ok, res = pcall(function()
        local known = false
        for _, t in ipairs(bindings().Gtk.Window.list_toplevels()) do
            local a = t.is_active
            if a == true then return true end
            if a == false then known = true end
        end
        return not known
    end)
    activeCache = {at = now, res = (not ok) or res}
    return activeCache.res
end

-- Scroll range now: upper value of the vertical and of the horizontal scroll bar, and the
-- height of the view (page size of the vertical scroll bar; nil if it cannot be read).
function H.scrollRange()
    local ok, uv, uh = pcall(function()
        return ui.scrolled:get_vadjustment():get_upper(), ui.scrolled:get_hadjustment():get_upper()
    end)
    if not ok or type(uv) ~= "number" or type(uh) ~= "number" then return nil end
    local okP, vp = pcall(function() return ui.scrolled:get_vadjustment():get_page_size() end)
    return uv, uh, (okP and type(vp) == "number") and vp or nil
end

-- ------------------------------------------------------------------ layout model (as in autozoom)
-- model = {n, cum[1..n] = heights of earlier pages (pt), w[i], h[i], total}
local function buildModel()
    local doc = app.getDocumentStructure()
    if type(doc) ~= "table" or type(doc["pages"]) ~= "table" then return nil end
    local pages = doc["pages"]
    local m = {n = #pages, cum = {}, w = {}, h = {}, total = 0, current = doc["currentPage"]}
    if m.n < 1 then return nil end
    for i = 1, m.n do
        local h, w = pages[i]["pageHeight"], pages[i]["pageWidth"]
        if type(h) ~= "number" or type(w) ~= "number" or h <= 0 or w <= 0 then return nil end
        m.cum[i], m.h[i], m.w[i] = m.total, h, w
        m.total = m.total + h
    end
    return m
end

-- layout = {s = pixels per page point, uh = scroll width, oy = empty space above the first page}
-- When the whole document fits in the view (zoom fit on a short document), the scroll area is the
-- view itself, not the pages, and Xournal++ centres the pages in it (0.10). s then comes from
-- zoom x DPI / 72 (the DPI is rounded, so it can be a few tenths of a percent off).
local function readLayout(m)
    local uv, uh, vp = H.scrollRange()
    if not uv then return nil end
    local s = (uv - 2 * CFG.PAD - (m.n - 1) * CFG.GAP) / m.total      -- pixels per page point
    local oy = 0
    if vp and uv <= vp + 0.5 then
        local ok, est = pcall(function() return app.getZoom() * app.getDisplayDpi() / 72 end)
        if ok and type(est) == "number" and est > 0 then
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

-- View point of the pointer -> page point {i, x, y}. With `page` given the point is
-- measured on that page (it may then lie outside it). `m` = the page model taken when the
-- mode started (reading it costs about 8 ms for 420 pages: never at every tick).
local function docAt(sp, pen, page, m)
    m = m or buildModel()
    local lay = m and readLayout(m)
    if not lay then return nil end
    local X, Y = sp["x"] + pen.x, sp["y"] + pen.y
    local i = page
    if not i or i > m.n then
        local lo, hi = 1, m.n
        while lo < hi do
            local mid = (lo + hi + 1) // 2
            if pageTop(m, lay, mid) <= Y then lo = mid else hi = mid - 1 end
        end
        i = lo
    end
    return {i = i, x = (X - (lay.uh - m.w[i] * lay.s) / 2) / lay.s, y = (Y - pageTop(m, lay, i)) / lay.s,
            w = m.w[i], h = m.h[i], s = lay.s}
end

-- Self-check of the layout maths: the scale read from the scroll area must agree with
-- zoom x screen DPI / 72 (the DPI is rounded, so only roughly). A big difference means
-- Xournal++ changed its page layout (PAD / GAP) and the copy may land beside the rectangle.
local scaleWarned = false
scaleLooksRight = function(s)
    local ok, est = pcall(function() return app.getZoom() * app.getDisplayDpi() / 72 end)
    if not ok or type(est) ~= "number" or not (est > 0) or type(s) ~= "number" then return true end
    if math.abs(s / est - 1) <= 0.05 then return true end
    if not scaleWarned then
        scaleWarned = true
        log(string.format("WARNING layout check: scale %.4f from the scroll area, %.4f from zoom and DPI. "
            .. "Xournal++ may have changed its page layout (PAD / GAP in settings.txt).", s, est))
    end
    return false
end

-- ------------------------------------------------------------------ rectangle mode
local S = {mode = "IDLE", status = ""}      -- IDLE / ARMED / DRAG / SETTLE
local timerGen, timerLive = 0, false
local dirtyAt = nil

local function setStatus(text)
    if text ~= S.status then log(text) end
    S.status = text
end

local function rectTool()
    local c = app.C
    return (type(c) == "table" and c.Tool_selectRect) or 6
end

local function currentTool()
    if not app.getActionState then return nil end
    local ok, t = pcall(app.getActionState, "select-tool")
    if ok then return t end
    return nil
end

local function setTool(t)
    if t == nil or not app.changeActionState then return false end
    return (pcall(app.changeActionState, "select-tool", t))
end

local function disarm(restore, text)
    if restore and S.prevTool ~= nil and S.prevTool ~= rectTool() then setTool(S.prevTool) end
    S.mode, S.a, S.b, S.upAt, S.seenUp, S.prevTool = "IDLE", nil, nil, nil, nil, nil
    if S.pre then
        S.pre = nil
        H.later(300, function() collectgarbage() end)   -- give the big page picture back soon
    end
    S.model = nil
    H.publish(false)
    if text then setStatus(text) end
end

-- Exports and loads the current page while the mode waits for the drag (the pen is on its
-- way to the page), so the release only has the cut to do. Skipped once a drag has begun.
-- While the mode is on, the tool is Select Rectangle: nothing new is written on the page.
local function earlyExport(gen)
    if S.mode ~= "ARMED" or S.armGen ~= gen or S.pre then return end
    local m = S.model
    local i = m and m.current
    if type(i) ~= "number" or i < 1 or i > m.n then return end
    local lib = pixbufLib()
    if not lib then return end
    local lay = readLayout(m)
    local t0 = os.clock()
    local page, err = loadPage(lib, i, m.w[i], lay and lay.s)
    if page then
        S.pre = page
        log(string.format("page %d made in advance (%d px wide, %.2f s)", i, page.width, os.clock() - t0))
    else
        log("early export failed (the copy will export on release): " .. tostring(err))
    end
end

local function arm()
    if S.mode ~= "IDLE" then return true end
    if not hasApi() then setStatus("this Xournal++ build lacks export / addImages") return false end
    if not ui then
        local ok, err = H.attach()
        if not ok then setStatus("cannot start: " .. tostring(err)) return false end
    end
    S.prevTool = currentTool()
    if not setTool(rectTool()) then
        S.prevTool = nil
        setStatus("cannot switch to the Select Rectangle tool")
        return false
    end
    S.mode, S.seenUp, S.missed, S.lastTick = "ARMED", false, nil, H.now()
    H.publish(true)
    local okM, m = pcall(buildModel)
    S.model = okM and m or nil
    S.armGen = (S.armGen or 0) + 1
    setStatus("drag a rectangle on the page")
    H.ensureTimer()
    if CFG.EARLY_EXPORT and S.model then
        local gen = S.armGen
        -- 0.11: wait EARLY_DELAY_MS (was 60 ms) so the lit dock button and the tool change are drawn
        -- before the export holds Xournal++ up (about 0.4 s); the press then feels as quick as any tool
        H.later(CFG.EARLY_DELAY_MS, function() earlyExport(gen) end)
    end
    return true
end

-- The drag is over: copy the rectangle between S.a and S.b.
local function finish()
    local a, b = S.a, S.b
    local box = strokeBox({x = {a.x, b.x}, y = {a.y, b.y}}, a.w, a.h, CFG.MIN_SIZE)
    if not box then
        -- a click or a tiny drag: stay in the mode
        if app.clearSelection then pcall(app.clearSelection) end
        S.mode, S.a, S.b, S.upAt, S.seenUp = "ARMED", nil, nil, nil, true
        setStatus("too small: drag a rectangle on the page")
        return
    end
    -- what the Select Rectangle tool caught goes back to the page, then the earlier tool
    -- comes back BEFORE the picture is added (a tool change could drop the new selection)
    if app.clearSelection then pcall(app.clearSelection) end
    local pre, upAt = S.pre, S.upAt
    disarm(true)
    local okD, doc = pcall(app.getDocumentStructure)
    if okD and type(doc) == "table" and doc.currentPage ~= a.i and app.setCurrentPage then
        pcall(app.setCurrentPage, a.i)
    end
    local right = scaleLooksRight(a.s)
    local ok, msg, err = pcall(copyBox, box, a.i, a.w, a.h, a.s, pre, upAt)
    if not ok then setStatus("error: " .. tostring(msg))
    elseif msg then
        log(msg)
        local also = err == true and " (also on the clipboard)" or ""
        setStatus(right and ("copied" .. also .. ": drag it where you need it")
                  or "copied (layout check failed, see the log)")
    else setStatus("nothing copied: " .. tostring(err)) end
end

local function tick()
    if S.mode == "IDLE" then return end
    local now = H.now()
    -- time since the last look at the pen. Long when Xournal++ was held up, mostly by the page
    -- export made in advance (about 0.4 s): the timer cannot run then, but the pen goes on.
    local gap = now - (S.lastTick or now)
    S.lastTick = now
    local sp = scrollPos()
    local pen = H.readPen(sp)

    if S.mode == "ARMED" then
        local t = currentTool()
        if t ~= nil and t ~= rectTool() then      -- the user picked another tool: leave quietly
            disarm(false, "stopped (another tool was chosen)")
            return
        end
        if not pen then return end
        if not H.appActive() then return end      -- a drag in another program is not ours
        if not pen.down then
            S.seenUp = true
            if S.missed then
                -- the box Xournal++ drew for the missed drag holds a selection: let it go, or the
                -- next drag over the same spot would move the selected ink instead of drawing a box
                S.missed = nil
                if app.clearSelection then pcall(app.clearSelection) end
            end
        elseif S.seenUp and pen.inside and gap > CFG.LATE_MS then
            -- the press came while we could not look: where it began is unknown. A copy from
            -- here would start part way through the drag (0.11). Wait for the next drag.
            S.seenUp, S.missed = false, true
            log(string.format("drag began while Xournal++ was busy (no look at the pen for %d ms)", gap))
            setStatus("too quick (the page was still loading): drag again")
            H.toast("Too quick: the page was still loading.\nDrag again.", pen)
        elseif S.seenUp and pen.inside then
            local d = docAt(sp, pen, nil, S.model)
            if d then
                S.a, S.b, S.mode = d, d, "DRAG"
            end
        end

    elseif S.mode == "DRAG" then
        if pen and pen.down then
            local d = docAt(sp, pen, S.a.i, S.model)
            if d then S.b = d end
        else
            S.upAt, S.mode = now, "SETTLE"
        end

    elseif S.mode == "SETTLE" then
        if now - S.upAt >= CFG.SETTLE_MS then finish() end
    end
end

-- ------------------------------------------------------------------ timer
-- Runs fn once after ms milliseconds (errors go to the log).
function H.later(ms, fn)
    local b = bindings()
    if not b then return end
    b.GLib.timeout_add(b.GLib.PRIORITY_DEFAULT, ms, function()
        local ok, e = pcall(fn)
        if not ok then log("later: " .. tostring(e)) end
        return false
    end)
end

function H.ensureTimer()
    if timerLive then return end
    timerGen = timerGen + 1
    timerLive = true
    local gen, n = timerGen, 0
    B.GLib.timeout_add(B.GLib.PRIORITY_DEFAULT, CFG.TICK_MS, function()
        if gen ~= timerGen then return false end
        if S.mode ~= "IDLE" then
            local okT, e = pcall(tick)
            if not okT then
                log("tick error: " .. tostring(e))
                pcall(disarm, true, "stopped (error, see the log)")
            end
        end
        n = n + 1
        if panel and n % 6 == 0 then
            local okP, e = pcall(panel.poll)
            if not okP then
                log("panel error: " .. tostring(e))
                pcall(function() panel.win:destroy() end)
                panel = nil
            end
        end
        local stop = S.mode == "IDLE" and not panel
        if dirtyAt and (stop or H.now() - dirtyAt > 800) then
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

-- ------------------------------------------------------------------ floating window
local function openPanel()
    if panel then
        pcall(function() panel.win:present() end)
        return true
    end
    if not ui then
        local ok, err = H.attach()
        if not ok then log("window cannot open: " .. tostring(err)) return false end
    end
    local b, berr = bindings()
    if not b then log("window cannot open: " .. tostring(berr)) return false end
    local G = B.Gtk
    local win = G.Window {title = "Snapshot", resizable = false, accept_focus = false, focus_on_map = false,
                          skip_taskbar_hint = true, type_hint = B.Gdk.WindowTypeHint.UTILITY}
    win:set_transient_for(ui.top)
    local box = G.Box {orientation = G.Orientation.VERTICAL, spacing = 6, margin = 10}
    win:add(box)
    local p = {win = win}
    p.btn = G.ToggleButton.new_with_label("Snapshot")
    p.btn:set_size_request(170, 44)
    p.btn:set_tooltip_text("Click, then drag a rectangle on the page: a copy of that part appears on top of it, "
        .. "ready to drag (same as Ctrl+Alt+F8).\nClick again to leave without copying.")
    p.state = G.Label {label = "", xalign = 0, wrap = true, max_width_chars = 24}
    p.clear = G.CheckButton.new_with_label("Transparent background")
    p.clear:set_tooltip_text("Ticked: the copy has no background. The page colour around the writing is "
        .. "see-through, so the copy can lie on top of other things without hiding them.\n"
        .. "Not ticked: the copy is a solid rectangle, as it looks on the page.")
    p.clear:set_active(CFG.TRANSPARENT)
    p.shownClear = CFG.TRANSPARENT
    box:add(p.btn)
    box:add(p.clear)
    box:add(p.state)
    if CFG.PANEL_X >= 0 and CFG.PANEL_Y >= 0 then win:move(CFG.PANEL_X, CFG.PANEL_Y) end
    win:show_all()
    p.shownOn = false

    function p.poll()
        if not win:get_visible() then       -- closed with its X
            panel = nil
            return
        end
        local x, y = win:get_position()
        if type(x) == "number" and type(y) == "number" and (x ~= CFG.PANEL_X or y ~= CFG.PANEL_Y) then
            CFG.PANEL_X, CFG.PANEL_Y = x, y
            dirtyAt = H.now()
        end
        local a = p.btn:get_active()
        if a ~= p.shownOn then              -- the user clicked the button
            if a then arm() else disarm(true, "stopped") end
        end
        local c = p.clear:get_active()
        if c ~= p.shownClear then           -- the user ticked the box
            p.shownClear, CFG.TRANSPARENT = c, c
            dirtyAt = H.now()
        end
        local on = S.mode ~= "IDLE"
        if p.btn:get_active() ~= on then p.btn:set_active(on) end
        p.shownOn = on
        if S.status ~= p.stateText then
            p.state:set_label(S.status)
            p.stateText = S.status
        end
    end

    panel = p
    H.ensureTimer()
    return true
end

-- ------------------------------------------------------------------ menu callbacks
function snapshotRect()
    local ok, e = pcall(function()
        if S.mode == "IDLE" then arm() else disarm(true, "stopped") end
    end)
    if not ok then log("key error: " .. tostring(e)) end
end

function snapshotPanel()
    local ok, e = pcall(openPanel)
    if not ok then
        log("window error: " .. tostring(e))
        pcall(function() if panel then panel.win:destroy() end end)
        panel = nil
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
    app.registerUi({["menu"] = "Snapshot: drag a rectangle (on / off)", ["callback"] = "snapshotRect",
                    ["accelerator"] = accel("KEY_RECT")})
    app.registerUi({["menu"] = "Snapshot: show the floating window", ["callback"] = "snapshotPanel",
                    ["accelerator"] = accel("KEY_PANEL")})
    -- show the window by itself, once the main window exists (a few tries)
    if CFG.PANEL_AT_START and not rawget(_G, "SNAPSHOT_TEST") and bindings() then
        local tries = 0
        B.GLib.timeout_add(B.GLib.PRIORITY_DEFAULT, 1700, function()
            tries = tries + 1
            local ok = pcall(function()
                local okA, err = H.attach()
                if not okA then error(err) end
                openPanel()
            end)
            return not ok and tries < 6
        end)
    end
end

if rawget(_G, "SNAPSHOT_TEST") then
    SNAPSHOT_INTERNALS = {CFG = CFG, H = H, S = function() return S end,
                          strokeBox = strokeBox, pixelRect = pixelRect, exportWidth = exportWidth,
                          cropFile = cropFile, cropPixbuf = cropPixbuf, loadPage = loadPage, transparentCopy = transparentCopy, fadeTable = fadeTable,
                          backgroundColours = backgroundColours, pixbufLib = pixbufLib, validKey = validKey, copyBox = copyBox, scaleLooksRight = function(v) return scaleLooksRight(v) end, loadSettings = loadSettings,
                          saveSettings = saveSettings, arm = arm, disarm = disarm, tick = tick, docAt = docAt,
                          setUi = function(u) ui = u end, panel = function() return panel end}
end
