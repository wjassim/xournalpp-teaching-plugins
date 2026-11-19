-- Smoke test: the autozoom plugin with the REAL LuaGObject, GLib timer and GTK widgets
-- (a small window with a canvas named "GtkXournal"), a fake `app`, and the REAL settings panel.
-- Windows show for about 9 seconds and close by themselves.
AUTOZOOM_SETTINGS_FILE = (os.getenv("TEMP") or ".") .. "\\autozoom_smoke_settings.txt"
os.remove(AUTOZOOM_SETTINGS_FILE)
AUTOZOOM_LOG_FILE = (os.getenv("TEMP") or ".") .. "\\autozoom_test.log"
local out = {}
local function say(s) out[#out + 1] = tostring(s) end
ZOOM, SX, SY, DIALOGS, CALLS = 1.0, 100.0, 200.0, {}, 0
app = {}
function app.getZoom() return ZOOM end
function app.setZoom(z) ZOOM = z CALLS = CALLS + 1 end
function app.getScrollPos() return {x = SX, y = SY, width = 500.0, height = 300.0} end
function app.scrollToPos(x, y, rel) if rel then x, y = SX + x, SY + y end SX, SY = x, y end
function app.getDocumentStructure() return {pages = {{pageWidth = 960.0, pageHeight = 540.0}, {pageWidth = 960.0, pageHeight = 540.0}}} end
function app.registerUi() end
function app.openDialog(m) DIALOGS[#DIALOGS + 1] = m end
dofile((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\autozoom\main.lua]])
local lgo = require("LuaGObject")
local GLib, Gtk = lgo.GLib, lgo.require("Gtk", "3.0")
Gtk.init()
local win = Gtk.Window {title = "autozoom self-test (closes itself)", default_width = 500, default_height = 300}
local sw = Gtk.ScrolledWindow {}
local da = Gtk.DrawingArea {}
da:set_name("GtkXournal")
sw:add(da) win:add(sw) win:show_all()
local loop = GLib.MainLoop()
local function at(ms, fn) GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, function() local ok, e = pcall(fn) if not ok then say("ERROR " .. tostring(e)) end return false end) end

local function readFile()
    local f = io.open(AUTOZOOM_SETTINGS_FILE, "r")
    if not f then return "" end
    local s = f:read("a") f:close() return s
end
local function panelWin()
    for _, t in ipairs(Gtk.Window.list_toplevels()) do
        if t:get_title() == "Auto zoom" and t:get_visible() then return t end
    end
end
local function find(w, name)
    if w:get_name() == name then return w end
    if Gtk.Container:is_type_of(w) then
        for _, k in ipairs(w:get_children()) do
            local r = find(k, name)
            if r then return r end
        end
    end
end
local function onButton(w)
    if Gtk.ToggleButton:is_type_of(w) and not Gtk.CheckButton:is_type_of(w) and (w:get_label() or ""):find("Auto zoom:") then return w end
    if Gtk.Container:is_type_of(w) then
        for _, k in ipairs(w:get_children()) do
            local r = onButton(k)
            if r then return r end
        end
    end
end

-- A. keys without the panel (toast instead of a dialog)
at(400, function() autozoomToggle() say("A toggle on: dialogs " .. #DIALOGS) end)
at(700, function() autozoomNow() end)
at(2900, function() say(string.format("A after key zoom in: zoom %.3f (setZoom calls %d)", ZOOM, CALLS)) autozoomNow() end)
at(5000, function() say(string.format("A after key zoom out: zoom %.3f scroll %.1f %.1f", ZOOM, SX, SY)) autozoomToggle() say("A toggle off: dialogs " .. #DIALOGS) end)

-- B. the settings panel
at(5300, function()
    autozoomPanel()
    local p = panelWin()
    say("B panel open: " .. tostring(p ~= nil) .. ", dialogs " .. #DIALOGS)
    local w, h = p:get_size()
    say(string.format("B panel size %d x %d", w, h))
    local sc = find(p, "az_FACTOR")
    say(string.format("B zoom slider shows %.2f", sc:get_value()))
    local tips = 0
    for _, n in ipairs({"FACTOR", "LEARN", "ZOOM_MS", "DWELL_MS", "WRITE_MS", "IDLE_MS", "STILL", "FOLLOW_DELAY_MS",
                        "FOLLOW_MS", "EDGE", "PAN_SPEED", "PAN_IDLE", "START_ON", "PANEL_AT_START"}) do
        if #(find(p, "az_tip_" .. n):get_tooltip_text() or "") > 20 then tips = tips + 1 end
    end
    say("B settings with an info mark: " .. tips .. " of 14; info text on the zoom slider itself: " .. tostring(sc:get_tooltip_text()))
    sc:set_value(2.0)
    find(p, "az_PAN_IDLE"):set_active(true)
end)
at(6600, function()
    local s = readFile()
    say("B saved after slider move: " .. tostring(s:match("FACTOR=[^\n]*")) .. ", " .. tostring(s:match("PAN_IDLE=[^\n]*")))
    onButton(panelWin()):set_active(true)       -- ON from the panel
end)
at(7000, function()
    local b = onButton(panelWin())
    say("B on-button label after click: " .. tostring(b:get_label()))
    autozoomNow()
end)
at(8600, function()
    say(string.format("B key zoom in with level 2.0: zoom %.3f", ZOOM))
    find(panelWin(), "az_defaults"):set_active(true)
end)
at(10600, function()
    local p = panelWin()
    say(string.format("B after defaults: slider %.2f, zoom %.3f, defaults button sprang back: %s",
        find(p, "az_FACTOR"):get_value(), ZOOM, tostring(not find(p, "az_defaults"):get_active())))
    local s = readFile()
    say("B saved after defaults: " .. tostring(s:match("FACTOR=[^\n]*")) .. ", " .. tostring(s:match("PAN_IDLE=[^\n]*")))
    onButton(p):set_active(false)               -- OFF from the panel
end)
at(11000, function()
    say(string.format("B off from the panel: zoom %.3f scroll %.1f %.1f", ZOOM, SX, SY))
    panelWin():destroy()                        -- as the X button does
end)
at(11600, function() say("B panel closed: " .. tostring(panelWin() == nil) .. ", dialogs " .. #DIALOGS) end)
at(12000, function() loop:quit() end)
loop:run()
win:destroy()
os.remove(AUTOZOOM_SETTINGS_FILE)
return table.concat(out, "\n")
