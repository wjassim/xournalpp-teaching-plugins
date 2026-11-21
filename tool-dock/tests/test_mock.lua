-- Mock test for the tool dock plugin: pure parts only (settings, catalogue, layout, press watch).
-- Run: powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_mock.lua
local PLUGIN = PLUGIN_PATH or ((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\tool-dock\main.lua]])
local TMP = os.getenv("TEMP") or "."
TOOLDOCK_TEST = true
TOOLDOCK_SETTINGS_FILE = TMP .. "\\tooldock_mock_settings.txt"
TOOLDOCK_LOG_FILE = TMP .. "\\tooldock_test.log"
os.remove(TOOLDOCK_SETTINGS_FILE)
os.remove(TOOLDOCK_LOG_FILE)

local out, fails = {}, 0
local function check(name, cond, detail)
    out[#out + 1] = (cond and "PASS " or "FAIL ") .. name .. ((not cond and detail) and ("  -> " .. tostring(detail)) or "")
    if not cond then fails = fails + 1 end
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function show(t) local s = {} for i, v in ipairs(t) do s[i] = tostring(v) end return "{" .. table.concat(s, ",") .. "}" end
local function writeFile(p, s) local f = assert(io.open(p, "w")) f:write(s) f:close() end
local function readFile(p) local f = io.open(p, "r") if not f then return "" end local s = f:read("a") f:close() return s end

app = {C = {Tool_pen = 1, Tool_eraser = 2, Tool_highlighter = 3, Tool_text = 4, Tool_image = 5,
            Tool_selectRect = 6, Tool_selectRegion = 7, Tool_selectObject = 10, Tool_verticalSpace = 12,
            Tool_hand = 13, Tool_drawRect = 14, Tool_drawEllipse = 15, Tool_drawArrow = 16,
            Tool_drawSpline = 20, Tool_laserPointerPen = 23, Tool_laserPointerHighlighter = 24, Tool_latex = 26}}
function app.registerUi() end

local ok, err = pcall(dofile, PLUGIN)
check("plugin loads", ok, err)
local I = TOOLDOCK_INTERNALS or {}
check("internals exposed", I.parseTools ~= nil)

-- ---------------------------------------------------------------- Task 1: catalogue + settings
if I.parseTools then
    check("parseTools keeps known ids in order", same(I.parseTools("eraser, pen"), {"eraser", "pen"}), show(I.parseTools("eraser, pen")))
    check("parseTools drops unknown and duplicates", same(I.parseTools("pen,bogus,pen"), {"pen"}), show(I.parseTools("pen,bogus,pen")))
    check("parseTools empty is empty", #I.parseTools("") == 0)
    check("parseColours reads hex", same(I.parseColours("000000,1E5AE6"), {0x000000, 0x1E5AE6}))
    check("parseColours drops bad and duplicates", same(I.parseColours("12345G,ff0000,FF0000,12345"), {0xFF0000}), show(I.parseColours("12345G,ff0000,FF0000,12345")))
    check("parseColours accepts #", same(I.parseColours("#00A000"), {0x00A000}))
    check("colourText pads", I.colourText(0x00A000) == "00A000", I.colourText(0x00A000))
    check("catalogue has 43 entries", #I.CATALOGUE == 43, #I.CATALOGUE)
    local nTools, nCmd, nLine, ids, okShape = 0, 0, 0, {}, true
    for _, e in ipairs(I.CATALOGUE) do
        if e.lineStyle then nLine = nLine + 1
        elseif e.action or e.helper or e.menu then nCmd = nCmd + 1 else nTools = nTools + 1 end
        local kinds = (e.const and 1 or 0) + (e.action and 1 or 0) + (e.draw and 1 or 0) + (e.menu and 1 or 0)
                      + (e.lineStyle and 1 or 0)
        if ids[e.id] or not e.icon or not e.label or kinds ~= 1 then okShape = false end
        ids[e.id] = true
    end
    check("22 tools + 17 commands + 4 line styles", nTools == 22 and nCmd == 17 and nLine == 4, nTools .. " + " .. nCmd .. " + " .. nLine)
    check("every entry: own id, icon, label, ONE of tool / command / drawing mode", okShape)
    check("commands need app.activateAction", I.available("zoomIn") == false)
    app.activateAction = function() end
    check("commands available with app.activateAction", I.available("zoomIn") and I.available("undo"))
    app.activateAction = nil
    check("axes = a drawing mode of the pen", I.catalogueEntry("drawAxes").draw == "tool-draw-coordinate-system"
          and I.catalogueEntry("drawArrow").draw == "tool-draw-arrow" and I.catalogueEntry("drawRect").const == nil)
    check("drawing modes available with pen + changeActionState", I.available("drawAxes") == (app.changeActionState ~= nil))
    check("parseTools knows the new ids", same(I.parseTools("zoomIn,drawAxes,ruler,undo"), {"zoomIn", "drawAxes", "ruler", "undo"}))
    check("ruler is a drawing mode listed with the helpers", I.catalogueEntry("ruler").draw == "tool-draw-line" and I.catalogueEntry("ruler").helper == true)
    check("catalogue laserPen const", I.catalogueEntry("laserPen").const == "Tool_laserPointerPen")
    check("default tools", same(I.CFG.TOOLS, {"pen", "laserPen", "selectObject", "eraser"}), show(I.CFG.TOOLS))
    check("default colours", same(I.CFG.COLOURS, {0x000000, 0x1E5AE6, 0xE00000, 0x00A000}))
    check("default key F12", I.CFG.KEY_DOCK == "<Control><Alt>F12")

    -- no file: nil
    check("no settings file: nil", I.loadSettings() == nil)
    -- bad values clamp / fall back, missing keys counted
    writeFile(TOOLDOCK_SETTINGS_FILE, "PER_ROW=0\nSIZE=huge\nSHAPE=round\nTOOLS=eraser,bogus\nCOLOURS=zz,0000FF\nKEY_DOCK=F9\n")
    local seen = I.loadSettings()
    check("PER_ROW 0 clamps to 1", I.CFG.PER_ROW == 1, I.CFG.PER_ROW)
    check("bad SIZE keeps default", I.CFG.SIZE == "medium", I.CFG.SIZE)
    check("bad SHAPE keeps default", I.CFG.SHAPE == "horizontal", I.CFG.SHAPE)
    check("TOOLS read", same(I.CFG.TOOLS, {"eraser"}), show(I.CFG.TOOLS))
    check("COLOURS read", same(I.CFG.COLOURS, {0x0000FF}))
    check("bad key keeps default", I.CFG.KEY_DOCK == "<Control><Alt>F12", I.CFG.KEY_DOCK)
    check("seen counts known keys", seen == 6, seen)
    check("fewer seen than defaults", seen < I.settingCount())
    -- empty lists are kept empty (user removed everything)
    writeFile(TOOLDOCK_SETTINGS_FILE, "TOOLS=\nCOLOURS=\nPER_ROW=99\n")
    I.resetDefaults()
    I.loadSettings()
    check("empty TOOLS stays empty", #I.CFG.TOOLS == 0)
    check("empty COLOURS stays empty", #I.CFG.COLOURS == 0)
    check("PER_ROW 99 clamps to 12", I.CFG.PER_ROW == 12, I.CFG.PER_ROW)
    -- round trip
    I.resetDefaults()
    I.CFG.TOOLS = {"pen", "highlighter"}
    I.CFG.COLOURS = {0x123456}
    I.CFG.SHAPE = "rectangle"
    I.CFG.PANEL_X, I.CFG.PANEL_Y = 40, 50
    I.saveSettings()
    local txt = readFile(TOOLDOCK_SETTINGS_FILE)
    check("saved TOOLS line", txt:find("TOOLS=pen,highlighter\n", 1, true) ~= nil, txt)
    check("saved COLOURS line", txt:find("COLOURS=123456\n", 1, true) ~= nil)
    I.resetDefaults()
    local s2 = I.loadSettings()
    check("round trip tools", same(I.CFG.TOOLS, {"pen", "highlighter"}))
    check("round trip shape", I.CFG.SHAPE == "rectangle")
    check("round trip place", I.CFG.PANEL_X == 40 and I.CFG.PANEL_Y == 50)
    check("round trip sees every key", s2 == I.settingCount(), s2)
    -- defaults are not changed by edits of CFG lists
    I.resetDefaults()
    table.insert(I.CFG.TOOLS, "hand")
    I.resetDefaults()
    check("resetDefaults gives fresh lists", #I.CFG.TOOLS == 4)
    -- a tool missing from app.C
    local saved = app.C.Tool_latex
    app.C.Tool_latex = nil
    check("available() false when const missing", not I.available("latex"))
    app.C.Tool_latex = saved
    check("available() true when const present", I.available("latex"))
end

-- ---------------------------------------------------------------- Task 3: layout
if I.layoutCells then
    local function cell(cells, kind, index)
        for _, c in ipairs(cells) do if c.kind == kind and (index == nil or c.index == index) then return c end end
    end
    local function allRow(cells, r) for _, c in ipairs(cells) do if c.row ~= r then return false end end return true end
    local h = I.layoutCells(4, 4, "horizontal", 4)
    check("horizontal one row", allRow(h, 0) and #h == 11, #h)
    check("horizontal order", cell(h, "line").col == 4 and cell(h, "colour", 1).col == 5 and cell(h, "plus").col == 9 and cell(h, "shape").col == 10)
    local v = I.layoutCells(4, 4, "vertical", 4)
    check("vertical one column", (function() for _, c in ipairs(v) do if c.col ~= 0 then return false end end return true end)())
    check("vertical shape last", cell(v, "shape").row == 10)
    local r = I.layoutCells(5, 4, "rectangle", 4)
    check("rectangle tool 5 wraps", cell(r, "tool", 5).row == 1 and cell(r, "tool", 5).col == 0)
    check("rectangle line own row full width", cell(r, "line").row == 2 and cell(r, "line").span == 4)
    check("rectangle colours start on a new row after the line", cell(r, "colour", 1).row == 3 and cell(r, "colour", 1).col == 0)
    check("rectangle plus and shape share last row", cell(r, "plus").row == 4 and cell(r, "shape").row == 4 and cell(r, "shape").col == 1)
    local e = I.layoutCells(0, 0, "vertical", 4)
    check("no tools still has plus and shape", cell(e, "plus") ~= nil and cell(e, "shape") ~= nil and #e == 2, #e)
    local t = I.layoutCells(3, 0, "horizontal", 4)
    check("no colours: no line", cell(t, "line") == nil and #t == 5, #t)
    local c = I.layoutCells(0, 2, "rectangle", 4)
    check("no tools: no line, colours first row", cell(c, "line") == nil and cell(c, "colour", 1).row == 0)
    local w = I.layoutCells(2, 2, "rectangle", 1)
    check("rectangle per row 1 = vertical-like", cell(w, "tool", 2).row == 1 and cell(w, "shape").row == 6, cell(w, "shape").row)
    -- v0.2: grip + line thickness button
    local O = {grip = true, size = true}
    local hg = I.layoutCells(4, 4, "horizontal", 4, O)
    check("grip first in horizontal", cell(hg, "grip").col == 0 and cell(hg, "tool", 1).col == 1, cell(hg, "grip").col)
    check("size after the tools", cell(hg, "size").col == 5 and cell(hg, "line").col == 6 and cell(hg, "size").index == nil)
    check("horizontal with grip + size: 13 cells, one row", #hg == 13 and allRow(hg, 0), #hg)
    local vg = I.layoutCells(4, 4, "vertical", 4, O)
    check("grip on top in vertical", cell(vg, "grip").row == 0 and cell(vg, "tool", 1).row == 1)
    local rg = I.layoutCells(4, 4, "rectangle", 4, O)
    check("rectangle grip row 0 full width", cell(rg, "grip").row == 0 and cell(rg, "grip").span == 4)
    check("rectangle size wraps after 4 tools", cell(rg, "tool", 1).row == 1 and cell(rg, "size").row == 2 and cell(rg, "size").col == 0)
    check("rectangle line after size row", cell(rg, "line").row == 3 and cell(rg, "colour", 1).row == 4)
    local so = I.layoutCells(0, 2, "horizontal", 4, {size = true})
    check("size alone + colours gets the line", cell(so, "line") ~= nil and cell(so, "size").col == 0)
    local ng = I.layoutCells(2, 0, "horizontal", 4, {grip = true})
    check("no size option: no size cell", cell(ng, "size") == nil and #ng == 5, #ng)
end

-- ---------------------------------------------------------------- Task 6: press watch
if I.pressWatch then
    local P = I.pressWatch
    local st = {}
    check("idle: nil", P(st, false, false, 0) == nil)
    check("press starts: nil", P(st, true, false, 100) == nil)
    check("held 300 ms: nil", P(st, true, false, 400) == nil)
    check("held 700 ms: long", P(st, true, false, 800) == "long")
    check("long reported once", P(st, true, false, 900) == nil)
    check("release after long: consumed", st.consumed == true)
    P(st, false, false, 1000)
    check("release tick: still consumed (its click is ignored)", st.consumed == true)
    P(st, false, false, 1030)
    check("next tick: consumed cleared", st.consumed == false)
    local s2 = {}
    check("right button over it: right", P(s2, false, true, 0) == "right")
    check("right held: reported once", P(s2, false, true, 30) == nil)
    P(s2, false, false, 60)
    check("right again after release", P(s2, false, true, 90) == "right")
    local s3 = {}
    P(s3, true, false, 0)
    P(s3, false, false, 200)
    check("short press not consumed", s3.consumed == false)
end

-- ---------------------------------------------------------------- review fixes
check("hasPlace: negative place (monitor left of the main one) is a real place", I.hasPlace and I.hasPlace(-1500, 20) == true)
check("hasPlace: -1, -1 is a real place", I.hasPlace and I.hasPlace(-1, -1) == true)
check("hasPlace: unset is not a place", I.hasPlace and I.hasPlace(I.CFG and I.DEFAULTS.PANEL_X, I.DEFAULTS.PANEL_Y) == false)
if I.rightEdge then
    local s = {}
    check("right: press starting over the dock counts", I.rightEdge(s, true, true) == true)
    check("right: held does not count again", I.rightEdge(s, true, true) == false)
    I.rightEdge(s, false, true)
    local d = {}
    check("right: drag from the page, outside the dock", I.rightEdge(d, true, false) == false)
    check("right: same drag now over the dock does not count", I.rightEdge(d, true, true) == false)
    local o = {}
    check("right: press while another window covers the dock", I.rightEdge(o, true, false) == false)
else
    check("rightEdge exists", false)
end


-- ---------------------------------------------------------------- 0.7: custom buttons (keys of 0.6 gone)
if I.customIndex then
    check("0.6 keys gone", I.registerKeys == nil and I.KEYS == nil and I.CFG.KEY_SLOTS == nil)
    check("customIndex", I.customIndex("custom1") == 1 and I.customIndex("custom40") == 40
          and I.customIndex("custom41") == nil and I.customIndex("custom0") == nil and I.customIndex("pen") == nil)
    check("plainLabel strips mnemonics", I.plainLabel("_Pen") == "Pen" and I.plainLabel("Recent__Documents") == "Recent_Documents"
          and I.plainLabel("N_ext Annotated Page") == "Next Annotated Page" and I.plainLabel(nil) == "")
    local c = I.parseCustom("Plugin|Auto zoom: ON / OFF|Ctrl+Alt+F5")
    check("parseCustom: group, label, key", c and c.group == "Plugin" and c.label == "Auto zoom: ON / OFF" and c.key == "Ctrl+Alt+F5")
    local c2 = I.parseCustom("Plugin|Check Page Step|")
    check("parseCustom: no key", c2 and c2.key == nil and c2.label == "Check Page Step")
    check("parseCustom: bad", I.parseCustom("nothing") == nil and I.parseCustom("Edit|") == nil)
    check("parseTools keeps customN", same(I.parseTools("pen,custom3,custom99"), {"pen", "custom3"}),
          show(I.parseTools("pen,custom3,custom99")))
    os.remove(TOOLDOCK_LOG_FILE)
    writeFile(TOOLDOCK_SETTINGS_FILE, table.concat({
        "TOOLS=pen,custom1,custom2,custom5,eraser",
        "CUSTOM1=Plugin|Auto zoom: ON / OFF|Ctrl+Alt+F5",
        "CUSTOM2=Edit|Undo|Ctrl+Z",
        "CUSTOM3=Edit|Redo|Ctrl+Y",            -- not in TOOLS: dropped
        "CUSTOM4=bad",                         -- bad: logged
        "KEY_pen=<Control><Alt>6",             -- 0.6 line: ignored
        "KEY_SLOTS=true", ""}, "\n"))
    I.resetDefaults()
    I.loadSettings()
    check("custom: read; one without its line dropped from TOOLS", same(I.CFG.TOOLS, {"pen", "custom1", "custom2", "eraser"}),
          show(I.CFG.TOOLS))
    check("custom: one not on the dock dropped", I.CUSTOM[1] and I.CUSTOM[2] and I.CUSTOM[3] == nil and I.CUSTOM[4] == nil)
    check("custom: bad line logged", readFile(TOOLDOCK_LOG_FILE):find("CUSTOM4", 1, true) ~= nil)
    check("custom: available", I.available("custom1") and not I.available("custom3"))
    local e = I.entryOf("custom1")
    check("custom: auto zoom gets the magnifier and the ON flag", e and e.icon == "system-search-symbolic"
          and e.env == "XOPP_AUTOZOOM_ON" and e.custom == I.CUSTOM[1])
    I.CUSTOM[7] = {group = "Plugin", label = "Snapshot: drag a rectangle (on / off)", key = "Ctrl+Alt+F8"}
    local s7 = I.entryOf("custom7")
    check("custom: snapshot gets the camera and the XOPP_SNAPSHOT_ON flag (0.8.2)", s7 and s7.icon == "camera-photo-symbolic"
          and s7.env == "XOPP_SNAPSHOT_ON")
    I.CUSTOM[7] = nil
    local u = I.entryOf("custom2")
    check("custom: Undo gets the catalogue's undo icon", u and u.icon == "xopp-edit-undo" and u.short == "Z", u and u.short)
    I.CUSTOM[6] = {group = "Plugin", label = "Snapshot: show the floating window", key = "Ctrl+Alt+F9"}
    local s6 = I.entryOf("custom6")
    check("custom: unknown entry = text of its shortcut", s6.icon == nil and s6.short == "F9", s6.short)
    I.CUSTOM[6] = {group = "View", label = "Zoom In", key = "Ctrl++"}
    check("custom: Ctrl++ shows +, catalogue icon", I.entryOf("custom6").short == "+" and I.entryOf("custom6").icon == "zoom-in-symbolic",
          I.entryOf("custom6").short)
    I.CUSTOM[6] = {group = "Plugin", label = "Check Page Step"}
    check("custom: no shortcut = 3 letters", I.entryOf("custom6").short == "Che")
    I.CUSTOM[6] = nil
    -- add / remove
    local n = I.addCustom({group = "Tools", label = "Pen", key = "Shift+Ctrl+P"})
    check("custom: add takes the first free number", n == 3 and I.CFG.TOOLS[#I.CFG.TOOLS] == "custom3", n)
    check("custom: Pen gets the pen icon", I.entryOf("custom3").icon == "xopp-tool-pencil")
    I.saveSettings()
    local txt = readFile(TOOLDOCK_SETTINGS_FILE)
    check("custom: saved", txt:find("CUSTOM1=Plugin|Auto zoom: ON / OFF|Ctrl+Alt+F5\n", 1, true)
          and txt:find("CUSTOM3=Tools|Pen|Shift+Ctrl+P\n", 1, true) and txt:find("TOOLS=pen,custom1,custom2,eraser,custom3\n", 1, true)
          and not txt:find("KEY_pen", 1, true) and not txt:find("KEY_SLOTS", 1, true), txt)
    I.removeCustom("custom1")
    check("custom: removed", I.CUSTOM[1] == nil and same(I.CFG.TOOLS, {"pen", "custom2", "eraser", "custom3"}), show(I.CFG.TOOLS))
    I.saveSettings()
    I.resetDefaults()
    I.loadSettings()
    check("custom: read back", I.CUSTOM[1] == nil and I.CUSTOM[2].label == "Undo" and I.CUSTOM[3].label == "Pen"
          and same(I.CFG.TOOLS, {"pen", "custom2", "eraser", "custom3"}), show(I.CFG.TOOLS))
    I.resetDefaults()
    check("custom: reset clears", next(I.CUSTOM) == nil)
    local nT, allIds = 0, true
    for lab, id in pairs(I.TICK_BOX_OF) do
        nT = nT + 1
        if not I.catalogueEntry(id) or lab ~= lab:lower() then allIds = false end
    end
    check("custom list hides 30 tick-box entries, each a catalogue id", nT == 30 and allIds, nT)
else
    check("customIndex exists", false)
end

-- ---------------------------------------------------------------- 0.6: auto zoom button
if I.catalogueEntry then
    local e = I.catalogueEntry("autozoom")
    check("autozoom: catalogue entry = the autozoom plugin's menu entry", e and e.menu == "Auto zoom: ON / OFF"
          and e.plugin == "autozoom" and e.env == "XOPP_AUTOZOOM_ON")
    check("autozoom: available only when the plugin is installed", I.available("autozoom") == I.pluginInstalled("autozoom"))
    local pz = I.catalogueEntry("autozoomPause")
    check("autozoom pause: catalogue entry = autozoom 0.16's pause menu entry, lit while paused",
          pz and pz.menu == "Auto zoom: pause zoom in / out" and pz.plugin == "autozoom" and pz.env == "XOPP_AUTOZOOM_PAUSED")
    check("autozoom pause: available only when the plugin is installed", I.available("autozoomPause") == I.pluginInstalled("autozoom"))
end
-- 0.7.5: carry ink buttons = preserve-view 2.8's menu entries
if I.catalogueEntry then
    local c, k = I.catalogueEntry("carryInk"), I.catalogueEntry("clearInk")
    check("carry ink: catalogue entry", c and c.menu == "Carry ink: on / off" and c.plugin == "preserve-view"
          and c.env == "XOPP_CARRYINK_ON")
    check("clear page ink: catalogue entry", k and k.menu == "Clear page ink" and k.plugin == "preserve-view" and k.env == nil)
    check("carry ink: available only with preserve-view", I.available("carryInk") == I.pluginInstalled("preserve-view"))
end

-- 0.8: pen line styles
if I.catalogueEntry and I.useTool then
    local styles = {}
    for _, e in ipairs(I.CATALOGUE) do if e.lineStyle then styles[#styles + 1] = e.lineStyle end end
    check("line styles: plain, dash, dashdot, dot", same(styles, {"plain", "dash", "dashdot", "dot"}), show(styles))
    check("line style ids parse", same(I.parseTools("lineDash,lineDot"), {"lineDash", "lineDot"}))
    local saved = {app.changeActionState, app.getActionState}
    app.changeActionState = nil
    check("line styles need changeActionState", I.available("lineDash") == false)
    local tool, style, calls = 2, "plain", {}
    app.changeActionState = function(a, v)
        calls[#calls + 1] = a .. "=" .. tostring(v)
        if a == "select-tool" then tool = v elseif a == "tool-pen-line-style" then style = v end
    end
    app.getActionState = function(a) if a == "select-tool" then return tool end end
    check("line styles available with changeActionState", I.available("lineDash") == true)
    I.useTool("lineDash")
    check("line style from the eraser: pen first, then dashed", tool == 1 and style == "dash"
          and calls[1] == "select-tool=1" and calls[2] == "tool-pen-line-style=dash", table.concat(calls, " | "))
    calls = {}
    I.useTool("lineDot")
    check("line style on the pen: only the style changes", #calls == 1 and style == "dot", table.concat(calls, " | "))
    app.changeActionState, app.getActionState = saved[1], saved[2]
end

-- 0.8: move a tool or colour earlier / later (tools this build lacks are stepped over)
if I.moveItem then
    I.CFG.TOOLS = {"pen", "link", "eraser", "hand"}         -- link: not in this fake app.C
    check("move: link is not available here", I.available("link") == false)
    check("move: first tool cannot go earlier", I.moveTarget({kind = "tool", id = "pen"}, -1) == nil)
    check("move: pen later skips link", I.moveItem({kind = "tool", id = "pen"}, 1)
          and same(I.CFG.TOOLS, {"eraser", "link", "pen", "hand"}), show(I.CFG.TOOLS))
    check("move: hand earlier", I.moveItem({kind = "tool", id = "hand"}, -1)
          and same(I.CFG.TOOLS, {"eraser", "link", "hand", "pen"}), show(I.CFG.TOOLS))
    check("move: last tool cannot go later", I.moveTarget({kind = "tool", id = "pen"}, 1) == nil)
    check("move: eraser earlier: nothing before it on the dock", I.moveItem({kind = "tool", id = "eraser"}, -1) == false)
    I.CFG.COLOURS = {0x000000, 0xE00000, 0x00A000}
    check("move: colour later", I.moveItem({kind = "colour", colour = 0x000000}, 1)
          and same(I.CFG.COLOURS, {0xE00000, 0x000000, 0x00A000}), show(I.CFG.COLOURS))
    check("move: last colour cannot go later", I.moveTarget({kind = "colour", colour = 0x00A000}, 1) == nil)
    check("move: thickness button never moves", I.moveTarget({kind = "size"}, 1) == nil)
    I.resetDefaults()
else
    check("moveItem exists", false)
end

for _, l in ipairs(out) do print(l) end
print(fails == 0 and "all checks passed" or (fails .. " FAILED"))
os.remove(TOOLDOCK_SETTINGS_FILE)
return fails == 0 and "ok" or "failed"
