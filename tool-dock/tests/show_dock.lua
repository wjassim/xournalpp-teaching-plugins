-- Takes pictures of the dock (3 shapes x 3 sizes), the edit list and the remove box, with
-- Xournal++'s own icons. No Xournal++ needed. Pictures go to the folder in TOOLDOCK_SHOT_DIR
-- (default %TEMP%). Run: powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\show_dock.lua
local DIR = os.getenv("TOOLDOCK_SHOT_DIR") or os.getenv("TEMP") or "."
TOOLDOCK_TEST = true
TOOLDOCK_SETTINGS_FILE = DIR .. "\\tooldock_shot_settings.txt"
TOOLDOCK_LOG_FILE = DIR .. "\\tooldock_shot.log"
os.remove(TOOLDOCK_SETTINGS_FILE)
app = {C = {Tool_pen = 1, Tool_eraser = 2, Tool_highlighter = 3, Tool_text = 4, Tool_image = 5,
            Tool_selectRect = 6, Tool_selectRegion = 7, Tool_selectObject = 10, Tool_verticalSpace = 12,
            Tool_hand = 13, Tool_drawRect = 14, Tool_drawEllipse = 15, Tool_drawArrow = 16,
            Tool_drawSpline = 20, Tool_laserPointerPen = 23, Tool_laserPointerHighlighter = 24, Tool_latex = 26}}
function app.registerUi() end
function app.getActionState(a) if a == "select-tool" then return 1 end return 0xFF1E5AE6 end
function app.getToolInfo() return {color = 0x1E5AE6} end
function app.changeActionState() end
function app.changeToolColor() end
dofile((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\tool-dock\main.lua]])
local I = TOOLDOCK_INTERNALS
local lgo = require("LuaGObject")
local GLib, Gtk, Gdk = lgo.GLib, lgo.require("Gtk", "3.0"), lgo.require("Gdk", "3.0")
Gtk.init()
local X = (os.getenv("LOCALAPPDATA") or "") .. "\\Programs\\Xournal++\\share\\xournalpp\\ui\\iconsColor-light"
Gtk.IconTheme.get_default():append_search_path(X)
Gtk.IconTheme.get_default():append_search_path(X:gsub("iconsColor%-light", "iconsColor-dark"))
local main = Gtk.Window {title = "host", default_width = 300, default_height = 200}
local da = Gtk.DrawingArea {}
da:set_name("GtkXournal")
main:add(da) main:show_all()

local function shot(win, name)
    local gw = win:get_window()
    local pb = Gdk.pixbuf_get_from_window(gw, 0, 0, gw:get_width(), gw:get_height())
    pb:savev(DIR .. "\\" .. name .. ".png", "png", {}, {})
    print(name .. " " .. gw:get_width() .. "x" .. gw:get_height())
end

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
at(300, function() I.CFG.PANEL_X, I.CFG.PANEL_Y = 100, 100 toolDockToggle() end)
for _, shape in ipairs({"horizontal", "vertical", "rectangle"}) do
    for _, size in ipairs({"small", "medium", "large"}) do
        at(100, function() I.CFG.SHAPE, I.CFG.SIZE = shape, size I.rebuildDock() end)
        at(900, function() shot(I.dock().win, "dock_" .. shape .. "_" .. size) end)
    end
end
for _, shape in ipairs({"horizontal", "vertical"}) do
    at(100, function() I.CFG.SHAPE, I.CFG.SIZE = shape, "medium" I.rebuildDock() end)
    at(600, function() for _, it in ipairs(I.dock().buttons) do if it.kind == "size" then it.widget:set_active(true) end end end)
    at(900, function() if I.pick() then shot(I.pick().win, "picker_" .. shape) else print("no picker") end end)
end
at(100, function()
    I.CFG.SHAPE, I.CFG.SIZE = "horizontal", "medium"
    I.rebuildDock()
end)
at(300, function()
    for _, it in ipairs(I.dock().buttons) do if it.kind == "plus" then it.widget:set_active(true) end end
end)
at(900, function() shot(I.edit().win, "edit_list") end)
at(100, function()
    I.setPressInput(function(n) return n == "td_colour_3", false end)
end)
at(900, function() I.setPressInput(nil) end)
at(1500, function() if I.ask() then shot(I.ask().win, "remove_box") else print("no remove box") end end)
at(300, function() loop:quit() end)
loop:run()
os.remove(TOOLDOCK_SETTINGS_FILE)
return "done"
