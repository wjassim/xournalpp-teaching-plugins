-- Tool dock plugin for Xournal++  (v0.7.4)
-- Author: Wissam Jassim (written with Claude), 2026-11-17.
-- Copyright (c) 2026 Wissam Jassim. MIT licence, see LICENSE in the repository root.
-- SPDX-License-Identifier: MIT
--
-- WHAT IT DOES
--   A small floating window with tool buttons (pen, laser pointer, select object, eraser ...)
--   and colour buttons. Place it anywhere over the page, so the pen never has to travel to the
--   top toolbar (with autozoom on, that trip slides the view).
--
-- HOW TO USE
--   Ctrl+Alt+F12 (or Plugin menu > "Tool dock: show / hide") shows or hides the dock.
--   Drag the dock by its grip (the dotted strip "⠿ Tools"). The dock has no Windows title bar.
--   Click a tool to switch to it, a colour to colour the current tool and anything selected.
--   The dot button opens the line thickness picker: 5 sizes, very thin to very thick. A click
--   sets the size of the current tool (pen, laser pointer, highlighter ...), as the toolbar does.
--   "+" opens the edit list: add or remove tools and colours, shape, buttons per row, size.
--   "⇄" switches the shape: horizontal, vertical, rectangle.
--   Hold a tool, colour or thickness button (long press) or right-click it to remove it.
--
-- HOW IT WORKS
--   The dock is a GTK window made with LuaGObject. One GLib timer runs only while the dock or the
--   edit list is shown and POLLS every button (a pressed toggle = a click, then it springs back).
--   SPEED (0.4): the buttons are asked only when a press STARTS on the dock. While the pen writes
--   on the page the dock asks nothing, however many buttons it has (each GTK call ~0.06 ms).
--   The edit list is asked every 100 ms, not at every tick.
--   Buttons can also run a Xournal++ command (zoom, undo, ruler ...): `action` in the catalogue,
--   `toggle` = an on / off command, its button is lit while it is on.
--   SHAPES (0.5): rectangle, ellipse, arrow, double arrow, axes, spline, ruler and shape recognizer
--   are DRAWING MODES of the pen (or highlighter) in Xournal++ 1.3, not tools: `draw` = the action
--   ("tool-draw-arrow" ...). Choosing Tool_drawArrow with select-tool only sets a number, the pen
--   still draws freehand (seen live, 0.4). A shape button switches to the pen when the tool is not
--   the pen / highlighter, then turns its mode on; again = off. The modes exclude each other. The pen
--   keeps its mode when another tool is chosen, so the Pen / Highlighter button turns any mode off.
--   NEVER connect a Lua handler to a signal (a canvas signal handler crashed Xournal++ once).
--   Facts checked in this build (1.3.8+dev): app.getActionState("tool-color") is ARGB (0xFF......);
--   app.changeToolColor on a tool without colour (select, eraser) raises "has no color capability",
--   with tool = "pen" it works.
--
-- SETTINGS
--   settings.txt next to this file, lines KEY=value (see CFG). The plugin writes it itself.
--   KEY_DOCK is read when Xournal++ starts: change it with Xournal++ closed (none = no key).
--   CUSTOM BUTTONS (0.7): edit list > "Add a custom button ..." lists every menu entry that has a
--   shortcut (and every Plugin menu entry): auto zoom on / off, snapshot, pen, undo, next page ...
--   Tap one: the dock gets a button that does what that shortcut does (it runs the menu entry
--   itself, no key press is faked). As many as you like. Settings: TOOLS holds custom1, custom2 ...,
--   CUSTOM1=<menu>|<entry>|<shortcut text> (the shortcut text only for the button's look).
--   The button shows an icon when the entry is known (magnifier = auto zoom, the tool's icon for a
--   tool ...), else the end of its shortcut ("F8"). Lit while the entry is on (a tick or radio
--   entry, or auto zoom's XOPP_AUTOZOOM_ON). The 0.6 per-button keys are gone (KEY_<button> lines
--   in an old settings.txt are ignored and dropped at the next save).
--   AUTO ZOOM (0.6): the "autozoom" button presses the autozoom plugin's menu entry "Auto zoom:
--   ON / OFF" (found once in the menus, ~150 ms, then kept); it is lit while autozoom publishes
--   XOPP_AUTOZOOM_ON=1 in the process environment (autozoom 0.13+; GLib.getenv, every 200 ms).

local CFG = {
    TOOLS = {"pen", "laserPen", "selectObject", "eraser"},     -- tool buttons, in order
    COLOURS = {0x000000, 0x1E5AE6, 0xE00000, 0x00A000},         -- colour buttons, in order (0xRRGGBB)
    SHAPE = "horizontal",       -- horizontal | vertical | rectangle
    PER_ROW = 4,                -- buttons per row in the rectangle shape (1 .. 12)
    SIZE = "medium",            -- small | medium | large
    SIZE_BUTTON = true,         -- the line thickness button (opens the 5-size picker)
    DOCK_AT_START = false,      -- show the dock when Xournal++ starts
    PANEL_X = -100000,          -- dock position (saved by itself; -100000 = not yet placed)
    PANEL_Y = -100000,          --   a monitor left of or above the main one gives negative places
    EDIT_X = -100000,           -- edit list position (saved by itself)
    EDIT_Y = -100000,
    EDIT_H = 0,                 -- edit list height after the user resized it (0 = natural height)
    LONG_MS = 600,              -- a press held this long is a long press (remove)
    TICK_MS = 30,               -- timer interval while shown
    LOG = true,                 -- write %TEMP%\tool-dock.log
    KEY_DOCK = "<Control><Alt>F12",
}

local SHAPES = {"horizontal", "vertical", "rectangle"}
local UNSET = -100000
local function hasPlace(x, y) return type(x) == "number" and type(y) == "number" and x > UNSET and y > UNSET end
local SIZES = {small = 28, medium = 40, large = 56}

-- Line thickness: the 5 sizes of Xournal++ (action "tool-size", app.C.ToolSize_<id>; value k - 1).
-- icon = Xournal++'s own toolbar icon (light / dark theme follow Xournal++); dot = the drawn dot
-- used when the icon is missing, its diameter as a part of the button size.
local LINE_SIZES = {
    {id = "veryThin",  label = "Very thin",  icon = "xopp-thickness-finer",   dot = 0.10},
    {id = "thin",      label = "Thin",       icon = "xopp-thickness-fine",    dot = 0.17},
    {id = "medium",    label = "Medium",     icon = "xopp-thickness-medium",  dot = 0.26},
    {id = "thick",     label = "Thick",      icon = "xopp-thickness-thick",   dot = 0.38},
    {id = "veryThick", label = "Very thick", icon = "xopp-thickness-thicker", dot = 0.52},
}
-- Tools with a size of their own. Xournal++ keeps one size per tool and gives it back when the
-- tool is chosen again (checked: pen thick, laser very thin, back to pen = thick). The picker sets
-- the size of the current tool when it is one of these; any other tool (select, hand, text ...)
-- has no size, then the picker sets the PEN's size ("tool-pen-size"), ready for the next stroke.
local SIZE_TOOLS = {"Tool_pen", "Tool_highlighter", "Tool_eraser", "Tool_laserPointerPen",
                    "Tool_laserPointerHighlighter", "Tool_drawRect", "Tool_drawEllipse", "Tool_drawArrow",
                    "Tool_drawDoubleArrow", "Tool_drawCoordinateSystem", "Tool_drawSpline"}
local function hasOwnSize(tool)
    if type(app) ~= "table" or type(app.C) ~= "table" or tool == nil then return false end
    for _, n in ipairs(SIZE_TOOLS) do if app.C[n] ~= nil and app.C[n] == tool then return true end end
    return false
end
local function dotPx(k, px) return math.max(3, math.floor(px * LINE_SIZES[k].dot + 0.5)) end

-- Every tool the dock can hold. const = name in app.C; colour = the tool takes a colour.
local CATALOGUE = {
    {id = "pen",              const = "Tool_pen",                     icon = "xopp-tool-pencil",      label = "Pen", colour = true},
    {id = "highlighter",      const = "Tool_highlighter",             icon = "xopp-tool-highlighter", label = "Highlighter", colour = true},
    {id = "laserPen",         const = "Tool_laserPointerPen",         icon = "xopp-laser-pointer",    label = "Laser pointer (pen)", colour = true},
    {id = "laserHighlighter", const = "Tool_laserPointerHighlighter", icon = "xopp-laser-pointer",    label = "Laser pointer (highlighter)", colour = true},
    {id = "eraser",           const = "Tool_eraser",                  icon = "xopp-tool-eraser",      label = "Eraser"},
    {id = "selectObject",     const = "Tool_selectObject",            icon = "xopp-object-select",    label = "Select object"},
    {id = "selectRect",       const = "Tool_selectRect",              icon = "xopp-select-rect",      label = "Select rectangle"},
    {id = "selectRegion",     const = "Tool_selectRegion",            icon = "xopp-select-lasso",     label = "Select region (lasso)"},
    {id = "selectRectAll",    const = "Tool_selectMultiLayerRect",    icon = "xopp-select-multilayer-rect",  label = "Select rectangle (all layers)"},
    {id = "selectRegionAll",  const = "Tool_selectMultiLayerRegion",  icon = "xopp-select-multilayer-lasso", label = "Select region (all layers)"},
    {id = "text",             const = "Tool_text",                    icon = "xopp-tool-text",        label = "Text", colour = true},
    {id = "image",            const = "Tool_image",                   icon = "xopp-tool-image",       label = "Image"},
    {id = "drawRect",         draw = "tool-draw-rectangle",           icon = "xopp-draw-rect",        label = "Rectangle", colour = true},
    {id = "drawEllipse",      draw = "tool-draw-ellipse",             icon = "xopp-draw-ellipse",     label = "Ellipse", colour = true},
    {id = "drawArrow",        draw = "tool-draw-arrow",               icon = "xopp-draw-arrow",       label = "Arrow", colour = true},
    {id = "drawDoubleArrow",  draw = "tool-draw-double-arrow",        icon = "xopp-draw-double-arrow", label = "Double arrow", colour = true},
    {id = "drawAxes",         draw = "tool-draw-coordinate-system",   icon = "xopp-draw-coordinate-system", label = "Axes (coordinate system)", colour = true},
    {id = "drawSpline",       draw = "tool-draw-spline",              icon = "xopp-draw-spline",      label = "Spline", colour = true},
    {id = "verticalSpace",    const = "Tool_verticalSpace",           icon = "xopp-vertical-space",   label = "Vertical space"},
    {id = "hand",             const = "Tool_hand",                    icon = "xopp-hand",             label = "Hand"},
    {id = "latex",            const = "Tool_latex",                   icon = "xopp-tool-math-tex",    label = "LaTeX", colour = true},
    {id = "link",             const = "Tool_link",                    icon = "xopp-tool-link",        label = "Link"},
    -- commands (no tool change): action = Xournal++ action name, toggle = on / off (lit while on).
    -- All checked in this build (1.3.8+dev). A zoom command takes effect just after the call.
    {id = "zoomIn",           action = "zoom-in",                     icon = "zoom-in-symbolic",       label = "Zoom in"},
    {id = "zoomOut",          action = "zoom-out",                    icon = "zoom-out-symbolic",      label = "Zoom out"},
    {id = "zoomFit",          action = "zoom-fit",                    icon = "zoom-fit-best-symbolic", label = "Zoom to fit"},
    {id = "zoom100",          action = "zoom-100",                    icon = "zoom-original-symbolic", label = "Zoom 100 %"},
    -- another plugin's menu entry (0.6): menu = its label, plugin = its folder, env = its ON flag
    {id = "autozoom",         menu = "Auto zoom: ON / OFF", plugin = "autozoom", env = "XOPP_AUTOZOOM_ON",
                              icon = "system-search-symbolic", label = "Auto zoom on / off"},
    {id = "undo",             action = "undo",                        icon = "xopp-edit-undo",         label = "Undo"},
    {id = "redo",             action = "redo",                        icon = "xopp-edit-redo",         label = "Redo"},
    {id = "ruler",            draw = "tool-draw-line", helper = true,               icon = "xopp-draw-line",         label = "Straight lines (ruler)"},
    {id = "shapeRecognizer",  draw = "tool-draw-shape-recognizer", helper = true,   icon = "xopp-shape-recognizer",  label = "Shape recognizer"},
    {id = "gridSnap",         action = "grid-snapping", toggle = true,              icon = "xopp-snapping-grid",     label = "Grid snapping"},
    {id = "rotationSnap",     action = "rotation-snapping", toggle = true,          icon = "xopp-snapping-rotation", label = "Rotation snapping"},
    {id = "setsquare",        action = "setsquare", toggle = true,                  icon = "xopp-setsquare",         label = "Set square"},
    {id = "compass",          action = "compass", toggle = true,                    icon = "xopp-compass",           label = "Compass"},
    {id = "newPage",          action = "new-page-after",              icon = "xopp-page-add",          label = "New page after this one"},
}
local BY_ID = {}
for _, e in ipairs(CATALOGUE) do BY_ID[e.id] = e end

-- Custom buttons (0.7): CUSTOM[n] = {group = top menu, label = entry, key = shortcut text or nil};
-- the dock id is "custom<n>". Labels are kept without the mnemonic "_".
local CUSTOM = {}
local MAX_CUSTOM = 40
local function customIndex(id)
    local n = type(id) == "string" and id:match("^custom(%d+)$")
    n = n and tonumber(n)
    if n and n >= 1 and n <= MAX_CUSTOM then return n end
end
local function plainLabel(s)            -- "_Pen" -> "Pen", "a__b" -> "a_b"
    local r = tostring(s or ""):gsub("__", "\1"):gsub("_", ""):gsub("\1", "_")
    return r
end
local function parseCustom(v)
    local g, l, k = tostring(v or ""):match("^(.-)|(.-)|(.*)$")
    if not g then g, l = tostring(v or ""):match("^(.-)|(.*)$") end
    if g and l and l ~= "" then return {group = g, label = l, key = (k and k ~= "") and k or nil} end
end
local function customText(c) return c.group .. "|" .. c.label .. "|" .. (c.key or "") end
-- Known entries get an icon (and auto zoom its ON flag); a tool or command of the catalogue with
-- the same name gets that one's icon.
local CUSTOM_LOOK = {
    ["auto zoom: on / off"] = {icon = "system-search-symbolic", env = "XOPP_AUTOZOOM_ON"},
    ["snapshot: drag a rectangle (on / off)"] = {icon = "camera-photo-symbolic"},
    ["next page (keep view)"] = {icon = "go-next-symbolic"},
    ["previous page (keep view)"] = {icon = "go-previous-symbolic"},
    ["next page"] = {icon = "go-down-symbolic"},
    ["previous page"] = {icon = "go-up-symbolic"},
    ["new page after"] = {icon = "xopp-page-add"},
}
-- Menu entries the edit list's tick boxes already give (better there: a shape switches to the pen
-- first, Pen / Highlighter turn any shape mode off). Hidden from the custom button list (0.7.1)
-- when that tick box exists in this build. Menu label (lower case, no "_") -> catalogue id.
local TICK_BOX_OF = {
    ["pen"] = "pen", ["highlighter"] = "highlighter", ["eraser"] = "eraser", ["text"] = "text",
    ["link"] = "link", ["latex"] = "latex", ["image"] = "image", ["hand tool"] = "hand",
    ["vertical space"] = "verticalSpace", ["select rectangle"] = "selectRect",
    ["select region"] = "selectRegion", ["select object"] = "selectObject",
    ["draw rectangle"] = "drawRect", ["draw ellipse"] = "drawEllipse", ["draw arrow"] = "drawArrow",
    ["draw double arrow"] = "drawDoubleArrow", ["draw coordinate system"] = "drawAxes",
    ["draw line"] = "ruler", ["draw spline"] = "drawSpline", ["shape recognizer"] = "shapeRecognizer",
    ["undo"] = "undo", ["redo"] = "redo", ["zoom in"] = "zoomIn", ["zoom out"] = "zoomOut",
    ["zoom to fit"] = "zoomFit", ["new page after"] = "newPage", ["auto zoom: on / off"] = "autozoom",
}
-- What a short text button shows: the end of the shortcut ("Ctrl+Alt+F8" -> "F8"), else the name.
local function customShort(c)
    if c.key then
        local k = c.key:match("%+(%+)$") or c.key:match("([^+]+)$") or c.key
        if #k <= 5 then return k end
    end
    return c.label:sub(1, 3)
end
-- The catalogue entry of a dock id; a custom button gets one made for it.
local function entryOf(id)
    if BY_ID[id] then return BY_ID[id] end
    local n = customIndex(id)
    local c = n and CUSTOM[n]
    if not c then return nil end
    local low = c.label:lower()
    local look = CUSTOM_LOOK[low] or {}
    local icon = look.icon
    if not icon then
        for _, e in ipairs(CATALOGUE) do if e.label:lower() == low then icon = e.icon break end end
    end
    local tip = c.label .. (c.key and ("  (" .. c.key .. ")") or "") .. "  [" .. c.group .. " menu]"
    return {id = id, custom = c, label = c.label, icon = icon, env = look.env, tip = tip, short = customShort(c)}
end

local function copyList(t) local r = {} for i, v in ipairs(t) do r[i] = v end return r end
local DEFAULTS = {}
for k, v in pairs(CFG) do DEFAULTS[k] = type(v) == "table" and copyList(v) or v end

local TEMP = os.getenv("TEMP") or os.getenv("TMPDIR") or "."
local SEP = package.config:sub(1, 1)
local LOGFILE = rawget(_G, "TOOLDOCK_LOG_FILE") or (TEMP .. SEP .. "tool-dock.log")

local function log(s)
    if not CFG.LOG then return end
    local f = io.open(LOGFILE, "a")
    if f then
        f:write(os.date("%H:%M:%S "), tostring(s), "\n")
        f:close()
    end
end

-- ------------------------------------------------------------------ catalogue + lists
local function catalogueEntry(id) return BY_ID[id] end

local pluginInstalled          -- defined with the settings path below
-- true when this build of Xournal++ knows the tool (app.C has its constant)
local function available(id)
    if customIndex(id) then return CUSTOM[customIndex(id)] ~= nil end
    local e = BY_ID[id]
    if e == nil or type(app) ~= "table" then return false end
    if e.menu then return pluginInstalled(e.plugin) end
    if e.action then return app.activateAction ~= nil end
    if e.draw then return app.changeActionState ~= nil and type(app.C) == "table" and app.C.Tool_pen ~= nil end
    return type(app.C) == "table" and app.C[e.const] ~= nil
end

local function parseTools(text)
    local r, seen = {}, {}
    for w in tostring(text or ""):gmatch("[^,%s]+") do
        local known = BY_ID[w] or customIndex(w)
        if known and not seen[w] then
            r[#r + 1] = w
            seen[w] = true
        elseif not known then
            log("settings: unknown tool '" .. w .. "' left out")
        end
    end
    return r
end

local function parseColours(text)
    local r, seen = {}, {}
    for w in tostring(text or ""):gmatch("[^,%s]+") do
        local hex = w:gsub("^#", "")
        local n = (#hex == 6 and hex:match("^%x+$")) and tonumber(hex, 16) or nil
        if n and not seen[n] then
            r[#r + 1] = n
            seen[n] = true
        elseif not n then
            log("settings: bad colour '" .. w .. "' left out")
        end
    end
    return r
end

local function colourText(n) return string.format("%06X", n & 0xFFFFFF) end

-- ------------------------------------------------------------------ settings file
local function settingsPath()
    local o = rawget(_G, "TOOLDOCK_SETTINGS_FILE")
    if type(o) == "string" then return o end
    local src = (debug and debug.getinfo) and debug.getinfo(1, "S").source or ""
    local dir = src:match("^@(.*)[/\\][^/\\]*$")
    if dir then return dir .. SEP .. "settings.txt" end
    return nil
end
local SETTINGS = settingsPath()

-- The plugins folder (the one that holds tool-dock).
local function pluginsDir()
    local o = rawget(_G, "TOOLDOCK_PLUGINS_DIR")
    if type(o) == "string" then return o end
    return SETTINGS and SETTINGS:match("^(.*)[/\\][^/\\]+[/\\][^/\\]*$")
end
local pluginCheck = {}
pluginInstalled = function(name)
    if pluginCheck[name] == nil then
        local dir = pluginsDir()
        local f = dir and io.open(dir .. SEP .. name .. SEP .. "plugin.ini", "r")
        if f then f:close() end
        pluginCheck[name] = f ~= nil
    end
    return pluginCheck[name]
end

local MODS = {control = true, ctrl = true, primary = true, alt = true, shift = true, super = true, meta = true}
local function validKey(v)
    if v:lower() == "none" then return true end
    local rest, mods = v, 0
    while true do
        local m, r = rest:match("^<(%a+)>(.*)$")
        if not m then break end
        if not MODS[m:lower()] then return false end
        rest, mods = r, mods + 1
    end
    return mods > 0 and rest:match("^[%w_]+$") ~= nil
end

local function settingCount() local n = 0 for _ in pairs(DEFAULTS) do n = n + 1 end return n end

local function resetDefaults()
    for k, v in pairs(DEFAULTS) do CFG[k] = type(v) == "table" and copyList(v) or v end
    for k in pairs(CUSTOM) do CUSTOM[k] = nil end
end

local function oneOf(v, list) for _, x in ipairs(list) do if x == v then return true end end return false end

-- Returns the number of known settings found in the file (nil = no file).
local function loadSettings()
    local f = SETTINGS and io.open(SETTINGS, "r")
    if not f then return nil end
    local seen = 0
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        local d = k and DEFAULTS[k]
        if d ~= nil then seen = seen + 1 end
        local cn = k and d == nil and customIndex("custom" .. (k:match("^CUSTOM(%d+)$") or "x"))
        if cn then
            CUSTOM[cn] = parseCustom(v)
            if not CUSTOM[cn] then log("settings: bad " .. k .. "=" .. v .. ", left out") end
        elseif k == "TOOLS" then
            CFG.TOOLS = parseTools(v)
        elseif k == "COLOURS" then
            CFG.COLOURS = parseColours(v)
        elseif k == "SHAPE" then
            if oneOf(v, SHAPES) then CFG.SHAPE = v else log("settings: bad SHAPE=" .. v .. ", default kept") end
        elseif k == "SIZE" then
            if SIZES[v] then CFG.SIZE = v else log("settings: bad SIZE=" .. v .. ", default kept") end
        elseif type(d) == "string" then
            if validKey(v) then CFG[k] = v else log("settings: bad shortcut " .. k .. "=" .. v .. ", default kept") end
        elseif type(d) == "boolean" then
            if v == "true" then CFG[k] = true elseif v == "false" then CFG[k] = false end
        elseif type(d) == "number" then
            local n = tonumber(v)
            if n and n == n then CFG[k] = math.floor(n) end
        end
    end
    f:close()
    CFG.PER_ROW = math.max(1, math.min(12, CFG.PER_ROW))
    CFG.LONG_MS = math.max(200, math.min(3000, CFG.LONG_MS))
    CFG.TICK_MS = math.max(10, math.min(200, CFG.TICK_MS))
    -- a custom button needs both its TOOLS place and its CUSTOMn line
    local inTools = {}
    for i = #CFG.TOOLS, 1, -1 do
        local n = customIndex(CFG.TOOLS[i])
        if n and not CUSTOM[n] then table.remove(CFG.TOOLS, i) elseif n then inTools[n] = true end
    end
    for n in pairs(CUSTOM) do if not inTools[n] then CUSTOM[n] = nil end end
    return seen
end

local function saveSettings()
    if not SETTINGS then return end
    local keys = {}
    for k in pairs(DEFAULTS) do keys[#keys + 1] = k end
    table.sort(keys)
    local f = io.open(SETTINGS, "w")
    if not f then log("cannot write " .. SETTINGS) return end
    f:write("# Tool dock settings. The plugin rewrites this file when the dock changes.\n")
    f:write("# TOOLS: " )
    local ids = {}
    for _, e in ipairs(CATALOGUE) do ids[#ids + 1] = e.id end
    f:write(table.concat(ids, " "), "\n")
    f:write("# COLOURS: RRGGBB, comma between. KEY_DOCK: e.g. <Control><Alt>F12 (none = no key), change it with Xournal++ closed.\n")
    f:write("# Custom buttons: TOOLS has custom1, custom2 ...; CUSTOM1=<menu>|<menu entry>|<its shortcut>.\n")
    f:write("#   Easier: the edit list (+) > Add a custom button ... (pick any menu entry with a shortcut).\n")
    for _, k in ipairs(keys) do
        local v = CFG[k]
        if k == "COLOURS" then
            local t = {}
            for i, c in ipairs(v) do t[i] = colourText(c) end
            v = table.concat(t, ",")
        elseif type(v) == "table" then
            v = table.concat(v, ",")
        end
        f:write(k, "=", tostring(v), "\n")
    end
    for n = 1, MAX_CUSTOM do
        if CUSTOM[n] then f:write("CUSTOM", n, "=", customText(CUSTOM[n]), "\n") end
    end
    f:close()
end

-- ------------------------------------------------------------------ layout
-- Places the buttons. Order: grip, tools, thickness button, a line, colours, "+", shape button.
-- The line only when there are tools (or the thickness button) AND colours. Rectangle: the grip
-- has the top row, tools wrap every perRow, the line has its own row, colours start a new row
-- and wrap, "+" and the shape button share the last row. opts = {grip = bool, size = bool}.
local function layoutCells(nTools, nColours, shape, perRow, opts)
    opts = opts or {}
    local cells = {}
    local function add(kind, index, row, col, span)
        cells[#cells + 1] = {kind = kind, index = index, row = row, col = col, span = span or 1}
    end
    local nT = nTools + (opts.size and 1 or 0)
    local function toolKind(i) return i <= nTools and "tool" or "size" end
    local seq = {}
    for i = 1, nT do seq[#seq + 1] = {toolKind(i), i <= nTools and i or nil} end
    if nT > 0 and nColours > 0 then seq[#seq + 1] = {"line"} end
    for i = 1, nColours do seq[#seq + 1] = {"colour", i} end
    seq[#seq + 1] = {"plus"}
    seq[#seq + 1] = {"shape"}
    local g = opts.grip and 1 or 0
    if shape == "horizontal" then
        if g == 1 then add("grip", nil, 0, 0) end
        for i, s in ipairs(seq) do add(s[1], s[2], 0, i - 1 + g) end
    elseif shape == "vertical" then
        if g == 1 then add("grip", nil, 0, 0) end
        for i, s in ipairs(seq) do add(s[1], s[2], i - 1 + g, 0) end
    else
        perRow = math.max(1, perRow or 4)
        local row = 0
        if g == 1 then
            add("grip", nil, 0, 0, perRow)
            row = 1
        end
        local function block(kind, n, kindOf)
            for i = 1, n do
                local k = kindOf and kindOf(i) or kind
                add(k, k == kind and i or nil, row + (i - 1) // perRow, (i - 1) % perRow)
            end
            if n > 0 then row = row + (n - 1) // perRow + 1 end
        end
        block("tool", nT, toolKind)
        if nT > 0 and nColours > 0 then
            add("line", nil, row, 0, perRow)
            row = row + 1
        end
        block("colour", nColours)
        if perRow >= 2 then
            add("plus", nil, row, 0)
            add("shape", nil, row, 1)
        else
            add("plus", nil, row, 0)
            add("shape", nil, row + 1, 0)
        end
    end
    return cells
end

-- ------------------------------------------------------------------ press watch
-- Called every tick for one button with what the poll sees: held = the button is pressed down
-- now (GTK state ACTIVE), right = the right mouse button is down with the pointer over it.
-- Returns "long" once when held LONG_MS, "right" once per right press, else nil.
-- st.consumed = the press already did something: its release must not count as a click.
local function pressWatch(st, held, right, now)
    local res
    if held then
        if not st.since then
            st.since, st.longDone = now, false
        elseif not st.longDone and now - st.since >= CFG.LONG_MS then
            st.longDone, st.consumed = true, true
            res = "long"
        end
    else
        if st.since and not st.longDone then st.consumed = false end
        if not st.since then st.consumed = false end
        st.since = nil
        if st.longDone then st.longDone = false end
    end
    if right then
        if not st.rightDown then
            st.rightDown = true
            res = "right"
        end
    else
        st.rightDown = false
    end
    return res
end

-- Right mouse button: counts only on the press itself (down now, up the tick before) and only
-- when the pointer is on the dock and no other window lies over it. A right-drag that starts on
-- the page and crosses the dock, or a press on a window covering the dock, never counts.
local function rightEdge(st, down, overDock)
    local edge = down and not st.was
    st.was = down
    return edge and overDock
end

-- ------------------------------------------------------------------ GTK helpers
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

local dock, edit, ask, pick = nil, nil, nil, nil   -- the windows (nil = not shown); pick = thickness picker
local cuPick = nil                                  -- the custom button list (opened from the edit list)
local timerLive, timerGen, dirtyAt, busy = false, 0, nil, false
local pressInput = nil                    -- test hook: function(buttonName) -> held, right
local gripInput = nil                     -- test hook: function() -> held, button1Down, screenX, screenY
local pointerInput = nil                  -- test hook: function() -> x, y (dock window), button1, button3

local function nowMs() return B.GLib.get_monotonic_time() / 1000 end
local function markDirty() dirtyAt = B and nowMs() or 0 end

-- LuaGObject gives flags either as a table of names or as a number.
local function flagSet(v, name, bit)
    if type(v) == "table" then return v[name] == true end
    if type(v) == "number" then return (v & bit) ~= 0 end
    return false
end

local function indexOf(list, v) for i, x in ipairs(list) do if x == v then return i end end end
local function esc(t) return (tostring(t):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end

-- The Xournal++ main window: the toplevel holding the page canvas "GtkXournal".
local function mainWindow()
    local G = B.Gtk
    local function has(w, depth)
        if depth > 40 then return false end
        if w:get_name() == "GtkXournal" then return true end
        if G.Container:is_type_of(w) then
            for _, k in ipairs(w:get_children()) do if has(k, depth + 1) then return true end end
        end
        return false
    end
    for _, t in ipairs(G.Window.list_toplevels()) do
        local ours = (dock and t == dock.win) or (edit and t == edit.win) or (ask and t == ask.win)
                     or (pick and t == pick.win)
        if not ours and t:get_visible() then
            local ok, r = pcall(has, t, 0)
            if ok and r then return t end
        end
    end
end

-- The work area (screen minus task bar) of the monitor at x, y (or the main monitor). nil if GTK cannot tell.
local function workArea(x, y)
    local fake = rawget(_G, "TOOLDOCK_WORKAREA")         -- tests: {x =, y =, width =, height =}
    if type(fake) == "table" then return fake end
    local ok, r = pcall(function()
        local d = B.Gdk.Display.get_default()
        local m = (x and y) and d:get_monitor_at_point(x, y) or d:get_primary_monitor() or d:get_monitor(0)
        return m:get_workarea()
    end)
    if ok and r and r.width and r.width > 0 then return r end
    if not ok then log("work area unknown: " .. tostring(r)) end
end

-- A saved place from a bigger or second screen can be off this screen: pull the window back inside.
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
        log(string.format("window moved back on screen: %d,%d -> %d,%d", x, y, nx, ny))
    end
end

-- Wayland lets no app place its own windows or read where the pointer is on the screen: the dock
-- cannot be dragged and its saved place is ignored. Under XWayland (GDK_BACKEND=x11) all works.
local waylandSaid = false
local function checkWayland()
    if waylandSaid then return end
    waylandSaid = true
    local ok, name = pcall(function() return B.Gdk.Display.get_default():get_name() end)
    if ok and type(name) == "string" and name:lower():find("wayland", 1, true) then
        log("Wayland display (" .. name .. "): windows cannot be placed or dragged here. Start Xournal++ with"
            .. " GDK_BACKEND=x11 (e.g. GDK_BACKEND=x11 xournalpp) for a dock you can move.")
    end
end

-- The natural size of a window (what it asks for), or nil.
local function naturalSize(win)
    local ok, w, h = pcall(function()
        local _, nat = win:get_preferred_size()
        return nat.width, nat.height
    end)
    if ok and type(w) == "number" and w > 0 and type(h) == "number" and h > 0 then return w, h end
end

local function utilityWindow(title, decorated)
    local G = B.Gtk
    return G.Window {title = title, resizable = false, decorated = decorated, accept_focus = false,
                     focus_on_map = false, skip_taskbar_hint = true, type_hint = B.Gdk.WindowTypeHint.UTILITY}
end

-- ------------------------------------------------------------------ look (CSS)
local provider = nil
local function applyCss()
    local px = SIZES[CFG.SIZE]
    local sw = math.floor(px * 0.55)
    local parts = {
        "button.td-btn { padding: 2px; min-width: 0; min-height: 0; }",
        "button.td-on { box-shadow: inset 0 0 0 2px #1E90FF; background-image: none; background-color: rgba(30,144,255,0.20); }",
        string.format(".td-swatch { min-width: %dpx; min-height: %dpx; border-radius: %dpx; border: 1px solid alpha(currentColor, 0.45); }",
                      sw, sw, sw // 2),
        ".td-swatch-small { min-width: 18px; min-height: 18px; border-radius: 9px; border: 1px solid alpha(currentColor, 0.45); }",
        -- no Windows title bar on the dock and the picker: a thin border of their own
        "window.td-frame { border: 1px solid alpha(currentColor, 0.45); }",
        "button.td-grip { padding: 0; min-width: 0; min-height: 0; background-image: none;"
            .. " background-color: alpha(currentColor, 0.10); border-radius: 3px; }",
        ".td-dot { background-color: currentColor; }",       -- the text colour: seen on light and dark themes
    }
    for k = 1, #LINE_SIZES do
        local d = dotPx(k, px)
        parts[#parts + 1] = string.format(".td-dot%d { min-width: %dpx; min-height: %dpx; border-radius: %dpx; }",
                                          k, d, d, d // 2 + 1)
    end
    for _, c in ipairs(CFG.COLOURS) do
        parts[#parts + 1] = string.format("#td_sw_%s { background-color: #%s; }", colourText(c), colourText(c))
    end
    if not provider then
        provider = B.Gtk.CssProvider()
        B.Gtk.StyleContext.add_provider_for_screen(B.Gdk.Screen.get_default(), provider, 800)
    end
    -- 0.7.4: the dock never takes the keyboard, so GTK always draws it as a window in the
    -- background (":backdrop"), which greys text and one-colour icons (Adwaita-dark #919190), while
    -- Xournal++'s own colour icons stay white. Buttons keep the normal text colour instead.
    -- @theme_fg_color is the theme's own name for it (light and dark); a theme without that
    -- name makes the line fail, so then the rest is loaded without it.
    local css = table.concat(parts, "\n")
    local okL, res = pcall(function()
        return provider:load_from_data(css .. "\nbutton.td-btn:backdrop { color: @theme_fg_color; }")
    end)
    if not okL or res == false then provider:load_from_data(css) end
end

local function setOn(w, on)
    local ctx = w:get_style_context()
    if on then ctx:add_class("td-on") else ctx:remove_class("td-on") end
end

-- ------------------------------------------------------------------ actions
-- Tool and colour now in Xournal++. A tool without colour (select, eraser, hand): the pen's colour.
local function currentState()
    local tool, colour
    pcall(function() tool = app.getActionState("select-tool") end)
    local e
    for _, x in ipairs(CATALOGUE) do
        if x.const and app.C[x.const] ~= nil and app.C[x.const] == tool then e = x break end
    end
    if e and e.colour then
        pcall(function() local c = app.getActionState("tool-color") if type(c) == "number" then colour = c & 0xFFFFFF end end)
    else
        pcall(function() local c = app.getToolInfo("pen").color if type(c) == "number" then colour = c & 0xFFFFFF end end)
    end
    local size      -- 1 .. 5, nil = unknown; the pen's size when the tool has no size
    pcall(function()
        local s = app.getActionState(hasOwnSize(tool) and "tool-size" or "tool-pen-size")
        if type(s) == "number" and s >= 0 and s < #LINE_SIZES then size = math.floor(s) + 1 end
    end)
    return tool, colour, size
end

-- Line thickness k (1 .. 5) for the current tool, as the toolbar's size buttons do it.
local function useSize(k)
    local v = (type(app.C) == "table" and app.C["ToolSize_" .. LINE_SIZES[k].id]) or (k - 1)
    local tool
    pcall(function() tool = app.getActionState("select-tool") end)
    local action = hasOwnSize(tool) and "tool-size" or "tool-pen-size"
    local ok, err = pcall(app.changeActionState, action, v)
    if not ok then log("size " .. LINE_SIZES[k].id .. " failed: " .. tostring(err)) end
end

local function setDot(box, k)
    local ctx = box:get_style_context()
    for i = 1, #LINE_SIZES do ctx:remove_class("td-dot" .. i) end
    ctx:add_class("td-dot" .. (k or 3))
end

-- Another plugin's menu entry, found by its label in the menus (once; kept). Returns nil or why not.
local menuItems = {}
local function findMenuItem(label)
    local G = B.Gtk
    local found = nil
    local function walk(x, d)
        if d > 60 or found then return end
        if G.MenuItem:is_type_of(x) then
            local okL, l = pcall(function() return x:get_label() end)
            if okL and l == label then found = x return end
            local sub = x:get_submenu()
            if sub then walk(sub, d + 1) end
        end
        if G.Container:is_type_of(x) then
            for _, c in ipairs(x:get_children()) do walk(c, d + 1) end
        end
    end
    for _, t in ipairs(G.Window.list_toplevels()) do
        local ours = (dock and t == dock.win) or (edit and t == edit.win) or (ask and t == ask.win)
                     or (pick and t == pick.win) or (cuPick and t == cuPick.win)
        if not ours then pcall(walk, t, 0) end
        if found then break end
    end
    return found
end
local function activateMenu(label)
    if not bindings() then return "no LuaGObject" end
    for _ = 1, 2 do
        local item = menuItems[label]
        if not item then
            item = findMenuItem(label)
            if not item then return "menu entry '" .. label .. "' not found (plugin off?)" end
            menuItems[label] = item
        end
        if pcall(function() item:activate() end) then return nil end
        menuItems[label] = nil            -- gone (menus rebuilt): look again once
    end
    return "menu entry '" .. label .. "' did not run"
end

-- ------------------------------------------------------------------ custom buttons: the menus
-- The main window's menu bar holds every entry (Xournal++'s own and the Plugin menu), each with
-- its shortcut in an AccelLabel (checked live, 1.3.8+dev: get_accel gives key + modifiers).
local function menuBarItems()
    if not bindings() then return {} end
    local G = B.Gtk
    local bar
    local function walk(x, d)
        if bar or d > 30 then return end
        if G.MenuBar:is_type_of(x) then bar = x return end
        if G.Container:is_type_of(x) then for _, c in ipairs(x:get_children()) do walk(c, d + 1) end end
    end
    for _, t in ipairs(G.Window.list_toplevels()) do
        local ours = (dock and t == dock.win) or (edit and t == edit.win) or (ask and t == ask.win)
                     or (pick and t == pick.win) or (cuPick and t == cuPick.win)
        if not ours and t:get_visible() then pcall(walk, t, 0) end
        if bar then break end
    end
    local r = {}
    if bar then
        for _, x in ipairs(bar:get_children()) do if G.MenuItem:is_type_of(x) then r[#r + 1] = x end end
    end
    return r
end

-- "Ctrl+Alt+F8" for a menu item with a shortcut, nil without.
local function accelText(mi)
    local G = B.Gtk
    local found
    local function find(w, d)
        if found or d > 4 then return end
        if G.AccelLabel:is_type_of(w) then
            local ok, k, m = pcall(function() return w:get_accel() end)
            if ok and type(k) == "number" and k ~= 0 then
                local okL, lab = pcall(G.accelerator_get_label, k, m)
                if okL and type(lab) == "string" and lab ~= "" then found = lab end
            end
            return
        end
        if G.Container:is_type_of(w) then for _, c in ipairs(w:get_children()) do find(c, d + 1) end end
    end
    pcall(find, mi, 0)
    return found
end

local function isPluginMenu(group) return group:lower():match("^plugin") ~= nil end

-- Every entry the custom button list offers: entries with a shortcut, and every Plugin menu
-- entry; in menu order, {group, label, key}. The tool dock's own entries are left out.
local function listMenuEntries()
    if not bindings() then return {}, 0 end
    local G = B.Gtk
    local r, seen, hidden = {}, {}, 0
    local function walk(menu, group, d)
        if d > 8 then return end
        for _, x in ipairs(menu:get_children()) do
            if G.MenuItem:is_type_of(x) and not G.SeparatorMenuItem:is_type_of(x) then
                local sub = x:get_submenu()
                local lab = plainLabel(x:get_label())
                if sub then
                    walk(sub, group, d + 1)
                elseif lab ~= "" and not lab:match("^Tool dock") then
                    local key = accelText(x)
                    local id = group .. "|" .. lab
                    local tick = TICK_BOX_OF[lab:lower()]
                    if (key or isPluginMenu(group)) and not seen[id] then
                        seen[id] = true
                        if tick and available(tick) then
                            hidden = hidden + 1
                        else
                            r[#r + 1] = {group = group, label = lab, key = key}
                        end
                    end
                end
            end
        end
    end
    for _, top in ipairs(menuBarItems()) do
        local sub = top:get_submenu()
        if sub then pcall(walk, sub, plainLabel(top:get_label()), 1) end
    end
    return r, hidden
end

local function findCustomItem(c)
    local G = B.Gtk
    local found
    local function walk(menu, d)
        if found or d > 8 then return end
        for _, x in ipairs(menu:get_children()) do
            if found then return end
            if G.MenuItem:is_type_of(x) then
                local sub = x:get_submenu()
                if sub then walk(sub, d + 1)
                elseif plainLabel(x:get_label()) == c.label then found = x end
            end
        end
    end
    for _, top in ipairs(menuBarItems()) do
        if plainLabel(top:get_label()) == c.group then
            local sub = top:get_submenu()
            if sub then pcall(walk, sub, 1) end
        end
        if found then break end
    end
    return found
end

local customItems = {}        -- n -> {item, c}: the menu item, kept (looked up again when gone)
local customMiss = {}         -- n -> time of the last failed look (looked for again after 5 s)
local function customItem(n, fresh)
    local c = CUSTOM[n]
    if not c then return nil end
    local it = customItems[n]
    if it and it.c == c and not fresh then return it.item end
    local now = nowMs()
    if not fresh and customMiss[n] and now - customMiss[n] < 5000 then return nil end
    local item = findCustomItem(c)
    if item then
        customItems[n], customMiss[n] = {item = item, c = c}, nil
    else
        customItems[n], customMiss[n] = nil, now
    end
    return item
end

-- Runs the menu entry of custom button n (what its shortcut does).
local function runCustom(n)
    local c = CUSTOM[n]
    if not c or not bindings() then return end
    for try = 1, 2 do
        local item = customItem(n, try == 2)
        if not item then break end
        if pcall(function() item:activate() end) then return end
    end
    log("custom button '" .. c.label .. "' (" .. c.group .. " menu): menu entry not found")
end

-- On / off of a custom button: auto zoom's ON flag, or a tick / radio entry that is on.
local function customOn(e, n)
    if e.env then
        local ok, v = pcall(function() return B.GLib.getenv(e.env) == "1" end)
        return ok and v
    end
    local item = customItem(n)
    if item and B.Gtk.CheckMenuItem:is_type_of(item) then
        local ok, v = pcall(function() return item:get_active() end)
        return ok and v == true
    end
    return false
end

local function useTool(id)
    local cn = customIndex(id)
    if cn then runCustom(cn) return end
    local e = BY_ID[id]
    if e.menu then
        local why = activateMenu(e.menu)
        if why then log("button " .. id .. ": " .. why) end
        return
    end
    if e.action then
        local okA, errA = pcall(app.activateAction, e.action)
        if not okA then log("command " .. id .. " failed: " .. tostring(errA)) end
        return
    end
    if e.draw then
        local tool
        pcall(function() tool = app.getActionState("select-tool") end)
        local pen, hl = app.C.Tool_pen, app.C.Tool_highlighter
        local switched = false
        if tool ~= pen and (hl == nil or tool ~= hl) then
            local okP, errP = pcall(app.changeActionState, "select-tool", pen)
            if not okP then log("shape " .. id .. ": pen failed: " .. tostring(errP)) return end
            switched = true
        end
        local on = false
        pcall(function() on = app.getActionState(e.draw) == true end)
        -- just switched to the pen: on (the pen may still have this mode: keep it); else on / off
        local want = switched or not on
        if want ~= on then
            local okD, errD = pcall(app.changeActionState, e.draw, want)
            if not okD then log("shape " .. id .. " failed: " .. tostring(errD)) end
        end
        return
    end
    local ok, err = pcall(app.changeActionState, "select-tool", app.C[e.const])
    if not ok then log("tool " .. id .. " failed: " .. tostring(err)) end
    if id == "pen" or id == "highlighter" then       -- Pen / Highlighter = freehand: any drawing mode off
        for _, x in ipairs(CATALOGUE) do
            if x.draw then
                local okS, v = pcall(app.getActionState, x.draw)
                if okS and v == true then pcall(app.changeActionState, x.draw, false) end
            end
        end
    end
end

-- Colours the current tool and anything selected. A tool without colour raises an error in
-- Xournal++: then the pen gets the colour (and the selection still does).
local function useColour(c)
    local ok, err = pcall(app.changeToolColor, {color = c, selection = true})
    if not ok then
        local ok2, err2 = pcall(app.changeToolColor, {color = c, tool = "pen", selection = true})
        if not ok2 then log("colour " .. colourText(c) .. " failed: " .. tostring(err) .. " / " .. tostring(err2)) end
    end
end

local function chooseColour()
    local hook = rawget(_G, "TOOLDOCK_CHOOSE_COLOUR")
    if type(hook) == "function" then return hook() end
    local G = B.Gtk
    local dlg = G.ColorChooserDialog {title = "Add a colour", use_alpha = false}
    if edit then dlg:set_transient_for(edit.win) end
    local r = dlg:run()
    local c
    if r == -5 or r == G.ResponseType.OK or r == "OK" then
        local rgba = dlg.rgba
        local function ch(v) return math.max(0, math.min(255, math.floor(v * 255 + 0.5))) end
        c = (ch(rgba.red) << 16) | (ch(rgba.green) << 8) | ch(rgba.blue)
    end
    dlg:destroy()
    return c
end

-- ------------------------------------------------------------------ dock window
local fillEdit, openEdit   -- defined below

local function visibleTools()
    local r = {}
    for _, id in ipairs(CFG.TOOLS) do
        if available(id) then r[#r + 1] = id else log("tool " .. id .. " is not in this Xournal++ build, left out") end
    end
    return r
end

local function newToggle(name, tip)
    local G = B.Gtk
    local b = G.ToggleButton()
    b:set_name(name)
    b:set_relief(G.ReliefStyle.NONE)
    b:set_focus_on_click(false)
    b:get_style_context():add_class("td-btn")
    if tip then b:set_tooltip_text(tip) end
    return b
end

local function toolButton(e, px)
    local G = B.Gtk
    local b = newToggle("td_tool_" .. e.id, e.tip or e.label)
    b:set_size_request(px, px)
    local okI, has = pcall(function() return e.icon ~= nil and G.IconTheme.get_default():has_icon(e.icon) end)
    if okI and has then
        local img = G.Image.new_from_icon_name(e.icon, G.IconSize.LARGE_TOOLBAR)
        img:set_pixel_size(math.floor(px * 0.62))
        b:add(img)
    elseif e.custom then                 -- no icon: the end of its shortcut ("F8")
        local t = e.short
        local f = #t <= 2 and 0.36 or (#t <= 3 and 0.30 or 0.24)
        local l = G.Label {}
        l:set_markup(string.format('<span size="%d" weight="bold">%s</span>', math.floor(px * f * 1024), esc(t)))
        b:add(l)
    else
        b:add(G.Label {label = e.label:sub(1, 3)})
    end
    return b
end

local function colourButton(c, index, px)
    local G = B.Gtk
    local b = newToggle("td_colour_" .. index, "#" .. colourText(c))
    b:set_size_request(px, px)
    local sw = G.Box {halign = G.Align.CENTER, valign = G.Align.CENTER}
    sw:set_name("td_sw_" .. colourText(c))
    sw:get_style_context():add_class("td-swatch")
    b:add(sw)
    return b
end

local function textButton(name, text, tip, px)
    local b = newToggle(name, tip)
    b:set_size_request(px, px)
    local l = B.Gtk.Label {}
    l:set_markup(string.format('<span size="%d" weight="bold">%s</span>', math.floor(px * 0.36 * 1024), text))
    b:add(l)
    return b
end

-- A dot of line thickness k in a box (the thickness button and the picker show these).
local function dotBox(k, name)
    local G = B.Gtk
    local d = G.Box {halign = G.Align.CENTER, valign = G.Align.CENTER}
    if name then d:set_name(name) end
    d:get_style_context():add_class("td-dot")
    setDot(d, k)
    return d
end

-- What a size button shows: Xournal++'s thickness icon k, or a dot when the icon is missing.
local function sizeShow(k, px, name)
    local G = B.Gtk
    local okI, has = pcall(function() return G.IconTheme.get_default():has_icon(LINE_SIZES[k].icon) end)
    if okI and has then
        local img = G.Image.new_from_icon_name(LINE_SIZES[k].icon, G.IconSize.LARGE_TOOLBAR)
        img:set_pixel_size(math.floor(px * 0.62))
        if name then img:set_name(name .. "_icon") end
        return {widget = img, icon = true, px = px}
    end
    return {widget = dotBox(k, name and (name .. "_dot")), icon = false, px = px}
end

local function setShow(show, k)
    k = k or 3
    if show.icon then
        show.widget:set_from_icon_name(LINE_SIZES[k].icon, B.Gtk.IconSize.LARGE_TOOLBAR)
        show.widget:set_pixel_size(math.floor(show.px * 0.62))
    else
        setDot(show.widget, k)
    end
end

-- The grip: press on it and drag to move the dock (polled, no signal handler; see pollGrip).
-- Horizontal dock: a narrow strip at the left with the dots. Vertical: dots over "Tools".
-- Rectangle: a strip across the top, "⠿ Tools".
local function gripButton(px, shape)
    local G = B.Gtk
    local b = newToggle("td_grip", "Drag here to move the dock")
    local ctx = b:get_style_context()
    ctx:remove_class("td-btn")
    ctx:add_class("td-grip")
    local dots = math.floor(px * 0.36 * 1024)
    local small = math.floor(math.max(7, px * 0.22) * 1024)
    local l = G.Label {justify = G.Justification.CENTER}
    if shape == "horizontal" then
        b:set_size_request(math.floor(px * 0.45), px)
        l:set_markup(string.format('<span size="%d">\u{283F}</span>', dots))
    elseif shape == "vertical" then
        b:set_size_request(px, math.floor(px * 0.70))
        l:set_markup(string.format('<span size="%d">\u{283F}</span>\n<span size="%d">Tools</span>', dots, small))
    else
        b:set_size_request(px, math.floor(px * 0.50))
        l:set_markup(string.format('<span size="%d">\u{283F}</span>  <span size="%d">Tools</span>', dots, small))
    end
    b:add(l)
    return b
end

local function sizeButton(px)
    local b = newToggle("td_size", "Line thickness of the current tool (the pen's, for select, hand, text ...): opens the 5 sizes")
    b:set_size_request(px, px)
    local show = sizeShow(3, px, "td_size")
    b:add(show.widget)
    return b, show
end

local function closePick()
    if pick then pcall(function() pick.win:destroy() end) end
    pick = nil
end

local function fillDock()
    local G = B.Gtk
    closePick()
    if dock.grid then dock.grid:destroy() end
    applyCss()
    local px = SIZES[CFG.SIZE]
    local grid = G.Grid {row_spacing = 2, column_spacing = 2, margin = 4}
    local tools = visibleTools()
    dock.buttons, dock.grip, dock.sizeShow = {}, nil, nil
    local opts = {grip = true, size = CFG.SIZE_BUTTON}
    for _, c in ipairs(layoutCells(#tools, #CFG.COLOURS, CFG.SHAPE, CFG.PER_ROW, opts)) do
        local w, item
        if c.kind == "grip" then
            w = gripButton(px, CFG.SHAPE)
            dock.grip = {widget = w}
        elseif c.kind == "size" then
            local d
            w, d = sizeButton(px)
            dock.sizeShow = d
            item = {kind = "size"}
        elseif c.kind == "tool" then
            local e = entryOf(tools[c.index])
            w = toolButton(e, px)
            item = {kind = "tool", id = tools[c.index], entry = e}
        elseif c.kind == "colour" then
            w = colourButton(CFG.COLOURS[c.index], c.index, px)
            item = {kind = "colour", colour = CFG.COLOURS[c.index]}
        elseif c.kind == "plus" then
            w = textButton("td_plus", "+", "Edit the dock: tools, colours, shape, size", px)
            item = {kind = "plus"}
        elseif c.kind == "shape" then
            w = textButton("td_shape", "\u{21C4}", "Shape: horizontal, vertical, rectangle", px)
            item = {kind = "shape"}
        else
            local o = CFG.SHAPE == "horizontal" and G.Orientation.VERTICAL or G.Orientation.HORIZONTAL
            w = G.Separator {orientation = o, margin = 3}
        end
        grid:attach(w, c.col, c.row, c.span, 1)
        if item then
            item.widget, item.st = w, {}
            dock.buttons[#dock.buttons + 1] = item
        end
    end
    dock.win:add(grid)
    dock.grid = grid
    grid:show_all()
    dock.win:resize(1, 1)
    dock.shownTool, dock.shownColour, dock.shownSize = false, false, false
end

local function rebuildDock()
    if dock then fillDock() end
    if edit then fillEdit() end
end

local function closeAsk()
    if ask then pcall(function() ask.win:destroy() end) end
    ask = nil
end

local function closeDock()
    closeAsk()
    closePick()
    if dock then
        pcall(function() dock.win:destroy() end)
        dock = nil
    end
end

local function closeCuPick()
    if cuPick then pcall(function() cuPick.win:destroy() end) end
    cuPick = nil
end
local function closeEdit()
    closeCuPick()
    if edit then
        pcall(function() edit.win:destroy() end)
        edit = nil
    end
end

local function openAsk(it)
    closeAsk()
    local G = B.Gtk
    local what = it.kind == "tool" and (entryOf(it.id) or {label = it.id}).label
                 or it.kind == "size" and "the line thickness button"
                 or ("the colour #" .. colourText(it.colour))
    local win = utilityWindow("Remove?", true)
    win:set_transient_for(dock.win)
    local box = G.Box {orientation = G.Orientation.HORIZONTAL, spacing = 8, margin = 8}
    box:add(G.Label {label = "Remove " .. what .. " from the dock?"})
    local yes = G.ToggleButton.new_with_label("Remove")
    yes:set_name("td_rm_yes")
    local no = G.ToggleButton.new_with_label("Cancel")
    no:set_name("td_rm_no")
    box:add(yes)
    box:add(no)
    local frame = G.Frame {}
    frame:add(box)
    win:add(frame)
    local x, y = dock.win:get_position()
    local _, h = dock.win:get_size()
    if type(x) == "number" and type(h) == "number" then win:move(x, y + h + 40) end
    win:show_all()
    keepOnScreen(win)
    ask = {win = win, yes = yes, no = no, item = it}
end

local function removeItem(it)
    if it.kind == "tool" then
        local i = indexOf(CFG.TOOLS, it.id)
        if i then table.remove(CFG.TOOLS, i) end
        local n = customIndex(it.id)
        if n then CUSTOM[n], customItems[n], customMiss[n] = nil, nil, nil end
        log("removed tool " .. it.id)
    elseif it.kind == "colour" then
        local i = indexOf(CFG.COLOURS, it.colour)
        if i then table.remove(CFG.COLOURS, i) end
        log("removed colour " .. colourText(it.colour))
    elseif it.kind == "size" then
        CFG.SIZE_BUTTON = false
        log("removed the line thickness button")
    end
    markDirty()
    rebuildDock()
end

local function pollAsk()
    if not ask then return end
    if not ask.win:get_visible() then ask = nil return end
    if ask.yes:get_active() then
        local it = ask.item
        closeAsk()
        removeItem(it)
    elseif ask.no:get_active() then
        closeAsk()
    end
end

-- The line thickness picker: 5 dot buttons, a row next to a horizontal or rectangle dock (below
-- it, or above when there is no room), a column next to a vertical dock (right, or left).
local function openPick(anchor)
    closePick()
    local G = B.Gtk
    local px = SIZES[CFG.SIZE]
    local win = utilityWindow("Line thickness", false)
    win:get_style_context():add_class("td-frame")
    win:set_transient_for(dock.win)
    local vertical = CFG.SHAPE == "vertical"
    local box = G.Box {orientation = vertical and G.Orientation.VERTICAL or G.Orientation.HORIZONTAL,
                       spacing = 2, margin = 4}
    local _, _, size = currentState()
    local buttons = {}
    for k, s in ipairs(LINE_SIZES) do
        local b = newToggle("td_sz_" .. k, s.label)
        b:set_size_request(px, px)
        b:add(sizeShow(k, px).widget)
        setOn(b, k == size)
        box:add(b)
        buttons[k] = b
    end
    win:add(box)
    box:show_all()
    win:resize(1, 1)
    -- place it: next to the thickness button, on the side with room
    local dx, dy = dock.win:get_position()
    local dw, dh = dock.win:get_size()
    local a = anchor:get_allocation()
    local nat = nil
    pcall(function() local _, n = win:get_preferred_size() nat = n end)
    local pw = nat and nat.width or (5 * (px + 2) + 8)
    local ph = nat and nat.height or (px + 8)
    if vertical then pw, ph = nat and nat.width or (px + 8), nat and nat.height or (5 * (px + 2) + 8) end
    if type(dx) == "number" and type(dw) == "number" then
        local wa = workArea(dx + dw // 2, dy + 10)
        local x, y
        if vertical then
            x, y = dx + dw + 4, dy + a.y - 4
            if wa and x + pw > wa.x + wa.width then x = dx - pw - 4 end
        else
            x, y = dx + a.x - 4, dy + dh + 4
            if wa and y + ph > wa.y + wa.height then y = dy - ph - 4 end
        end
        win:move(x, y)
    end
    win:show_all()
    keepOnScreen(win)
    pick = {win = win, buttons = buttons}
end

local function pollPick()
    if not pick then return end
    if not pick.win:get_visible() then pick = nil return end
    for k, b in ipairs(pick.buttons) do
        if b:get_active() then
            b:set_active(false)
            useSize(k)
            closePick()
            if dock then dock.nextHl = nil end
            return
        end
    end
end

-- Returns true when the dock was rebuilt (its buttons are new).
local function click(it)
    if it.kind == "size" then
        if pick then closePick() else openPick(it.widget) end
    elseif it.kind == "tool" then
        useTool(it.id)
    elseif it.kind == "colour" then
        useColour(it.colour)
    elseif it.kind == "plus" then
        if edit then pcall(function() edit.win:present() end) else openEdit() end
    elseif it.kind == "shape" then
        local i = indexOf(SHAPES, CFG.SHAPE) or 1
        CFG.SHAPE = SHAPES[i % #SHAPES + 1]
        markDirty()
        rebuildDock()
        return true
    end
    dock.nextHl = nil
    return false
end

local function readPress(it, gx, gy, rightDown)
    if pressInput then return pressInput(it.widget:get_name()) end
    local held = false
    pcall(function() held = flagSet(it.widget:get_state_flags(), "ACTIVE", 1) end)
    local right = false
    if rightDown and gx then
        local a = it.widget:get_allocation()
        right = gx >= a.x and gx < a.x + a.width and gy >= a.y and gy < a.y + a.height
    end
    return held, right
end

-- The grip and the buttons (see pollDock: only while something is pressed, or every 150 ms).
-- Returns true when the dock was rebuilt.
local function pollButtons(now, gx, gy, rightDown, b1)
    local g = dock.grip
    if g then
        local held, down, sx, sy = false, b1, nil, nil
        if gripInput then
            held, down, sx, sy = gripInput()
        else
            pcall(function() held = flagSet(g.widget:get_state_flags(), "ACTIVE", 1) end)
            pcall(function() local _, x, y = dock.pointer:get_position() sx, sy = x, y end)
        end
        if not g.drag and held and type(sx) == "number" then
            local wx, wy = dock.win:get_position()
            if type(wx) == "number" then
                g.drag = {sx = sx, sy = sy, wx = wx, wy = wy}
                closePick()
            end
        end
        if g.drag then
            if (down or held) and type(sx) == "number" then
                local nx, ny = g.drag.wx + sx - g.drag.sx, g.drag.wy + sy - g.drag.sy
                local cx, cy = dock.win:get_position()
                if nx ~= cx or ny ~= cy then dock.win:move(nx, ny) end
            else
                g.drag = nil
                keepOnScreen(dock.win)
            end
        end
        if g.widget:get_active() then g.widget:set_active(false) end   -- a grip press is never a click
    end
    for _, it in ipairs(dock.buttons) do
        local removable = it.kind == "tool" or it.kind == "colour" or it.kind == "size"
        local held, right = readPress(it, gx, gy, rightDown)
        local r = pressWatch(it.st, held, right and removable, now)
        if r and removable then openAsk(it) end
        if it.widget:get_active() then
            it.widget:set_active(false)
            if not it.st.consumed and not r then
                if click(it) then return true end
            end
        end
    end
    local x, y = dock.win:get_position()
    if type(x) == "number" and type(y) == "number" and (x ~= CFG.PANEL_X or y ~= CFG.PANEL_Y) then
        CFG.PANEL_X, CFG.PANEL_Y = x, y
        markDirty()
    end
    return false
end

local function pollDock(now)
    if not dock then return end
    if not dock.win:get_visible() then     -- closed with its X
        closeAsk()
        dock = nil
        return
    end
    local gx, gy, rightDown, b1, b3
    if pointerInput then
        gx, gy, b1, b3 = pointerInput()
        rightDown = rightEdge(dock.right, b3, false)
    elseif dock.pointer and not pressInput then
        pcall(function()
            local gw = dock.win:get_window()
            local _, x, y, mask = gw:get_device_position(dock.pointer)
            b1 = flagSet(mask, "BUTTON1_MASK", 256)
            local down = flagSet(mask, "BUTTON3_MASK", 1024)
            b3 = down
            local over = false
            if down then
                local under = dock.pointer:get_window_at_position()
                over = under ~= nil and under:get_toplevel() == gw
            end
            gx, gy = x, y
            rightDown = rightEdge(dock.right, down, over)
        end)
    end
    -- Every GTK call costs about 0.06 ms; asking all buttons at every tick took 2.6 ms (0.3,
    -- measured). So the buttons are asked while a press that STARTED ON THE DOCK is down, on the
    -- tick after it lifts (a click shows as a button pressed in), and every 150 ms while nothing
    -- is pressed. A press that starts on the page (writing) is left alone until it lifts (0.4),
    -- except one look every 500 ms (0.5, safety).
    local down = (b1 or b3) and true or false
    if down and not dock.wasDown then
        dock.pressOnDock = true          -- unknown place: count it as on the dock (safe side)
        if type(gx) == "number" and type(gy) == "number" then
            local okS, w, h = pcall(function() return dock.win:get_size() end)
            if okS and type(w) == "number" and type(h) == "number" then
                dock.pressOnDock = gx >= 0 and gy >= 0 and gx < w and gy < h
            end
        end
    end
    local g = dock.grip
    local onDock = dock.pressOnDock ~= false
    local look = pressInput ~= nil or gripInput ~= nil or (g ~= nil and g.drag ~= nil)
                 or ((down or dock.wasDown) and onDock)
                 or (not down and not dock.wasDown and (not dock.nextLook or now >= dock.nextLook))
                 -- safety: a press off the dock that seems to last (a pen driver that reports the tip
                 -- as down) must not freeze the dock: look every 500 ms then (2 ms per 0.5 s)
                 or (down and not onDock and now >= (dock.nextLook or 0) + 350)
    dock.wasDown = down
    if look then
        dock.looks = (dock.looks or 0) + 1
        dock.nextLook = now + 150
        if pollButtons(now, gx, gy, rightDown, b1) then return end
    end
    if not dock.nextHl or now >= dock.nextHl then
        dock.nextHl = now + 200
        local tool, colour, size = currentState()
        if tool ~= dock.shownTool or colour ~= dock.shownColour then
            dock.shownTool, dock.shownColour = tool, colour
            for _, it in ipairs(dock.buttons) do
                local e = it.kind == "tool" and BY_ID[it.id]
                if e and e.const then setOn(it.widget, app.C[e.const] == tool)
                elseif it.kind == "colour" then setOn(it.widget, it.colour == colour) end
            end
        end
        for _, it in ipairs(dock.buttons) do          -- on / off commands: lit while on
            local e = it.kind == "tool" and (it.entry or BY_ID[it.id])
            if e and (e.toggle or e.draw or e.env or e.custom) then
                local okT, v
                if e.custom then okT, v = pcall(customOn, e, customIndex(it.id))
                elseif e.env then okT, v = pcall(function() return B.GLib.getenv(e.env) == "1" end)
                else okT, v = pcall(app.getActionState, e.action or e.draw) end
                local on = okT and v == true
                if on ~= it.on then it.on = on setOn(it.widget, on) end
            end
        end
        if size ~= dock.shownSize then
            dock.shownSize = size
            if dock.sizeShow then setShow(dock.sizeShow, size) end
            if pick then for k, b in ipairs(pick.buttons) do setOn(b, k == size) end end
        end
    end
end

-- ------------------------------------------------------------------ edit list
-- ------------------------------------------------------------------ custom buttons in the edit list
-- The custom buttons on the dock, in dock order.
local function customIds()
    local r = {}
    for _, id in ipairs(CFG.TOOLS) do
        local n = customIndex(id)
        if n and CUSTOM[n] then r[#r + 1] = id end
    end
    return r
end

-- A new custom button for menu entry c ({group, label, key}), at the end of the tools.
local function addCustom(c)
    for n = 1, MAX_CUSTOM do
        if not CUSTOM[n] then
            CUSTOM[n] = {group = c.group, label = c.label, key = c.key}
            customItems[n], customMiss[n] = nil, nil
            CFG.TOOLS[#CFG.TOOLS + 1] = "custom" .. n
            log("custom button " .. n .. ": " .. c.label .. " (" .. c.group .. " menu"
                .. (c.key and (", " .. c.key) or "") .. ")")
            markDirty()
            return n
        end
    end
    log("custom button not added: there are " .. MAX_CUSTOM .. " already")
end

local function removeCustom(id)
    local i = indexOf(CFG.TOOLS, id)
    if i then table.remove(CFG.TOOLS, i) end
    local n = customIndex(id)
    if n then CUSTOM[n], customItems[n], customMiss[n] = nil, nil, nil end
    log("removed custom button " .. id)
    markDirty()
end

-- The list of menu entries: one row per entry (name left, shortcut right), under its menu.
-- Entries already on the dock are greyed. Tap one = new button; Cancel at the top.
local function openCuPick()
    closeCuPick()
    local G = B.Gtk
    local hook = rawget(_G, "TOOLDOCK_MENU_ENTRIES")          -- tests: a list or a function
    local list, hidden = nil, 0
    if type(hook) == "function" then list = hook()
    elseif type(hook) == "table" then list = hook
    else list, hidden = listMenuEntries() end
    local win = utilityWindow("Tool dock: custom button", true)
    if edit then win:set_transient_for(edit.win) end
    local outer = G.Box {orientation = G.Orientation.VERTICAL, spacing = 6, margin = 10}
    local top = G.Box {orientation = G.Orientation.HORIZONTAL, spacing = 12}
    top:pack_start(G.Label {label = "Tap what the new button should do\n(pen, shapes, undo, zoom ... are tick boxes in the edit list)",
                            xalign = 0}, true, true, 0)
    local cancel = G.ToggleButton.new_with_label("Cancel")
    cancel:set_name("td_cu_cancel")
    top:pack_end(cancel, false, false, 0)
    outer:pack_start(top, false, false, 0)
    local onDock = {}
    for _, id in ipairs(customIds()) do
        local c = CUSTOM[customIndex(id)]
        onDock[c.group .. "|" .. c.label] = true
    end
    local grid = G.Grid {row_spacing = 2, column_spacing = 4}
    local btns, row, group = {}, 0, nil
    for i, c in ipairs(list) do
        if c.group ~= group then
            group = c.group
            local h = G.Label {xalign = 0, margin_top = row > 0 and 8 or 0}
            h:set_markup("<b>" .. esc(group) .. " menu</b>")
            grid:attach(h, 0, row, 1, 1)
            row = row + 1
        end
        local b = G.ToggleButton()
        b:set_name("td_cu_" .. i)
        b:set_relief(G.ReliefStyle.NONE)
        b:set_focus_on_click(false)
        local box = G.Box {orientation = G.Orientation.HORIZONTAL, spacing = 24}
        box:pack_start(G.Label {label = c.label, xalign = 0}, true, true, 0)
        local k = G.Label {xalign = 1}
        k:set_markup('<span alpha="65%">' .. esc(c.key or "no shortcut") .. "</span>")
        box:pack_end(k, false, false, 0)
        b:add(box)
        b:set_hexpand(true)
        if onDock[c.group .. "|" .. c.label] then
            b:set_sensitive(false)
            b:set_tooltip_text("Already on the dock")
        end
        grid:attach(b, 0, row, 1, 1)
        row = row + 1
        btns[#btns + 1] = {widget = b, entry = c}
    end
    if #list == 0 then
        grid:attach(G.Label {label = "No menu entries found (see the log).", xalign = 0}, 0, row, 1, 1)
    end
    local sw = G.ScrolledWindow {hscrollbar_policy = G.PolicyType.NEVER, vscrollbar_policy = G.PolicyType.AUTOMATIC,
                                 propagate_natural_width = true, propagate_natural_height = true,
                                 overlay_scrolling = false}
    sw:add(grid)
    local ex, ey, ew
    if edit then
        ex, ey = edit.win:get_position()
        ew = edit.win:get_size()
    end
    local wa = workArea(type(ex) == "number" and ex or nil, type(ey) == "number" and ey or nil)
    if wa then sw.max_content_height = math.max(200, wa.height - 160) end
    outer:pack_start(sw, true, true, 0)
    win:add(outer)
    outer:show_all()
    win:resize(1, 1)
    if type(ex) == "number" and type(ew) == "number" then
        local pw = naturalSize(win) or 420
        local x = ex + ew + 6                          -- right of the edit list
        if wa and x + pw > wa.x + wa.width then
            if ex - pw - 6 >= wa.x then x = ex - pw - 6   -- no room: left of it
            else x = wa.x + wa.width - pw end              -- no room either: over it, at the right edge
        end
        win:move(x, ey)
    end
    win:show_all()
    keepOnScreen(win)
    cuPick = {win = win, btns = btns, cancel = cancel}
    log(string.format("custom button list: %d menu entries (%d left out: tick boxes give them)", #list, hidden or 0))
end

-- Returns true when a button was added (the dock needs building again).
local function pollCuPick()
    if not cuPick then return false end
    if not cuPick.win:get_visible() then cuPick = nil return false end
    if cuPick.cancel:get_active() then closeCuPick() return false end
    for _, b in ipairs(cuPick.btns) do
        if b.widget:get_active() then
            local c = b.entry
            closeCuPick()
            return addCustom(c) ~= nil
        end
    end
    return false
end

fillEdit = function()
    local G = B.Gtk
    if edit.content then edit.content:destroy() end
    applyCss()
    local grid = G.Grid {row_spacing = 4, column_spacing = 12, margin = 10}
    local row = 0
    local function heading(text)
        if row > 0 then
            grid:attach(G.Separator {orientation = G.Orientation.HORIZONTAL, margin_top = 4}, 0, row, 2, 1)
            row = row + 1
        end
        local h = G.Label {xalign = 0}
        h:set_markup("<b>" .. text .. "</b>")
        grid:attach(h, 0, row, 2, 1)
        row = row + 1
    end
    local shown = {tools = {}}
    edit.tools, edit.rm = {}, {}

    local on = {}
    for _, id in ipairs(CFG.TOOLS) do on[id] = true end
    local function group(title, commands)
        heading(title)
        local n = 0
        for _, e in ipairs(CATALOGUE) do
            if (e.action ~= nil or e.helper == true or e.menu ~= nil) == commands and available(e.id) then
                local cb = G.CheckButton.new_with_label(e.label)
                cb:set_name("td_e_tool_" .. e.id)
                cb:set_active(on[e.id] == true)
                grid:attach(cb, n % 2, row + n // 2, 1, 1)
                edit.tools[e.id] = cb
                shown.tools[e.id] = on[e.id] == true
                n = n + 1
            end
        end
        row = row + (n + 1) // 2
    end
    group("Tools (ticked = on the dock)", false)
    group("Zoom, undo and drawing helpers (ticked = on the dock)", true)
    edit.sizeBtn = G.CheckButton.new_with_label("Line thickness button (5 sizes)")
    edit.sizeBtn:set_name("td_e_sizebtn")
    edit.sizeBtn:set_active(CFG.SIZE_BUTTON)
    shown.sizeBtn = CFG.SIZE_BUTTON
    grid:attach(edit.sizeBtn, 0, row, 2, 1)
    row = row + 1

    heading("Custom buttons (any menu entry or shortcut)")
    edit.cuRm = {}
    for _, id in ipairs(customIds()) do
        local c = CUSTOM[customIndex(id)]
        grid:attach(G.Label {label = c.label .. (c.key and ("    " .. c.key) or ""), xalign = 0}, 0, row, 1, 1)
        local rm = G.ToggleButton.new_with_label("Remove")
        rm:set_name("td_e_curm_" .. id)
        grid:attach(rm, 1, row, 1, 1)
        edit.cuRm[id] = rm
        row = row + 1
    end
    edit.cuAdd = G.ToggleButton.new_with_label("Add a custom button ...")
    edit.cuAdd:set_name("td_e_cuadd")
    edit.cuAdd:set_tooltip_text("Lists every menu entry with a shortcut (auto zoom, snapshot, pen, undo ...)."
                                .. " Tap one: the dock gets a button that does it.")
    grid:attach(edit.cuAdd, 0, row, 2, 1)
    row = row + 1
    shown.cuSig = table.concat(customIds(), ",")

    heading("Colours")
    shown.colours = {}
    for i, c in ipairs(CFG.COLOURS) do
        local box = G.Box {orientation = G.Orientation.HORIZONTAL, spacing = 8}
        local sw = G.Box {valign = G.Align.CENTER}
        sw:set_name("td_sw_" .. colourText(c))
        sw:get_style_context():add_class("td-swatch-small")
        box:add(sw)
        box:add(G.Label {label = "#" .. colourText(c)})
        grid:attach(box, 0, row, 1, 1)
        local rm = G.ToggleButton.new_with_label("Remove")
        rm:set_name("td_e_rm_" .. i)
        grid:attach(rm, 1, row, 1, 1)
        edit.rm[i] = rm
        shown.colours[i] = c
        row = row + 1
    end
    edit.add = G.ToggleButton.new_with_label("Add colour ...")
    edit.add:set_name("td_e_add")
    edit.add:set_tooltip_text("Opens the colour picker. The new colour goes to the end of the colour buttons.")
    grid:attach(edit.add, 0, row, 2, 1)
    row = row + 1

    heading("Shape")
    local sbox = G.Box {orientation = G.Orientation.HORIZONTAL, spacing = 10}
    edit.shape = {}
    local prev = nil
    for _, s in ipairs(SHAPES) do
        local rb = G.RadioButton.new_with_label_from_widget(prev, s:sub(1, 1):upper() .. s:sub(2))
        rb:set_name("td_e_shape_" .. s)
        sbox:add(rb)
        edit.shape[s] = rb
        prev = rb
    end
    edit.shape[CFG.SHAPE]:set_active(true)
    shown.shape = CFG.SHAPE
    grid:attach(sbox, 0, row, 2, 1)
    row = row + 1
    grid:attach(G.Label {label = "Buttons per row (rectangle)", xalign = 0}, 0, row, 1, 1)
    edit.perRow = G.SpinButton.new_with_range(1, 12, 1)
    edit.perRow:set_name("td_e_perrow")
    edit.perRow:set_value(CFG.PER_ROW)
    edit.perRow:set_sensitive(CFG.SHAPE == "rectangle")
    shown.perRow = CFG.PER_ROW
    grid:attach(edit.perRow, 1, row, 1, 1)
    row = row + 1

    heading("Button size")
    local zbox = G.Box {orientation = G.Orientation.HORIZONTAL, spacing = 10}
    edit.size = {}
    prev = nil
    for _, z in ipairs({"small", "medium", "large"}) do
        local rb = G.RadioButton.new_with_label_from_widget(prev, z:sub(1, 1):upper() .. z:sub(2))
        rb:set_name("td_e_size_" .. z)
        zbox:add(rb)
        edit.size[z] = rb
        prev = rb
    end
    edit.size[CFG.SIZE]:set_active(true)
    shown.size = CFG.SIZE
    grid:attach(zbox, 0, row, 2, 1)
    row = row + 1

    heading("Start-up")
    edit.atStart = G.CheckButton.new_with_label("Open the dock when Xournal++ starts")
    edit.atStart:set_name("td_e_atstart")
    edit.atStart:set_active(CFG.DOCK_AT_START)
    shown.atStart = CFG.DOCK_AT_START
    grid:attach(edit.atStart, 0, row, 2, 1)
    row = row + 1
    edit.close = G.ToggleButton.new_with_label("Close")
    edit.close:set_name("td_e_close")
    edit.close.margin_top = 6
    grid:attach(edit.close, 0, row, 2, 1)

    local sw = G.ScrolledWindow {hscrollbar_policy = G.PolicyType.NEVER, vscrollbar_policy = G.PolicyType.AUTOMATIC,
                                 propagate_natural_width = true, propagate_natural_height = true,
                                 overlay_scrolling = false}
    sw:add(grid)
    local placed = hasPlace(CFG.EDIT_X, CFG.EDIT_Y)
    local wa = workArea(placed and CFG.EDIT_X or nil, placed and CFG.EDIT_Y or nil)
    if wa then sw.max_content_height = math.max(200, wa.height - 80) end
    edit.waH = wa and wa.height or nil
    edit.win:add(sw)
    edit.content = sw
    edit.shown = shown
    sw:show_all()
    -- resizable (0.7.2): a resizable GTK window shrinks to its MINIMUM on resize(1, 1), so ask for
    -- the natural size; the user's own height (EDIT_H) wins, kept inside the screen. 0.7.3: the
    -- height only: the width stays the content's width (a wider window only showed empty space)
    local w, h = naturalSize(edit.win)
    if CFG.EDIT_H > 0 then h = CFG.EDIT_H end
    if wa and w and h then
        w = math.min(w, wa.width - 20)
        h = math.min(h, wa.height - 40)
    end
    if w then
        local okH, errH = pcall(function()
            local Gdk = B.Gdk
            edit.win:set_geometry_hints(nil, Gdk.Geometry {min_width = w, max_width = w, min_height = 150,
                                                            max_height = 100000},
                                        Gdk.WindowHints {"MIN_SIZE", "MAX_SIZE"})
        end)
        if not okH then log("edit list width not fixed: " .. tostring(errH)) end
    end
    edit.win:resize(w or 1, h or 1)
    edit.autoUntil = nowMs() + 700                     -- size changes now are ours, not the user's
end

openEdit = function()
    local win = utilityWindow("Tool dock: edit", true)
    win.resizable = true                               -- 0.7.2: drag its edges (small screens, big fonts)
    if dock then win:set_transient_for(dock.win) end
    edit = {win = win}
    fillEdit()
    if hasPlace(CFG.EDIT_X, CFG.EDIT_Y) then win:move(CFG.EDIT_X, CFG.EDIT_Y) end
    win:show_all()
    keepOnScreen(win)
end

local function sameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

local function pollEdit()
    if not edit then return end
    if not edit.win:get_visible() then edit = nil return end
    local sh, changed = edit.shown, false
    -- colours changed somewhere else (long press on the dock): show them again
    if not sameList(sh.colours, CFG.COLOURS) then fillEdit() return end
    if table.concat(customIds(), ",") ~= sh.cuSig then fillEdit() return end   -- removed on the dock
    if pollCuPick() then rebuildDock() return end
    for id, rm in pairs(edit.cuRm) do
        if rm:get_active() then
            rm:set_active(false)
            removeCustom(id)
            rebuildDock()
            return
        end
    end
    if edit.cuAdd:get_active() then
        edit.cuAdd:set_active(false)
        if cuPick then
            pcall(function() cuPick.win:present() end)
        else
            local okP, errP = pcall(openCuPick)
            if not okP then log("custom button list failed: " .. tostring(errP)) closeCuPick() end
        end
    end
    for id, cb in pairs(edit.tools) do
        local a, inList = cb:get_active(), indexOf(CFG.TOOLS, id) ~= nil
        if a ~= sh.tools[id] then
            sh.tools[id] = a
            if a and not inList then CFG.TOOLS[#CFG.TOOLS + 1] = id changed = true end
            if not a and inList then table.remove(CFG.TOOLS, indexOf(CFG.TOOLS, id)) changed = true end
        elseif inList ~= sh.tools[id] then
            cb:set_active(inList)
            sh.tools[id] = inList
        end
    end
    local sb = edit.sizeBtn:get_active()
    if sb ~= sh.sizeBtn then
        sh.sizeBtn = sb
        if sb ~= CFG.SIZE_BUTTON then CFG.SIZE_BUTTON = sb changed = true end
    elseif CFG.SIZE_BUTTON ~= sh.sizeBtn then          -- removed on the dock (long press)
        edit.sizeBtn:set_active(CFG.SIZE_BUTTON)
        sh.sizeBtn = CFG.SIZE_BUTTON
    end
    for i, rm in ipairs(edit.rm) do
        if rm:get_active() then
            rm:set_active(false)
            local k = indexOf(CFG.COLOURS, sh.colours[i])
            if k then table.remove(CFG.COLOURS, k) end
            markDirty()
            rebuildDock()
            return
        end
    end
    if edit.add:get_active() then
        edit.add:set_active(false)
        busy = true
        local okC, c = pcall(chooseColour)
        busy = false
        if not okC then log("colour picker failed: " .. tostring(c)) c = nil end
        if c and not indexOf(CFG.COLOURS, c) then
            CFG.COLOURS[#CFG.COLOURS + 1] = c
            log("added colour " .. colourText(c))
            markDirty()
            rebuildDock()
            return
        end
    end
    for s, rb in pairs(edit.shape) do
        if rb:get_active() and s ~= sh.shape then sh.shape = s CFG.SHAPE = s changed = true end
    end
    if CFG.SHAPE ~= sh.shape then edit.shape[CFG.SHAPE]:set_active(true) sh.shape = CFG.SHAPE end
    edit.perRow:set_sensitive(CFG.SHAPE == "rectangle")
    local pr = math.floor(edit.perRow:get_value() + 0.5)
    if pr ~= sh.perRow then sh.perRow = pr CFG.PER_ROW = pr changed = true end
    for z, rb in pairs(edit.size) do
        if rb:get_active() and z ~= sh.size then sh.size = z CFG.SIZE = z changed = true end
    end
    local st = edit.atStart:get_active()
    if st ~= sh.atStart then sh.atStart = st CFG.DOCK_AT_START = st markDirty() end
    if changed then
        markDirty()
        if dock then fillDock() end
    end
    if edit.close:get_active() then closeEdit() return end
    local x, y = edit.win:get_position()
    local w, h = edit.win:get_size()
    if type(x) == "number" and type(y) == "number" and (x ~= CFG.EDIT_X or y ~= CFG.EDIT_Y) then
        CFG.EDIT_X, CFG.EDIT_Y = x, y
        markDirty()
        -- moved to another monitor: its own height limit, and never taller than that screen
        local wa = type(w) == "number" and workArea(x + w // 2, y + 10)
        if wa and wa.height ~= edit.waH then
            edit.waH = wa.height
            edit.content.max_content_height = math.max(200, wa.height - 80)
            if h > wa.height - 40 then
                edit.win:resize(w, wa.height - 40)
                edit.autoUntil = nowMs() + 700
            end
            log("edit list on a screen " .. wa.width .. " x " .. wa.height .. " (work area)")
        end
    end
    -- the user dragged an edge: keep that size (a size change just after a rebuild is ours)
    if type(w) == "number" and type(h) == "number" then
        local last = edit.lastSize
        if not last or nowMs() < (edit.autoUntil or 0) then
            edit.lastSize = {w, h}
        elseif last[2] ~= h then
            edit.lastSize = {w, h}
            CFG.EDIT_H = h
            markDirty()
        end
    end
end

-- ------------------------------------------------------------------ timer
local editNext = nil
local function tick()
    local now = nowMs()
    pollAsk()
    pollPick()
    pollDock(now)
    -- the edit list has ~35 boxes (~2 ms to ask them all): every 100 ms is quick enough
    if edit and (not editNext or now >= editNext) then
        editNext = now + 100
        pollEdit()
    elseif not edit then
        editNext = nil
    end
end

local function ensureTimer()
    if timerLive then return end
    timerGen = timerGen + 1
    timerLive = true
    local gen = timerGen
    B.GLib.timeout_add(B.GLib.PRIORITY_DEFAULT, CFG.TICK_MS, function()
        if gen ~= timerGen then return false end
        if busy then return true end            -- the colour picker runs its own loop
        local ok, e = pcall(tick)
        if not ok then
            log("tick error: " .. tostring(e) .. " (windows closed)")
            pcall(closeEdit)
            pcall(closeDock)
        end
        local stop = not dock and not edit and not ask
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

local function openDock()
    if dock then
        pcall(function() dock.win:present() end)
        return true
    end
    local b, err = bindings()
    if not b then return false, err end
    checkWayland()
    local top = mainWindow()
    local win = utilityWindow("Tool dock", false)     -- no Windows title bar: moved by its grip
    win:get_style_context():add_class("td-frame")
    if top then win:set_transient_for(top) end
    local okP, pointer = pcall(function() return B.Gdk.Display.get_default():get_default_seat():get_pointer() end)
    dock = {win = win, pointer = okP and pointer or nil, buttons = {}, right = {}}
    fillDock()
    if hasPlace(CFG.PANEL_X, CFG.PANEL_Y) then win:move(CFG.PANEL_X, CFG.PANEL_Y) end
    win:show_all()
    keepOnScreen(win)
    ensureTimer()
    log("dock shown")
    return true
end

-- ------------------------------------------------------------------ menu, keys, start
function toolDockToggle()
    if dock then
        closeEdit()
        closeDock()
        log("dock hidden")
        return
    end
    local ok, res, err = pcall(openDock)
    if not ok or not res then
        local why = tostring(ok and err or res)
        log("dock cannot open: " .. why)
        if app.openDialog then pcall(app.openDialog, "Tool dock cannot open: " .. why, {"OK"}, "", true) end
    end
end

local function accel(name)
    local v = CFG[name]
    if type(v) ~= "string" or v:lower() == "none" then return nil end
    return v
end

function initUi()
    -- settings first: the shortcut key comes from the file. A file that lacks a setting
    -- (older version) is rewritten once, so every setting can be seen and changed there.
    local okL, seen = pcall(loadSettings)
    if okL and (seen or 0) < settingCount() then pcall(saveSettings) end
    app.registerUi({["menu"] = "Tool dock: show / hide", ["callback"] = "toolDockToggle",
                    ["accelerator"] = accel("KEY_DOCK")})
    if CFG.DOCK_AT_START and not rawget(_G, "TOOLDOCK_TEST") and bindings() then
        local tries = 0
        B.GLib.timeout_add(B.GLib.PRIORITY_DEFAULT, 1700, function()
            tries = tries + 1
            if dock then return false end
            if not mainWindow() then return tries < 6 end
            local ok = pcall(openDock)
            return not ok and tries < 6
        end)
    end
end

if rawget(_G, "TOOLDOCK_TEST") then
    TOOLDOCK_INTERNALS = {CFG = CFG, DEFAULTS = DEFAULTS, CATALOGUE = CATALOGUE, catalogueEntry = catalogueEntry,
                          available = available, parseTools = parseTools, parseColours = parseColours,
                          colourText = colourText, loadSettings = loadSettings, saveSettings = saveSettings,
                          settingCount = settingCount, resetDefaults = resetDefaults, layoutCells = layoutCells,
                          pressWatch = pressWatch, validKey = validKey, hasPlace = hasPlace, rightEdge = rightEdge,
                          dock = function() return dock end, edit = function() return edit end,
                          ask = function() return ask end, rebuildDock = rebuildDock, keepOnScreen = keepOnScreen,
                          pick = function() return pick end, LINE_SIZES = LINE_SIZES,
                          timerLive = function() return timerLive end, tick = tick,
                          setPressInput = function(f) pressInput = f end,
                          setGripInput = function(f) gripInput = f end,
                          setPointerInput = function(f) pointerInput = f end,
                          pluginInstalled = pluginInstalled, CUSTOM = CUSTOM, customIndex = customIndex,
                          plainLabel = plainLabel, parseCustom = parseCustom, entryOf = entryOf,
                          addCustom = addCustom, removeCustom = removeCustom, useTool = useTool,
                          cuPick = function() return cuPick end, listMenuEntries = listMenuEntries,
                          customOn = customOn, TICK_BOX_OF = TICK_BOX_OF, naturalSize = naturalSize,
                          pollEdit = pollEdit}
end
