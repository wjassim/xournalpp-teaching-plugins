-- Real GTK test (no Xournal++): builds the floating window with the real Gtk, polls it, clicks its button.
-- Run:  powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_gtk_smoke.lua
local PLUGIN = PLUGIN_PATH or ((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\snapshot\main.lua]])
local TEMP = os.getenv("TEMP") or "."
SNAPSHOT_TEST = true
SNAPSHOT_LOG_FILE = TEMP .. "/snapshot_test.log"
SNAPSHOT_SETTINGS_FILE = TEMP .. "/snapshot_smoke_settings.txt"
os.remove(SNAPSHOT_SETTINGS_FILE)
local out, fails = {}, 0
local function check(name, cond, detail)
    out[#out + 1] = (cond and "PASS " or "FAIL ") .. name .. ((not cond and detail) and ("  -> " .. tostring(detail)) or "")
    if not cond then fails = fails + 1 end
end

local lgo = require("LuaGObject")
local Gtk, Gdk = lgo.require("Gtk", "3.0"), lgo.require("Gdk", "3.0")
Gtk.init()

local tool = 1
app = {C = {Tool_selectRect = 6}}
function app.registerUi() end
function app.export() end
function app.addImages() return {} end
function app.getDocumentStructure() return {pages = {{pageWidth = 960, pageHeight = 540}}, currentPage = 1} end
function app.getScrollPos() return {x = 0, y = 0, width = 800, height = 600} end
function app.getActionState() return tool end
function app.changeActionState(_, t) tool = t end

dofile(PLUGIN)
local I = SNAPSHOT_INTERNALS
local top = Gtk.Window {title = "fake main window"}
top:show_all()
local pointer = Gdk.Display.get_default():get_default_seat():get_pointer()
I.H.attach = function() I.setUi({top = top, gdkwin = top:get_window(), pointer = pointer}) return true end
I.H.ensureTimer = function() end
I.H.now = function() return 0 end
initUi()
snapshotPanel()
local p = I.panel()
check("window opens", p ~= nil and p.win:get_visible() == true)
if p then
    local ok, e = pcall(p.poll)
    check("poll runs", ok, e)
    p.btn:set_active(true)
    ok, e = pcall(p.poll)
    check("button click arms the mode", ok and I.S().mode == "ARMED" and tool == 6, e)
    check("status text shown", p.state:get_label() == "drag a rectangle on the page", p.state:get_label())
    local okR, pen = pcall(I.H.readPen, app.getScrollPos())
    check("real pointer can be read", okR and (pen == nil or type(pen.x) == "number"), pen)
    p.btn:set_active(false)
    ok, e = pcall(p.poll)
    check("second click leaves the mode, tool back", ok and I.S().mode == "IDLE" and tool == 1, e)
    snapshotRect()
    pcall(p.poll)
    check("key arms and the button follows", I.S().mode == "ARMED" and p.btn:get_active() == true)
    check("0.11: XOPP_SNAPSHOT_ON = 1 while waiting for a drag", lgo.GLib.getenv("XOPP_SNAPSHOT_ON") == "1",
          lgo.GLib.getenv("XOPP_SNAPSHOT_ON"))
    snapshotRect()
    pcall(p.poll)
    check("key again: button released", I.S().mode == "IDLE" and p.btn:get_active() == false)
    p.win:hide()
    pcall(p.poll)
    check("closing the window is noticed", I.panel() == nil)
    check("0.11: XOPP_SNAPSHOT_ON = 0 after the mode", lgo.GLib.getenv("XOPP_SNAPSHOT_ON") == "0",
          lgo.GLib.getenv("XOPP_SNAPSHOT_ON"))
    local function popups()
        local c = 0
        for _, w in ipairs(Gtk.Window.list_toplevels()) do
            local ty = w:get_window_type()
            if (ty == "POPUP" or ty == Gtk.WindowType.POPUP) and w:get_visible() then c = c + 1 end
        end
        return c
    end
    local before = popups()
    local okT, eT = pcall(I.H.toast, "Too quick: the page was still loading.\nDrag again.", {x = 40, y = 40})
    check("0.11: note pops up (window closed)", okT and popups() == before + 1, eT or popups())
end
os.remove(SNAPSHOT_SETTINGS_FILE)
out[#out + 1] = (fails == 0 and "ALL PASS" or ("FAILED " .. fails))
return table.concat(out, "\n")
