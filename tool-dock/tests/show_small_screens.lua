-- Small screens: shows the dock, the edit list and the custom button list as they would sit on a
-- smaller screen (the work area is faked with TOOLDOCK_WORKAREA; GTK on Windows uses real pixels, so
-- 1366 x 728 here = a 1366 x 768 laptop with its task bar, at 125 % text size).
-- For each screen it writes <TOOLDOCK_SHOT_DIR>\ready_<n>.txt (with the window places) and waits
-- 3 s: a screen grab of the top left corner of the screen shows it (see grab_small_screens.ps1).
-- Run: powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\show_small_screens.lua
local DIR = os.getenv("TOOLDOCK_SHOT_DIR") or os.getenv("TEMP") or "."
TOOLDOCK_TEST = true
TOOLDOCK_SETTINGS_FILE = DIR .. "\\tooldock_small_settings.txt"
TOOLDOCK_LOG_FILE = DIR .. "\\tooldock_small.log"
TOOLDOCK_PLUGINS_DIR = (os.getenv("LOCALAPPDATA") or "."):gsub(string.char(92), "/") .. "/xournalpp/plugins"
os.remove(TOOLDOCK_SETTINGS_FILE)
app = {C = {Tool_pen = 1, Tool_eraser = 2, Tool_highlighter = 3, Tool_text = 4, Tool_image = 5,
            Tool_selectRect = 6, Tool_selectRegion = 7, Tool_selectObject = 10, Tool_verticalSpace = 12,
            Tool_hand = 13, Tool_drawRect = 14, Tool_drawEllipse = 15, Tool_drawArrow = 16,
            Tool_drawSpline = 20, Tool_laserPointerPen = 23, Tool_laserPointerHighlighter = 24, Tool_latex = 26,
            Tool_link = 25, Tool_selectMultiLayerRect = 8, Tool_selectMultiLayerRegion = 9}}
function app.registerUi() end
function app.getActionState(a) if a == "select-tool" then return 1 end return 0xFF1E5AE6 end
function app.getToolInfo() return {color = 0x1E5AE6} end
function app.changeActionState() end
function app.changeToolColor() end
function app.activateAction() end
-- the custom button list: 68 entries, as in Xournal++ 1.3 with these four plugins
local ENTRIES = {}
local groups = {{"File", 7}, {"Edit", 6}, {"View", 5}, {"Navigation", 11}, {"Journal", 5}, {"Tools", 4}, {"Plugin", 30}}
for _, g in ipairs(groups) do
    for i = 1, g[2] do
        ENTRIES[#ENTRIES + 1] = {group = g[1], label = g[1] == "Plugin" and ("Snapshot: drag a rectangle (on / off) " .. i)
                                 or (g[1] .. " entry " .. i), key = "Shift+Ctrl+Page Down"}
    end
end
TOOLDOCK_MENU_ENTRIES = ENTRIES
dofile((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\tool-dock\main.lua]])
local I = TOOLDOCK_INTERNALS
local lgo = require("LuaGObject")
local GLib, Gtk = lgo.GLib, lgo.require("Gtk", "3.0")
Gtk.init()
local X = (os.getenv("LOCALAPPDATA") or "") .. "\\Programs\\Xournal++\\share\\xournalpp\\ui\\iconsColor-light"
Gtk.IconTheme.get_default():append_search_path(X)
Gtk.IconTheme.get_default():append_search_path(X:gsub("iconsColor%-light", "iconsColor-dark"))
local main = Gtk.Window {title = "host", default_width = 300, default_height = 200}
local da = Gtk.DrawingArea {}
da:set_name("GtkXournal")
main:add(da)
main:show_all()
main:move(3000, 600)

local SCREENS = {{1366, 728}, {1280, 680}, {1920, 1032}}
local loop = GLib.MainLoop()
local T = 0
local function at(ms, fn)
    T = T + ms
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, T, function()
        local ok, e = pcall(fn)
        if not ok then print("ERROR " .. tostring(e)) end
        return false
    end)
end
local function place(win)
    local x, y = win:get_position()
    local w, h = win:get_size()
    return string.format("%d,%d %dx%d", x, y, w, h)
end
for n, sc in ipairs(SCREENS) do
    at(400, function()
        TOOLDOCK_WORKAREA = {x = 0, y = 0, width = sc[1], height = sc[2]}
        I.CFG.TOOLS = {"pen", "laserPen", "selectObject", "eraser", "hand", "zoomFit", "drawArrow", "drawRect", "undo", "redo"}
        I.CFG.PANEL_X, I.CFG.PANEL_Y = 20, 40
        I.CFG.EDIT_X, I.CFG.EDIT_Y = math.floor(sc[1] * 0.25), 0      -- where a user might have it
        I.CFG.EDIT_H = 0
        toolDockToggle()
    end)
    at(500, function() for _, it in ipairs(I.dock().buttons) do if it.kind == "plus" then it.widget:set_active(true) end end end)
    at(900, function() I.edit().cuAdd:set_active(true) end)
    at(900, function()
        local f = io.open(DIR .. "\\ready_" .. n .. ".txt", "w")
        local s = string.format("screen %dx%d  dock %s  edit %s  list %s", sc[1], sc[2], place(I.dock().win),
                                place(I.edit().win), I.cuPick() and place(I.cuPick().win) or "none")
        f:write(s) f:close()
        print(s)
    end)
    at(3000, function()
        if I.cuPick() then I.cuPick().cancel:set_active(true) end
    end)
    at(400, function()
        I.edit().close:set_active(true)
        toolDockToggle()
    end)
end
at(800, function() loop:quit() end)
loop:run()
main:destroy()
os.remove(TOOLDOCK_SETTINGS_FILE)
return "done"
