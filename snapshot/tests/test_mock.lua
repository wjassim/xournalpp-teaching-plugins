-- Mock test for the snapshot plugin: fake app (strokes, undo, export, addImages) and a fake
-- GdkPixbuf. Run:  powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_mock.lua
local PLUGIN = PLUGIN_PATH or ((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\snapshot\main.lua]])
local TEMP = os.getenv("TEMP") or "."
SNAPSHOT_TEST = true
SNAPSHOT_SETTINGS_FILE = TEMP .. "\\snapshot_mock_settings.txt"
SNAPSHOT_LOG_FILE = TEMP .. "\\snapshot_test.log"
os.remove(SNAPSHOT_SETTINGS_FILE)

local out, fails = {}, 0
local function check(name, cond, detail)
    out[#out + 1] = (cond and "PASS " or "FAIL ") .. name .. ((not cond and detail) and ("  -> " .. tostring(detail)) or "")
    if not cond then fails = fails + 1 end
end
local function touch(path) local f = io.open(path, "wb") f:write("x") f:close() end

local W
local function world(opts)
    opts = opts or {}
    W = {strokes = opts.strokes or {}, undone = {}, exports = {}, images = {}, selected = nil, cleared = 0,
         crops = {}, saves = {}, numbered = opts.numbered, undoBreaks = opts.undoBreaks, reg = {}}
    app = {}
    function app.getDocumentStructure()
        W.structReads = (W.structReads or 0) + 1
        return {pages = {{pageWidth = 960.0, pageHeight = 540.0}, {pageWidth = 960.0, pageHeight = 540.0}},
                currentPage = opts.page or 2}
    end
    function app.getStrokes(kind) assert(kind == "layer") return W.strokes end
    function app.activateAction(a)
        if a == "undo" then
            if W.undoBreaks == "nothing" then return end
            if W.undoBreaks == "two" then table.remove(W.strokes) end
            W.undone[#W.undone + 1] = table.remove(W.strokes)
        elseif a == "redo" then
            W.strokes[#W.strokes + 1] = table.remove(W.undone)
        end
    end
    function app.clearSelection() W.cleared = W.cleared + 1 end
    function app.export(o)
        W.exports[#W.exports + 1] = o
        W.strokesAtExport = #W.strokes
        local path = o.outputFile
        if W.numbered then path = path:gsub("%.png$", "-" .. o.range .. ".png") end
        touch(path)
    end
    function app.addImages(o)
        W.images[#W.images + 1] = o
        local fh = io.open(o.images[1].path, "rb")
        W.cutExisted = fh ~= nil
        if fh then fh:close() end
        return {io.stdout}                       -- any userdata stands for the element reference
    end
    function app.addToSelection(refs) W.selected = refs end
    function app.refreshPage() end
    function app.registerUi(o) W.reg[#W.reg + 1] = o end
    W.tool, W.toolLog, W.clock, W.pen = 1, {}, 0, {x = 0, y = 0, down = false, inside = true}
    W.sp = {x = 0, y = 1000, width = 2175, height = 1224}
    app.C = {Tool_pen = 1, Tool_selectRect = 6}
    function app.getActionState(a) assert(a == "select-tool") return W.tool end
    function app.changeActionState(a, t) assert(a == "select-tool") W.tool = t W.toolLog[#W.toolLog + 1] = t end
    function app.getScrollPos() return W.sp end
    function app.setCurrentPage(i) W.setPage = i end

    SNAPSHOT_PIXBUF = {Pixbuf = {new_from_file = function(path)
        local pb = {}
        function pb:get_width() return W.exports[#W.exports].pngWidth end
        function pb:get_height() return W.exports[#W.exports].pngWidth * 540 / 960 end
        function pb:new_subpixbuf(x, y, w, h)
            W.crops[#W.crops + 1] = {x = x, y = y, w = w, h = h}
            return {fake = true, savev = function(_, dst) W.saves[#W.saves + 1] = dst touch(dst) return true end}
        end
        return pb
    end}}
    SNAPSHOT_INTERNALS = nil
    dofile(PLUGIN)
    local I = SNAPSHOT_INTERNALS
    I.H.attach = function() I.setUi({}) return true end
    I.H.now = function() return W.clock end
    I.H.readPen = function() if W.noPen then return nil end
        return {x = W.pen.x, y = W.pen.y, down = W.pen.down, inside = W.pen.inside} end
    W.active = true
    I.H.appActive = function() return W.active end
    I.H.scrollRange = function() return 2195, 2175 end      -- 2 px per point, two pages 960 x 540
    I.H.ensureTimer = function() W.timerAsked = true end
    W.laters = {}
    I.H.later = function(ms, fn) if W.laterNow ~= false then fn() else W.laters[#W.laters + 1] = fn end end
    W.clips = {}
    I.H.toClipboard = function(pic) W.clips[#W.clips + 1] = pic return not W.clipFails end
    return I
end

local function box(x0, y0, x1, y1)   -- freehand-like closed box
    return {x = {x0, x1, x1, x0, x0}, y = {y0, y0, y1, y1, y0}, tool = "pen"}
end

-- ---- pure helpers
local I = world()
local b = I.strokeBox(box(100.4, 50.6, 300.2, 150.1), 960, 540, 10)
check("box snaps outwards to whole points", b and b.x == 100 and b.y == 50 and b.w == 201 and b.h == 101,
      b and (b.x .. "," .. b.y .. "," .. b.w .. "," .. b.h))
b = I.strokeBox(box(-20, -5, 1000, 600), 960, 540, 10)
check("box is clipped to the page", b and b.x == 0 and b.y == 0 and b.w == 960 and b.h == 540)
check("small box is ignored", I.strokeBox(box(10, 10, 15, 200), 960, 540, 10) == nil)
check("stroke without points is ignored", I.strokeBox({x = {}, y = {}}, 960, 540, 10) == nil)
local r = I.pixelRect({x = 100, y = 50, w = 200, h = 100}, 960, 540, 5760, 3240)
check("pixel rectangle scales by 6", r.x == 600 and r.y == 300 and r.w == 1200 and r.h == 600)
r = I.pixelRect({x = 900, y = 500, w = 60, h = 40}, 960, 540, 5759, 3239)
check("pixel rectangle stays inside the picture", r.x + r.w <= 5759 and r.y + r.h <= 3239)
check("export width = page width x sharpness", I.exportWidth(960) == 5760)
check("export width is capped", I.exportWidth(4000) == 8000)

-- ---- copy flow
local BOX = {x = 100, y = 50, w = 200, h = 100}
check("zoom below the sharpness: width unchanged", I.exportWidth(960, 2.87) == 5760)
check("zoomed in: width follows the zoom (x 1.25)", I.exportWidth(960, 6) == 7200)
check("zoomed in far: capped", I.exportWidth(960, 10) == 8000)
I = world({})
initUi()
check("two menu entries, F8 = rectangle mode, F9 = window", #W.reg == 2 and W.reg[1].accelerator == "<Control><Alt>F8"
      and W.reg[1].callback == "snapshotRect" and W.reg[2].accelerator == "<Control><Alt>F9")
local msg, err = I.copyBox(BOX, 2, 960, 540)
check("flow succeeds", msg ~= nil, err)
local e = W.exports[1]
check("export: given page, with background, 5760 px", e and e.range == "2" and e.background == "all" and e.pngWidth == 5760)
local c = W.crops[1]
check("crop rectangle", c and c.x == 600 and c.y == 300 and c.w == 1200 and c.h == 600, c and (c.x .. "," .. c.y .. "," .. c.w .. "," .. c.h))
local im = W.images[1] and W.images[1].images[1]
check("picture placed on the original, same size", im and im.x == 100 and im.y == 50 and im.maxWidth == 200 and im.maxHeight == 100 and im.aspectRatio == false)
check("size passed as whole numbers", im and math.type(im.maxWidth) == "integer" and math.type(im.maxHeight) == "integer")
check("one undo step for the picture", W.images[1] and W.images[1].allowUndoRedoAction == "grouped")
check("cut file existed when inserted", W.cutExisted == true)
check("picture is selected", W.selected and #W.selected == 1)
check("temp files removed", io.open(e.outputFile, "rb") == nil and io.open(W.saves[1], "rb") == nil,
      tostring(e.outputFile) .. " | " .. tostring(W.saves[1]))
check("the cut picture goes to the clipboard, once", #W.clips == 1 and W.clips[1].fake == true and err == true, #W.clips)
check("log line says so", tostring(msg):find("on the clipboard", 1, true) ~= nil, msg)
I = world({})
I.CFG.CLIPBOARD = false
msg, err = I.copyBox(BOX, 2, 960, 540)
check("CLIPBOARD=false: copy made, clipboard untouched", msg ~= nil and #W.clips == 0 and err == false and #W.images == 1)
I.CFG.CLIPBOARD = true
I = world({})
W.clipFails = true
msg, err = I.copyBox(BOX, 2, 960, 540)
check("clipboard failure does not stop the copy", msg ~= nil and #W.images == 1 and err == false
      and tostring(msg):find("on the clipboard", 1, true) == nil, msg)
I = world({})
msg, err = I.copyBox(BOX, 2, 960, 540, 6)
check("zoomed in: sharper export, crop scales with it", W.exports[1].pngWidth == 7200 and W.crops[1].x == 750 and W.crops[1].w == 1500)

-- export that adds the page number to the file name
I = world({numbered = true, page = 1})
msg, err = I.copyBox(BOX, 1, 960, 540)
check("numbered export file is found", msg ~= nil and #W.images == 1, err)
I = world({})
app.addImages = function() return {"cannot load"} end
msg, err = I.copyBox(BOX, 2, 960, 540)
check("addImages error is reported", msg == nil and tostring(err):find("cannot load") ~= nil)

-- ---- layout self-check
I = world({})
app.getZoom = function() return 2 end
app.getDisplayDpi = function() return 120 end
check("scale near zoom x DPI / 72 passes", I.scaleLooksRight(3.31) == true)
check("scale far from it fails", I.scaleLooksRight(2.5) == false)
app.getZoom = nil
check("no zoom API: no complaint", I.scaleLooksRight(2.5) == true)

-- ---- settings file
check("shortcut texts", I.validKey("<Control><Alt>F8") and I.validKey("<Shift>F2") and I.validKey("F9") and I.validKey("none")
      and not I.validKey("Ctrl+F8") and not I.validKey("<Bogus>F8") and not I.validKey(""))
local f = io.open(SNAPSHOT_SETTINGS_FILE, "w")
f:write("# test\nPX_PER_PT=4\nOFFSET_X = 12\nLOG=false\nBOGUS=1\nMIN_SIZE=abc\nKEY_RECT=<Control><Shift>S\nKEY_PANEL=Ctrl+9\n")
f:close()
I = world({})
I.loadSettings()
check("settings file is read", I.CFG.PX_PER_PT == 4 and I.CFG.OFFSET_X == 12 and I.CFG.LOG == false and I.CFG.MIN_SIZE == 10)
check("shortcut from the file; a bad one keeps the default", I.CFG.KEY_RECT == "<Control><Shift>S" and I.CFG.KEY_PANEL == "<Control><Alt>F9")
I.copyBox(BOX, 2, 960, 540)
check("settings are used", W.exports[1].pngWidth == 3840 and W.images[1].images[1].x == 112)
initUi()
check("menu uses the shortcut from the file", W.reg[1].accelerator == "<Control><Shift>S")
f = io.open(SNAPSHOT_SETTINGS_FILE, "r")
local txt = f:read("a")
f:close()
check("file rewritten with every setting", txt:find("KEY_PANEL=<Control><Alt>F9", 1, true) ~= nil and txt:find("ZOOM_HEADROOM=1.25", 1, true) ~= nil)
os.remove(SNAPSHOT_SETTINGS_FILE)


-- ---- rectangle mode (v0.2)
-- view point of a page-2 point: x = 127.5 + 2 * px, y = 1105 + 2 * py - scroll 1000
local function at(px, py, down) W.pen.x, W.pen.y, W.pen.down = 127.5 + 2 * px, 105 + 2 * py, down end
local function step(ms) W.clock = W.clock + (ms or 16) I.tick() end
local function drag(x0, y0, x1, y1)
    at(x0, y0, false) step()
    at(x0, y0, true) step()
    at((x0 + x1) / 2, (y0 + y1) / 2, true) step()
    at(x1, y1, true) step()
    at(x1, y1, false) step()        -- release seen
end

I = world({strokes = {box(5, 5, 50, 50)}})
local d = I.docAt(W.sp, {x = 127.5 + 200, y = 105 + 100})
check("view point -> page point", d and d.i == 2 and math.abs(d.x - 100) < 1e-9 and math.abs(d.y - 50) < 1e-9,
      d and (d.i .. " " .. d.x .. " " .. d.y))
d = I.docAt({x = 0, y = 0, width = 2175, height = 1224}, {x = 127.5 + 20, y = 10 + 30})
check("view point on page 1", d and d.i == 1 and math.abs(d.x - 10) < 1e-9 and math.abs(d.y - 15) < 1e-9)
-- 0.10: the whole document fits in the view (zoom fit on a short document). The scroll area is then the
-- view itself (3000 px, not the 2195 px of pages) and Xournal++ centres the pages in it: 402 px above.
app.getZoom = function() return 1.2 end                 -- 1.2 x 120 / 72 = 2 px per point, as above
app.getDisplayDpi = function() return 120 end
local oldRange = I.H.scrollRange
I.H.scrollRange = function() return 3000, 2175, 3000 end
d = I.docAt({x = 0, y = 0, width = 2175, height = 3000}, {x = 127.5 + 20, y = 402 + 10 + 30})
check("document fits in the view: scale from zoom and DPI, pages centred", d and d.i == 1
      and math.abs(d.x - 10) < 1e-9 and math.abs(d.y - 15) < 1e-9 and math.abs(d.s - 2) < 1e-9,
      d and (d.i .. " " .. d.x .. " " .. d.y .. " s " .. d.s))
d = I.docAt({x = 0, y = 0, width = 2175, height = 3000}, {x = 127.5 + 200, y = 402 + 10 + 1080 + 15 + 100})
check("document fits in the view: page 2 found", d and d.i == 2 and math.abs(d.y - 50) < 1e-9,
      d and (d.i .. " " .. d.y))
check("document fits in the view: no layout warning", I.scaleLooksRight(d and d.s or 0) == true)
app.getZoom, app.getDisplayDpi, I.H.scrollRange = nil, nil, oldRange

check("arm switches to Select Rectangle", I.arm() == true and W.tool == 6 and I.S().mode == "ARMED" and W.timerAsked == true)
at(100, 50, true) step()            -- button still down from the click on the window button
check("a press that began before arming is ignored", I.S().mode == "ARMED")
drag(100, 50, 300, 150)
check("release starts the short wait", I.S().mode == "SETTLE" and #W.images == 0)
step(40)
check("no copy before the wait is over", #W.images == 0)
step(60)
check("copy made after the wait", #W.images == 1 and I.S().mode == "IDLE")
im = W.images[1] and W.images[1].images[1]
check("copy placed on the dragged rectangle", im and im.x == 100 and im.y == 50 and im.maxWidth == 200 and im.maxHeight == 100,
      im and (im.x .. "," .. im.y .. "," .. im.maxWidth .. "," .. im.maxHeight))
check("earlier tool is back", W.tool == 1)
check("tool restored before the picture was selected", W.toolLog[#W.toolLog] == 1 and W.selected and #W.selected == 1)
check("caught strokes released before the export", W.cleared >= 1)
check("no stroke was removed (no undo)", #W.strokes == 1)
check("export of page 2", W.exports[1] and W.exports[1].range == "2")
check("status says copied", I.S().status:find("copied") ~= nil)
check("status names the clipboard", I.S().status:find("also on the clipboard", 1, true) ~= nil, I.S().status)

-- another program in front: a drag there is not the snapshot drag
I = world({page = 2})
I.arm()
W.active = false
drag(100, 50, 300, 150)
step(100)
check("drag in another program is ignored, still armed", I.S().mode == "ARMED" and #W.images == 0, I.S().mode)
W.active = true
drag(100, 50, 300, 150)
step(100)
check("back in Xournal++ the drag copies", #W.images == 1 and I.S().mode == "IDLE", I.S().mode)

-- drag from bottom right to top left gives the same rectangle
I = world({page = 2})
I.arm()
drag(300, 150, 100, 50)
step(100)
im = W.images[1] and W.images[1].images[1]
check("backward drag works", im and im.x == 100 and im.y == 50 and im.maxWidth == 200 and im.maxHeight == 100)

-- drag that leaves the page is clipped to it
I = world({page = 2})
I.arm()
drag(900, 500, 1100, 700)
step(100)
im = W.images[1] and W.images[1].images[1]
check("drag past the page edge is clipped", im and im.x == 900 and im.y == 500 and im.maxWidth == 60 and im.maxHeight == 40)

-- a click (tiny drag) keeps the mode
I = world({page = 2})
I.arm()
drag(100, 50, 102, 52)
step(100)
check("tiny drag: still armed, nothing copied", I.S().mode == "ARMED" and #W.images == 0 and W.tool == 6)
drag(100, 50, 300, 150)
step(100)
check("next drag copies", #W.images == 1 and W.tool == 1)

-- press outside the page area (on the floating window) does not start a drag
I = world({page = 2})
I.arm()
step()
W.pen.inside = false
at(100, 50, true) step()
check("press outside the page area is ignored", I.S().mode == "ARMED")
W.pen.inside = true

-- the page under the drag is not the current page
I = world({page = 1})
I.arm()
drag(100, 50, 300, 150)
step(100)
check("other page becomes current, that page exported on release",
      W.setPage == 2 and #W.exports == 2 and W.exports[1].range == "1" and W.exports[2].range == "2")

-- cancel, tool change, key toggle
I = world({page = 2})
I.arm()
I.disarm(true, "stopped")
check("cancel restores the tool", I.S().mode == "IDLE" and W.tool == 1)
I.arm()
W.tool = 3
step()
check("another tool chosen: mode ends, tool left alone", I.S().mode == "IDLE" and W.tool == 3)
snapshotRect()
check("key arms", I.S().mode == "ARMED" and W.tool == 6)
snapshotRect()
check("key again cancels, tool back", I.S().mode == "IDLE" and W.tool == 3)

-- already on Select Rectangle before arming: stays there
I = world({page = 2})
W.tool = 6
I.arm()
drag(100, 50, 300, 150)
step(100)
check("tool was Select Rectangle before: left as it was", W.tool == 6 and #W.images == 1)

-- pointer lost during the drag: uses the last point seen
I = world({page = 2})
I.arm()
at(100, 50, false) step()
at(100, 50, true) step()
at(300, 150, true) step()
W.noPen = true step()
step(100)
im = W.images[1] and W.images[1].images[1]
check("pointer lost during the drag: last point is used", im and im.maxWidth == 200 and im.maxHeight == 100)

-- 0.8: page list read once per mode, page exported in advance
I = world({page = 2})
I.arm()
check("page exported as soon as the mode starts", #W.exports == 1 and W.exports[1].range == "2" and I.S().pre ~= nil)
local reads = W.structReads
at(100, 50, false) step()
at(100, 50, true) step()
for k = 1, 20 do at(100 + k * 10, 50 + k * 5, true) step() end
check("no page-list read during the drag", W.structReads == reads, tostring(W.structReads) .. " vs " .. tostring(reads))
at(300, 150, false) step()
step(100)
im = W.images[1] and W.images[1].images[1]
check("copy uses the page made in advance (no second export)", #W.exports == 1 and #W.images == 1
      and im and im.x == 100 and im.y == 50 and im.maxWidth == 200 and im.maxHeight == 100,
      #W.exports .. " exports, " .. (im and (im.maxWidth .. "x" .. im.maxHeight) or "no image"))
check("page picture let go after the copy", I.S().pre == nil and I.S().model == nil)

-- a drag that starts before the early export ran: export on release as before
I = world({page = 2})
W.laterNow = false
I.arm()
drag(100, 50, 300, 150)
step(100)
check("drag before the early export: one export, on release", #W.exports == 1 and #W.images == 1)
W.laters[1]()
check("late early export does nothing once the mode ended", #W.exports == 1)

-- zoom changed after the early export: sharper export needed, made on release
I = world({page = 2})
I.arm()
I.H.scrollRange = function() return 3 * 2195, 3 * 2175 end    -- about 6 px per point now
local s6 = (3 * 2195 - 20 - 15) / 1080
W.sp = {x = 0, y = 3000, width = 2175, height = 1224}
local function at4(px, py, down)
    W.pen.x = (3 * 2175 - 960 * s6) / 2 + s6 * px
    W.pen.y = 10 + 15 + 540 * s6 + s6 * py - 3000
    W.pen.down = down
end
at4(100, 50, false) step()
at4(100, 50, true) step()
at4(300, 150, true) step()
at4(300, 150, false) step()
step(100)
check("zoom changed: page exported again at the new sharpness", #W.exports == 2 and #W.images == 1
      and W.exports[2].pngWidth ~= W.exports[1].pngWidth, #W.exports)

-- EARLY_EXPORT off: old behaviour
I = world({page = 2})
I.CFG.EARLY_EXPORT = false
I.arm()
check("EARLY_EXPORT off: nothing exported on arm", #W.exports == 0)
drag(100, 50, 300, 150)
step(100)
check("EARLY_EXPORT off: export on release", #W.exports == 1 and #W.images == 1)
I.CFG.EARLY_EXPORT = true

-- settings are written back
I = world({page = 2})
I.CFG.PANEL_X, I.CFG.PANEL_Y = 321, 123
I.saveSettings()
I = world({page = 2})
I.loadSettings()
check("window position is saved and read back", I.CFG.PANEL_X == 321 and I.CFG.PANEL_Y == 123)
os.remove(SNAPSHOT_SETTINGS_FILE)

out[#out + 1] = (fails == 0 and "ALL PASS " or ("FAILED " .. fails .. " of ")) .. (#out) .. " checks"
return table.concat(out, "\n")
