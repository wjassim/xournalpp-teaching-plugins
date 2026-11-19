-- Shows the real settings panel for 6 seconds (to look at it or take a picture). No Xournal++ needed.
AUTOZOOM_SETTINGS_FILE = (os.getenv("TEMP") or ".") .. "\\autozoom_smoke_settings.txt"
AUTOZOOM_LOG_FILE = (os.getenv("TEMP") or ".") .. "\\autozoom_test.log"
os.remove(AUTOZOOM_SETTINGS_FILE)
app = {}
function app.getZoom() return 1.0 end
function app.setZoom() end
function app.getScrollPos() return {x = 0, y = 0, width = 500.0, height = 300.0} end
function app.scrollToPos() end
function app.getDocumentStructure() return {pages = {{pageWidth = 960.0, pageHeight = 540.0}}} end
function app.registerUi() end
function app.openDialog() end
dofile((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\autozoom\main.lua]])
local lgo = require("LuaGObject")
local GLib, Gtk = lgo.GLib, lgo.require("Gtk", "3.0")
Gtk.init()
local settings = Gtk.Settings.get_default()
settings.gtk_application_prefer_dark_theme = true
local win = Gtk.Window {title = "autozoom panel preview (closes itself)", default_width = 300, default_height = 200}
local sw = Gtk.ScrolledWindow {}
local da = Gtk.DrawingArea {}
da:set_name("GtkXournal")
sw:add(da) win:add(sw) win:show_all()
local loop = GLib.MainLoop()
GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, function() autozoomPanel() return false end)
GLib.timeout_add(GLib.PRIORITY_DEFAULT, 6000, function() loop:quit() return false end)
loop:run()
os.remove(AUTOZOOM_SETTINGS_FILE)
return "shown"
