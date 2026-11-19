-- Real GTK test (no Xournal++): builds the floating window with the real Gtk, polls it, clicks its buttons.
-- Run from the plugin folder:
--   powershell -ExecutionPolicy Bypass -File ..\autozoom\tests\run_lua55.ps1 tests\test_gtk_smoke.lua
local PLUGIN = PLUGIN_PATH or ((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\preserve-view\main.lua]])
local TEMP = os.getenv("TEMP") or "."
PRESERVE_VIEW_TEST = true
PRESERVE_VIEW_SETTINGS_FILE = TEMP .. "/preserve_view_smoke_settings.txt"
local out, fails = {}, 0
local function check(name, cond, detail)
    out[#out + 1] = (cond and "PASS " or "FAIL ") .. name .. ((not cond and detail) and ("  -> " .. tostring(detail)) or "")
    if not cond then fails = fails + 1 end
end

local lgo = require("LuaGObject")
local Gtk = lgo.require("Gtk", "3.0")
Gtk.init()

-- fake Xournal++: 10 pages of 540 pt, 2 px per point, view 1080 px high
local N, S, VIEW = 10, 2, 1080
local total = 20 + (N - 1) * 15 + N * 540 * S
local y, reg, dialogs = 300, {}, {}
app = {}
function app.registerUi(t) reg[#reg + 1] = t end
function app.openDialog(m) dialogs[#dialogs + 1] = m end
function app.getZoom() return S / (120 / 72) end
function app.getDisplayDpi() return 120 end
function app.getScrollPos() return {x = 0, y = y, width = 1920, height = VIEW} end
function app.getDocumentStructure()
    local p = {}
    for i = 1, N do p[i] = {pageHeight = 540, pageWidth = 960} end
    return {pages = p, currentPage = math.min(N, math.floor((y + VIEW / 2 - 10) / (540 * S + 15)) + 1)}
end
function app.scrollToPos(_, dy, rel)
    y = math.max(0, math.min(total - VIEW, rel and (y + dy) or dy))
end
function app.scrollToPage() end

-- settings file with a changed key, a bad key and a nudge step
local f = io.open(PRESERVE_VIEW_SETTINGS_FILE, "w")
f:write("NUDGE_PX=7\nKEY_NEXT=<Control>Page_Down\nKEY_PREVIOUS=Ctrl+Left\nKEY_CHECK=none\n")
f:close()

dofile(PLUGIN)
local I = PRESERVE_VIEW_INTERNALS
check("shortcut texts", I.validKey("<Control><Alt>Right") and I.validKey("F9") and I.validKey("none")
      and not I.validKey("Ctrl+F8") and not I.validKey("<Bogus>F8") and not I.validKey(""))
initUi()
check("six menu entries", #reg == 6, #reg)
check("key from the file", reg[1].accelerator == "<Control>Page_Down", reg[1].accelerator)
check("bad key keeps the default", reg[2].accelerator == "<Control><Alt>Left", reg[2].accelerator)
check("none = no key", reg[5].accelerator == nil and reg[5].callback == "recalibrate")
check("window entry", reg[6].callback == "preserveViewPanel" and reg[6].accelerator == "<Control><Alt>F11")
check("nudge step from the file", I.CFG.NUDGE_PX == 7)
f = io.open(PRESERVE_VIEW_SETTINGS_FILE, "r")
local txt = f:read("a")
f:close()
check("file rewritten with every setting", txt:find("KEY_PANEL=<Control><Alt>F11", 1, true) ~= nil
      and txt:find("KEY_NEXT=<Control>Page_Down", 1, true) ~= nil and txt:find("PANEL_AT_START=false", 1, true) ~= nil)

-- the real window on a fake main window
local top = Gtk.Window {title = "fake main window"}
top:show_all()
I.H.mainWindow = function() return top end
I.H.ensureTimer = function() end
I.H.now = function() return 0 end
preserveViewPanel()
local p = I.panel()
check("window opens", p ~= nil and p.win:get_visible() == true, dialogs[#dialogs])
if p then
    local ok, e = pcall(p.poll, 10)
    check("poll runs", ok, e)
    check("page number shown", p.page:get_label() == "Page 1 / 10", p.page:get_label())
    check("no nudge controls in the window", p.btn.up == nil and p.btn.down == nil and p.step == nil)
    local pitch = 540 * S + 15
    local y0 = y
    p.btn.next:set_active(true)
    ok, e = pcall(p.poll, 1)
    check("Next: one page step down", ok and y - y0 == pitch, tostring(e) .. " moved " .. (y - y0))
    check("Next springs back", p.btn.next:get_active() == false)
    check("page number follows", p.page:get_label() == "Page 2 / 10", p.page:get_label())
    p.btn.previous:set_active(true)
    pcall(p.poll, 2)
    check("Previous: back to the start", y == y0, y)
    -- 2.6: page list read only after a scroll (or every 3 s), never 3 times a second
    pcall(p.poll, 10)      -- first look after the button click above reads once
    local reads = 0
    local realDS = app.getDocumentStructure
    app.getDocumentStructure = function() reads = reads + 1 return realDS() end
    for k = 2, 9 do pcall(p.poll, 10 * k) end
    check("still view: no page-list read", reads == 0, reads)
    pcall(p.poll, 100)
    check("still view: one read every 3 s", reads == 1, reads)
    local ySave = y
    y = y + 3 * pitch
    pcall(p.poll, 110)
    check("scroll by hand: page number follows", reads == 2 and p.page:get_label() == "Page 4 / 10", p.page:get_label())
    y = ySave
    pcall(p.poll, 120)
    app.getDocumentStructure = realDS
    nudgeDown()
    check("nudge key still works, step from the file", y - y0 == 7, y - y0)
    local n0 = #dialogs
    p.btn.check:set_active(true)
    ok, e = pcall(p.poll, 6)
    check("Check button shows its message", ok and #dialogs == n0 + 1, e)
    preserveViewPanel()
    check("second call keeps one window", I.panel() == p)
    p.win:hide()
    pcall(p.poll, 7)
    check("closing the window is noticed", I.panel() == nil)
end
os.remove(PRESERVE_VIEW_SETTINGS_FILE)
out[#out + 1] = (fails == 0 and "ALL PASS" or ("FAILED " .. fails))
return table.concat(out, "\n")
