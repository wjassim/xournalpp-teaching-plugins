-- Smoke test: the tool dock with the REAL LuaGObject, GLib timer and GTK widgets, a fake `app`
-- and a fake main window (a canvas named "GtkXournal"). Windows show for a few seconds and close.
-- Run: powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_gtk_smoke.lua
local TMP = os.getenv("TEMP") or "."
TOOLDOCK_TEST = true
TOOLDOCK_SETTINGS_FILE = TMP .. "\\tooldock_smoke_settings.txt"
TOOLDOCK_LOG_FILE = TMP .. "\\tooldock_smoke.log"
TOOLDOCK_PLUGINS_DIR = (os.getenv("LOCALAPPDATA") or "."):gsub(string.char(92), "/") .. "/xournalpp/plugins"   -- autozoom is installed there
TOOLDOCK_OTHER_SETTINGS = {}
os.remove(TOOLDOCK_SETTINGS_FILE)
os.remove(TOOLDOCK_LOG_FILE)

local out, fails = {}, 0
local function check(name, cond, detail)
    out[#out + 1] = (cond and "PASS " or "FAIL ") .. name .. ((not cond and detail ~= nil) and ("  -> " .. tostring(detail)) or "")
    if not cond then fails = fails + 1 end
end
local function readFile(p) local f = io.open(p, "r") if not f then return "" end local s = f:read("a") f:close() return s end

-- fake app ------------------------------------------------------------------
TOOL, COLOR, PENCOLOR, CALLS, SIZE = 23, 0x008000, 0x000000, {}, 1
local NOCOLOUR = {[2] = true, [10] = true, [13] = true, [6] = true, [7] = true}
app = {C = {Tool_pen = 1, Tool_eraser = 2, Tool_highlighter = 3, Tool_text = 4, Tool_image = 5,
            Tool_selectRect = 6, Tool_selectRegion = 7, Tool_selectObject = 10, Tool_verticalSpace = 12,
            Tool_hand = 13, Tool_drawRect = 14, Tool_drawEllipse = 15, Tool_drawArrow = 16,
            Tool_drawSpline = 20, Tool_laserPointerPen = 23, Tool_laserPointerHighlighter = 24, Tool_latex = 26,
            ToolSize_veryThin = 0, ToolSize_thin = 1, ToolSize_medium = 2, ToolSize_thick = 3, ToolSize_veryThick = 4}}
function app.registerUi() end
function app.openDialog(m) CALLS[#CALLS + 1] = "dialog " .. tostring(m) end
function app.getActionState(a)
    if a == "select-tool" then return TOOL end
    if a == "tool-size" or a == "tool-pen-size" then return SIZE end
    if a == "tool-color" then
        if NOCOLOUR[TOOL] then return 0xFFFFFFFF end
        return 0xFF000000 | (TOOL == 1 and PENCOLOR or COLOR)
    end
end
function app.changeActionState(a, v)
    CALLS[#CALLS + 1] = "state " .. a .. "=" .. tostring(v)
    if a == "select-tool" then TOOL = v end
    if a == "tool-size" or a == "tool-pen-size" then SIZE = v end
end
function app.changeToolColor(o)
    CALLS[#CALLS + 1] = string.format("colour %06X tool=%s sel=%s", o.color, tostring(o.tool), tostring(o.selection))
    if o.tool == "pen" then PENCOLOR = o.color return end
    if NOCOLOUR[TOOL] then error("tool has no color capability") end
    if TOOL == 1 then PENCOLOR = o.color else COLOR = o.color end
end
function app.getToolInfo(t) if t == "pen" then return {color = PENCOLOR} end return {} end
STATES = {["grid-snapping"] = false}
DRAWS = {"tool-draw-line", "tool-draw-rectangle", "tool-draw-ellipse", "tool-draw-arrow", "tool-draw-double-arrow",
         "tool-draw-coordinate-system", "tool-draw-spline", "tool-draw-shape-recognizer"}
MODE = {[1] = nil, [3] = nil}                  -- drawing mode per tool (pen 1, highlighter 3), as Xournal++ keeps it
for _, a in ipairs(DRAWS) do STATES[a] = true end   -- marker: a drawing mode (state comes from MODE)
function app.activateAction(a)
    CALLS[#CALLS + 1] = "action " .. a
    if STATES[a] ~= nil then STATES[a] = not STATES[a] end
end
app.C.Tool_drawCoordinateSystem, app.C.Tool_drawDoubleArrow = 18, 17
local isDraw = {}
for _, a in ipairs(DRAWS) do isDraw[a] = true STATES[a] = nil end
local realState = app.getActionState
function app.getActionState(a)
    if isDraw[a] then return (TOOL == 1 or TOOL == 3) and MODE[TOOL] == a end
    if STATES[a] ~= nil then return STATES[a] end
    return realState(a)
end
local realChange = app.changeActionState
function app.changeActionState(a, v)
    if isDraw[a] then
        CALLS[#CALLS + 1] = "state " .. a .. "=" .. tostring(v)
        if TOOL == 1 or TOOL == 3 then
            if v then MODE[TOOL] = a elseif MODE[TOOL] == a then MODE[TOOL] = nil end
        end
        return
    end
    return realChange(a, v)
end

dofile((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\tool-dock\main.lua]])
local I = TOOLDOCK_INTERNALS
local lgo = require("LuaGObject")
local GLib, Gtk = lgo.GLib, lgo.require("Gtk", "3.0")
Gtk.init()
local main = Gtk.Window {title = "tool dock self-test (closes itself)", default_width = 500, default_height = 300}
local sw = Gtk.ScrolledWindow {}
local da = Gtk.DrawingArea {}
da:set_name("GtkXournal")
sw:add(da) main:add(sw) main:show_all()

local function find(w, name)
    if w:get_name() == name then return w end
    if Gtk.Container:is_type_of(w) then
        for _, k in ipairs(w:get_children()) do
            local r = find(k, name)
            if r then return r end
        end
    end
end
local function count(w, prefix)
    local n = 0
    local function go(x)
        if (x:get_name() or ""):sub(1, #prefix) == prefix then n = n + 1 end
        if Gtk.Container:is_type_of(x) then for _, k in ipairs(x:get_children()) do go(k) end end
    end
    go(w)
    return n
end
local function dockWin() local d = I.dock() return d and d.win end
local function editWin() local e = I.edit() return e and e.win end
local function lastCalls(n) local t = {} for i = math.max(1, #CALLS - n + 1), #CALLS do t[#t + 1] = CALLS[i] end return table.concat(t, " | ") end

local loop = GLib.MainLoop()
local T = 0
local function at(ms, fn)
    T = T + ms
    GLib.timeout_add(GLib.PRIORITY_DEFAULT, T, function()
        local ok, e = pcall(fn)
        if not ok then check("no error at " .. T, false, e) end
        return false
    end)
end

-- A. open, buttons, tool + colour clicks, highlight
at(300, function()
    toolDockToggle()
    check("A dock opens", dockWin() ~= nil and dockWin():get_visible())
    check("A 4 tools", count(dockWin(), "td_tool_") == 4, count(dockWin(), "td_tool_"))
    check("A 4 colours", count(dockWin(), "td_colour_") == 4, count(dockWin(), "td_colour_"))
    check("A plus + shape", find(dockWin(), "td_plus") ~= nil and find(dockWin(), "td_shape") ~= nil)
    check("A no dialog", #CALLS == 0, lastCalls(3))
    find(dockWin(), "td_tool_pen"):set_active(true)
end)
at(200, function()
    check("A pen click switches tool", TOOL == 1, lastCalls(2))
    check("A pen button springs back", not find(dockWin(), "td_tool_pen"):get_active())
    find(dockWin(), "td_colour_3"):set_active(true)      -- red on the pen
end)
at(200, function()
    check("A red colours the pen", PENCOLOR == 0xE00000, lastCalls(2))
    check("A colour call has selection=true", lastCalls(1):find("sel=true", 1, true) ~= nil, lastCalls(1))
    TOOL = 10                                              -- select object, no colour
    find(dockWin(), "td_colour_2"):set_active(true)      -- blue
end)
at(250, function()
    check("A blue with select tool: pen colour + selection", PENCOLOR == 0x1E5AE6 and lastCalls(1):find("tool=pen sel=true", 1, true) ~= nil, lastCalls(2))
    TOOL = 1
end)
at(400, function()
    local ctx = find(dockWin(), "td_tool_pen"):get_style_context()
    check("A active tool highlighted", ctx:has_class("td-on"))
    check("A other tool not highlighted", not find(dockWin(), "td_tool_eraser"):get_style_context():has_class("td-on"))
    check("A current colour highlighted (blue)", find(dockWin(), "td_colour_2"):get_style_context():has_class("td-on"))
    find(dockWin(), "td_shape"):set_active(true)
end)
-- B. shape cycle
at(900, function()
    check("B shape -> vertical", I.CFG.SHAPE == "vertical", I.CFG.SHAPE)
    local w, h = dockWin():get_size()
    check("B vertical is taller than wide", h > w, w .. "x" .. h)
    check("B still 4 tools after rebuild", count(dockWin(), "td_tool_") == 4)
    find(dockWin(), "td_shape"):set_active(true)
end)
at(300, function()
    check("B shape -> rectangle", I.CFG.SHAPE == "rectangle")
    find(dockWin(), "td_shape"):set_active(true)
end)
at(900, function()
    check("B shape -> horizontal", I.CFG.SHAPE == "horizontal")
    local w, h = dockWin():get_size()
    check("B horizontal is wider than tall", w > h, w .. "x" .. h)
    find(dockWin(), "td_plus"):set_active(true)
end)
-- C. edit list
at(400, function()
    check("C edit list opens", editWin() ~= nil and editWin():get_visible())
    check("C plus springs back", not find(dockWin(), "td_plus"):get_active())
    check("C 33 ticks (tools this fake app knows + commands + drawing modes + auto zoom)", count(editWin(), "td_e_tool_") == 33, count(editWin(), "td_e_tool_"))
    check("C eraser ticked", find(editWin(), "td_e_tool_eraser"):get_active())
    find(editWin(), "td_e_tool_eraser"):set_active(false)
end)
at(250, function()
    check("C untick eraser removes it", count(dockWin(), "td_tool_") == 3 and find(dockWin(), "td_tool_eraser") == nil)
    find(editWin(), "td_e_tool_highlighter"):set_active(true)
end)
at(250, function()
    check("C tick highlighter adds it last", I.CFG.TOOLS[#I.CFG.TOOLS] == "highlighter", table.concat(I.CFG.TOOLS, ","))
    find(editWin(), "td_e_rm_2"):set_active(true)          -- remove blue
end)
at(250, function()
    check("C remove blue", #I.CFG.COLOURS == 3 and I.CFG.COLOURS[2] == 0xE00000)
    check("C dock has 3 colours", count(dockWin(), "td_colour_") == 3)
    check("C edit list shows 3 colours", count(editWin(), "td_e_rm_") == 3, count(editWin(), "td_e_rm_"))
    TOOLDOCK_CHOOSE_COLOUR = function() return 0x123456 end
    find(editWin(), "td_e_add"):set_active(true)
end)
at(250, function()
    check("C add colour appends", I.CFG.COLOURS[#I.CFG.COLOURS] == 0x123456 and #I.CFG.COLOURS == 4)
    find(editWin(), "td_e_add"):set_active(true)          -- the same colour again
end)
at(250, function()
    check("C duplicate colour not added", #I.CFG.COLOURS == 4)
    TOOLDOCK_CHOOSE_COLOUR = function() return nil end     -- user pressed Cancel
    find(editWin(), "td_e_add"):set_active(true)
end)
at(250, function()
    check("C cancel adds nothing", #I.CFG.COLOURS == 4)
    find(editWin(), "td_e_shape_rectangle"):set_active(true)
end)
at(250, function()
    check("C shape rectangle", I.CFG.SHAPE == "rectangle")
    check("C per row enabled for rectangle", find(editWin(), "td_e_perrow"):get_sensitive())
    find(editWin(), "td_e_perrow"):set_value(3)
end)
at(250, function()
    check("C per row 3", I.CFG.PER_ROW == 3, I.CFG.PER_ROW)
    find(editWin(), "td_e_size_large"):set_active(true)
end)
at(300, function()
    check("C size large", I.CFG.SIZE == "large")
    local w = find(dockWin(), "td_tool_pen"):get_allocated_width()
    check("C large tool button is 56 px wide or more", w >= 56, w)
    find(editWin(), "td_e_shape_horizontal"):set_active(true)
    find(editWin(), "td_e_size_medium"):set_active(true)
    find(editWin(), "td_e_atstart"):set_active(true)
end)
at(300, function()
    check("C open at start ticked", I.CFG.DOCK_AT_START == true)
    check("C per row disabled for horizontal", not find(editWin(), "td_e_perrow"):get_sensitive())
    find(editWin(), "td_e_close"):set_active(true)
end)
at(250, function()
    check("C close hides the edit list", I.edit() == nil)
end)
-- D. long press and right-click (pointer input replaced by a fake)
local FAKE = {}
at(100, function()
    I.setPressInput(function(name) local f = FAKE[name] or {} return f.held or false, f.right or false end)
    FAKE.td_colour_1 = {held = true}                        -- black held
end)
at(800, function()
    check("D long press opens the remove box", I.ask() ~= nil)
    FAKE.td_colour_1 = nil                                  -- released
end)
at(150, function()
    check("D long press does not also click", COLOR ~= 0x000000 or lastCalls(1):find("colour 000000", 1, true) == nil, lastCalls(2))
    find(I.ask().win, "td_rm_yes"):set_active(true)
end)
at(250, function()
    check("D remove box gone", I.ask() == nil)
    check("D black removed", I.CFG.COLOURS[1] == 0xE00000 and #I.CFG.COLOURS == 3, #I.CFG.COLOURS)
    FAKE.td_tool_pen = {right = true}
end)
at(200, function()
    check("D right-click opens the remove box", I.ask() ~= nil)
    FAKE.td_tool_pen = nil
    find(I.ask().win, "td_rm_no"):set_active(true)
end)
at(250, function()
    check("D cancel keeps the pen", I.ask() == nil and find(dockWin(), "td_tool_pen") ~= nil)
    FAKE.td_plus = {held = true}                           -- + can never be removed
end)
at(800, function()
    check("D long press on + does nothing", I.ask() == nil)
    FAKE.td_plus = nil
    I.setPressInput(nil)
end)
-- E. saved file, empty dock, missing tool, off screen, close
at(1000, function()
    local s = readFile(TOOLDOCK_SETTINGS_FILE)
    check("E settings saved", s:find("COLOURS=E00000,", 1, true) ~= nil and s:find("DOCK_AT_START=true", 1, true) ~= nil, s:match("COLOURS=[^\n]*"))
    I.CFG.TOOLS, I.CFG.COLOURS = {}, {}
    I.rebuildDock()
    check("E empty dock keeps + and shape", count(dockWin(), "td_tool_") == 0 and find(dockWin(), "td_plus") ~= nil and find(dockWin(), "td_shape") ~= nil)
    app.C.Tool_laserPointerPen = nil
    I.CFG.TOOLS = {"pen", "laserPen", "selectObject", "eraser"}
    I.rebuildDock()
    check("E missing tool left out", count(dockWin(), "td_tool_") == 3 and find(dockWin(), "td_tool_laserPen") == nil)
    check("E missing tool logged", readFile(TOOLDOCK_LOG_FILE):find("laserPen", 1, true) ~= nil)
    app.C.Tool_laserPointerPen = 23
    dockWin():move(60000, 60000)
end)
at(300, function()
    I.keepOnScreen(dockWin())
    local x, y = dockWin():get_position()
    check("E pulled back on screen", x < 60000 and y < 60000, x .. "," .. y)
    toolDockToggle()
end)
at(400, function()
    check("E toggle closes the dock", I.dock() == nil)
    check("E timer stopped", not I.timerLive())
    check("E no dialogs", #CALLS == 0 or not table.concat(CALLS, "|"):find("dialog", 1, true), table.concat(CALLS, "|"))
end)
-- F. a saved place with a negative coordinate (monitor above / left of the main one) is used
at(100, function()
    I.CFG.PANEL_X, I.CFG.PANEL_Y = 777, -50
    toolDockToggle()
end)
at(700, function()
    local x, y = dockWin():get_position()
    check("F negative place restored (x kept, y pulled on screen)", x == 777 and y >= 0, x .. "," .. y)
    toolDockToggle()
end)
at(400, function() check("F closed again", I.dock() == nil) end)
-- G. v0.2: no title bar, grip drag, line thickness picker
local function pickWin() local p = I.pick() return p and p.win end
local GRIP = {}
at(100, function()
    I.CFG.TOOLS, I.CFG.COLOURS = {"pen", "laserPen", "selectObject", "eraser"}, {0x000000, 0x1E5AE6}
    I.CFG.SHAPE, I.CFG.SIZE_BUTTON = "horizontal", true
    toolDockToggle()
end)
at(500, function()
    check("G dock has no title bar", dockWin():get_decorated() == false)
    check("G grip shown", find(dockWin(), "td_grip") ~= nil)
    check("G thickness button shown", find(dockWin(), "td_size") ~= nil)
    check("G thickness dot shows size 2 (thin)", find(dockWin(), "td_size_dot"):get_style_context():has_class("td-dot2"))
    find(dockWin(), "td_size"):set_active(true)
end)
at(300, function()
    check("G picker opens", pickWin() ~= nil and pickWin():get_visible())
    check("G picker has 5 sizes", count(pickWin(), "td_sz_") == 5, count(pickWin(), "td_sz_"))
    check("G current size outlined", find(pickWin(), "td_sz_2"):get_style_context():has_class("td-on"))
    local px, py = pickWin():get_position()
    local dx, dy = dockWin():get_position()
    check("G picker below the dock", py > dy, px .. "," .. py .. " dock " .. dx .. "," .. dy)
    find(pickWin(), "td_sz_4"):set_active(true)
end)
at(400, function()
    check("G size click sets thick", SIZE == 3 and lastCalls(1) == "state tool-size=3", lastCalls(1))
    check("G picker closes after a pick", I.pick() == nil)
    check("G thickness dot follows (thick)", find(dockWin(), "td_size_dot"):get_style_context():has_class("td-dot4"))
    find(dockWin(), "td_size"):set_active(true)
end)
at(250, function()
    check("G picker opens again", I.pick() ~= nil)
    find(dockWin(), "td_size"):set_active(true)
end)
at(250, function()
    check("G second click on the button closes it", I.pick() == nil)
    local x, y = dockWin():get_position()
    GRIP.x0, GRIP.y0 = x, y
    I.setGripInput(function() return GRIP.held, GRIP.down, GRIP.sx, GRIP.sy end)
    GRIP.held, GRIP.down, GRIP.sx, GRIP.sy = true, true, 1000, 500
end)
at(150, function() GRIP.held, GRIP.sx, GRIP.sy = false, 1080, 540 end)   -- the button lets go, the tip stays down
at(250, function()
    local x, y = dockWin():get_position()
    check("G grip drag moves the dock", x == GRIP.x0 + 80 and y == GRIP.y0 + 40, x .. "," .. y .. " from " .. GRIP.x0 .. "," .. GRIP.y0)
    GRIP.down = false
    GRIP.sx, GRIP.sy = 1300, 700
end)
at(250, function()
    local x, y = dockWin():get_position()
    check("G lift ends the drag", x == GRIP.x0 + 80 and y == GRIP.y0 + 40, x .. "," .. y)
    check("G place saved", I.CFG.PANEL_X == x and I.CFG.PANEL_Y == y)
    I.setGripInput(nil)
    I.setPressInput(function(name) if name == "td_size" then return true, false end return false, false end)
end)
at(800, function()
    check("G long press on thickness asks to remove", I.ask() ~= nil)
    I.setPressInput(nil)
    find(I.ask().win, "td_rm_yes"):set_active(true)
end)
at(300, function()
    check("G thickness button removed", I.CFG.SIZE_BUTTON == false and find(dockWin(), "td_size") == nil)
    find(dockWin(), "td_plus"):set_active(true)
end)
at(400, function()
    check("G edit list: thickness box unticked", not find(editWin(), "td_e_sizebtn"):get_active())
    find(editWin(), "td_e_sizebtn"):set_active(true)
end)
at(300, function()
    check("G tick brings the thickness button back", I.CFG.SIZE_BUTTON == true and find(dockWin(), "td_size") ~= nil)
    find(dockWin(), "td_shape"):set_active(true)
end)
at(500, function()
    check("G vertical: grip on top", I.CFG.SHAPE == "vertical")
    local g = find(dockWin(), "td_grip"):get_allocation()
    local t = find(dockWin(), "td_tool_pen"):get_allocation()
    check("G vertical grip above the pen", g.y < t.y, g.y .. " / " .. t.y)
    find(dockWin(), "td_size"):set_active(true)
end)
at(300, function()
    local px = pickWin():get_position()
    local dx = dockWin():get_position()
    local w, h = pickWin():get_size()
    check("G vertical picker right of the dock, a column", px > dx and h > w, px .. " / " .. dx .. " " .. w .. "x" .. h)
    I.edit().close:set_active(true)
    toolDockToggle()
end)
at(400, function()
    check("G toggle closes dock + picker", I.dock() == nil and I.pick() == nil)
    check("G timer stopped", not I.timerLive())
end)
-- H. a tool without a size (select object): the picker sets the PEN's size; cost of one tick
at(100, function() TOOL = 10 toolDockToggle() end)
at(500, function() find(dockWin(), "td_size"):set_active(true) end)
at(300, function() find(pickWin(), "td_sz_5"):set_active(true) end)
at(300, function()
    check("H select tool: picker sets the pen size", lastCalls(1) == "state tool-pen-size=4", lastCalls(1))
    local t0 = GLib.get_monotonic_time()
    for i = 1, 200 do I.tick() end
    local ms = (GLib.get_monotonic_time() - t0) / 1000 / 200
    print(string.format("INFO one dock tick %.3f ms", ms))
    check("H one tick is cheap (< 1 ms)", ms < 1, ms)
    toolDockToggle()
end)
at(300, function() check("H closed", I.dock() == nil) end)
-- I. commands (zoom, ruler), the axes tool, and no button asking while the pen writes on the page (0.4)
at(100, function()
    TOOL = 1
    I.CFG.TOOLS = {"pen", "zoomIn", "ruler", "drawAxes"}
    toolDockToggle()
end)
at(400, function()
    check("I zoom, ruler and axes buttons", find(dockWin(), "td_tool_zoomIn") ~= nil and find(dockWin(), "td_tool_ruler") ~= nil
          and find(dockWin(), "td_tool_drawAxes") ~= nil)
    find(dockWin(), "td_tool_zoomIn"):set_active(true)
end)
at(250, function()
    check("I zoom in runs the Xournal++ command", lastCalls(1) == "action zoom-in", lastCalls(2))
    check("I zoom button springs back", not find(dockWin(), "td_tool_zoomIn"):get_active())
    find(dockWin(), "td_tool_ruler"):set_active(true)
end)
at(450, function()
    check("I ruler switched on", MODE[1] == "tool-draw-line", lastCalls(2))
    check("I ruler button lit while on", find(dockWin(), "td_tool_ruler"):get_style_context():has_class("td-on"))
    check("I zoom button never lit", not find(dockWin(), "td_tool_zoomIn"):get_style_context():has_class("td-on"))
    MODE[1] = nil                                        -- switched off in Xournal++ itself
end)
at(450, function()
    check("I ruler light follows Xournal++", not find(dockWin(), "td_tool_ruler"):get_style_context():has_class("td-on"))
    find(dockWin(), "td_tool_drawAxes"):set_active(true)
end)
at(250, function()
    check("I axes button: pen in axes mode", TOOL == 1 and MODE[1] == "tool-draw-coordinate-system", TOOL .. " " .. tostring(MODE[1]))
    check("I axes button lit", find(dockWin(), "td_tool_drawAxes"):get_style_context():has_class("td-on"))
    TOOL = 23                                            -- laser pointer: a shape button must switch to the pen
    MODE[1] = nil
    find(dockWin(), "td_tool_drawAxes"):set_active(true)
end)
at(250, function()
    check("I axes from the laser pointer: pen + axes mode", TOOL == 1 and MODE[1] == "tool-draw-coordinate-system", TOOL .. " " .. tostring(MODE[1]))
    find(dockWin(), "td_tool_drawAxes"):set_active(true)
end)
at(250, function()
    check("I axes again: mode off, pen stays", TOOL == 1 and MODE[1] == nil, TOOL .. " " .. tostring(MODE[1]))
    find(dockWin(), "td_tool_ruler"):set_active(true)
end)
at(250, function()
    check("I ruler on", MODE[1] == "tool-draw-line")
    TOOL = 10                                            -- select tool; the pen keeps its ruler mode
    find(dockWin(), "td_tool_ruler"):set_active(true)
end)
at(250, function()
    check("I ruler from select, pen still in ruler mode: stays on", TOOL == 1 and MODE[1] == "tool-draw-line", tostring(MODE[1]))
    find(dockWin(), "td_tool_pen"):set_active(true)
end)
at(250, function()
    check("I Pen button = freehand: mode off", TOOL == 1 and MODE[1] == nil, tostring(MODE[1]))
    local d = I.dock()
    local P = {x = -60, y = -60, b1 = false}
    I.setPointerInput(function() return P.x, P.y, P.b1, false end)
    I.tick()
    P.b1 = true                                          -- pen down on the page
    local n0 = d.looks or 0
    for k = 1, 40 do d.nextLook = GLib.get_monotonic_time() / 1000 I.tick() end   -- even with the 150 ms look due
    check("I writing on the page: no button asked", (d.looks or 0) == n0, (d.looks or 0) - n0)
    d.nextLook = GLib.get_monotonic_time() / 1000 - 400 I.tick()
    check("I long press off the dock: one safety look after 500 ms", (d.looks or 0) == n0 + 1, (d.looks or 0) - n0)
    n0 = d.looks
    local t0 = GLib.get_monotonic_time()
    for k = 1, 200 do I.tick() end
    local ms = (GLib.get_monotonic_time() - t0) / 1000 / 200
    print(string.format("INFO one dock tick while writing %.3f ms", ms))
    check("I tick while writing is cheap (< 0.3 ms)", ms < 0.3, ms)
    P.b1 = false I.tick()                                -- lift on the page: still no look
    check("I lift after writing: no look", (d.looks or 0) == n0)
    P.x, P.y = 5, 5 I.tick()
    P.b1 = true
    I.tick() I.tick() I.tick()
    check("I press on the dock: buttons asked at every tick", (d.looks or 0) >= n0 + 3, (d.looks or 0) - n0)
    P.b1 = false I.tick()
    I.setPointerInput(nil)
    find(dockWin(), "td_plus"):set_active(true)
end)
at(500, function()
    check("I edit list has the commands", find(editWin(), "td_e_tool_zoomIn") ~= nil and find(editWin(), "td_e_tool_setsquare") ~= nil)
    check("I edit list: zoom in ticked, zoom out not", find(editWin(), "td_e_tool_zoomIn"):get_active()
          and not find(editWin(), "td_e_tool_zoomOut"):get_active())
    find(editWin(), "td_e_tool_zoomOut"):set_active(true)
end)
at(400, function()
    check("I tick in the edit list adds zoom out", find(dockWin(), "td_tool_zoomOut") ~= nil)
    I.edit().close:set_active(true)
    toolDockToggle()
end)
at(300, function() check("I closed", I.dock() == nil) end)
-- J. 0.6 auto zoom button + 0.7 custom buttons (fake menus: Plugin + Edit, with shortcuts)
local AZ = {n = 0}
local UNDO, SNAP, CUT = {n = 0}, {n = 0}, {n = 0}
local mwin = Gtk.Window {title = "fake menus"}
local bar = Gtk.MenuBar {}
local function withKey(item, key, mods)
    local ok, err = pcall(function() item:get_child():set_accel(key, mods) end)
    if not ok then print("set_accel failed: " .. tostring(err)) end
    return item
end
local top = Gtk.MenuItem.new_with_label("Plugin")
local menu = Gtk.Menu {}
local azItem = withKey(Gtk.MenuItem.new_with_label("Auto zoom: ON / OFF"), 65474, {CONTROL_MASK = true, MOD1_MASK = true})
azItem.on_activate = function()
    AZ.n = AZ.n + 1
    GLib.setenv("XOPP_AUTOZOOM_ON", (GLib.getenv("XOPP_AUTOZOOM_ON") == "1") and "0" or "1", true)
end
menu:append(azItem)
local snapItem = withKey(Gtk.MenuItem.new_with_label("Snapshot: drag a rectangle (on / off)"), 65477, {CONTROL_MASK = true, MOD1_MASK = true})
snapItem.on_activate = function() SNAP.n = SNAP.n + 1 end
menu:append(snapItem)
menu:append(withKey(Gtk.MenuItem.new_with_label("Tool dock: show / hide"), 65481, {CONTROL_MASK = true, MOD1_MASK = true}))
menu:append(Gtk.MenuItem.new_with_label("Check Page Step"))      -- Plugin menu: listed without a key
top:set_submenu(menu)
bar:append(top)
local etop = Gtk.MenuItem.new_with_mnemonic("_Edit")
local emenu = Gtk.Menu {}
local undoItem = withKey(Gtk.MenuItem.new_with_mnemonic("_Undo"), 122, {CONTROL_MASK = true})
undoItem.on_activate = function() UNDO.n = UNDO.n + 1 end
emenu:append(undoItem)                                            -- a tick box gives it: left out
local cutItem = withKey(Gtk.MenuItem.new_with_mnemonic("Cu_t"), 120, {CONTROL_MASK = true})
cutItem.on_activate = function() CUT.n = CUT.n + 1 end
emenu:append(cutItem)
emenu:append(Gtk.SeparatorMenuItem {})
local gridItem = withKey(Gtk.CheckMenuItem.new_with_label("Grid Snapping"), 103, {CONTROL_MASK = true})
emenu:append(gridItem)
emenu:append(Gtk.MenuItem.new_with_label("No key here"))          -- not Plugin, no key: left out
etop:set_submenu(emenu)
bar:append(etop)
mwin:add(bar)
mwin:show_all()
at(300, function()
    check("J no 0.6 keys", I.registerKeys == nil and I.KEYS == nil)
    GLib.setenv("XOPP_AUTOZOOM_ON", "0", true)
    I.CFG.TOOLS = {"pen", "autozoom"}
    toolDockToggle()
end)
at(400, function()
    local b = find(dockWin(), "td_tool_autozoom")
    check("J auto zoom button on the dock", b ~= nil)
    if b then b:set_active(true) end
end)
at(500, function()
    check("J click presses the autozoom menu entry", AZ.n == 1 and GLib.getenv("XOPP_AUTOZOOM_ON") == "1", AZ.n)
    local b = find(dockWin(), "td_tool_autozoom")
    check("J button lit while auto zoom is on", b and b:get_style_context():has_class("td-on"))
    find(dockWin(), "td_plus"):set_active(true)
end)
at(500, function()
    check("J edit list lists auto zoom with the helpers", find(editWin(), "td_e_tool_autozoom") ~= nil)
    check("J no key rows any more", find(editWin(), "td_e_key_pen") == nil)
    local l, hidden = I.listMenuEntries()
    local s = {}
    for i, c in ipairs(l) do s[i] = c.group .. "|" .. c.label .. "|" .. tostring(c.key) end
    check("J menu list: Plugin entries + entries with a key; tool dock's own and tick-box ones left out",
          #l == 4 and s[1] == "Plugin|Snapshot: drag a rectangle (on / off)|Ctrl+Alt+F8" and s[2] == "Plugin|Check Page Step|nil"
          and s[3] == "Edit|Cut|Ctrl+X" and s[4] == "Edit|Grid Snapping|Ctrl+G" and hidden == 2,
          table.concat(s, " ; ") .. " hidden " .. tostring(hidden))
    find(editWin(), "td_e_cuadd"):set_active(true)
end)
at(500, function()
    local cp = I.cuPick()
    check("J custom list open with 4 entries", cp ~= nil and #cp.btns == 4, cp and #cp.btns)
    if cp then find(cp.win, "td_cu_1"):set_active(true) end       -- Snapshot
end)
at(500, function()
    check("J list closed after a choice", I.cuPick() == nil)
    check("J custom1 = snapshot", I.CUSTOM[1] and I.CUSTOM[1].label == "Snapshot: drag a rectangle (on / off)" and I.CUSTOM[1].key == "Ctrl+Alt+F8")
    local b = find(dockWin(), "td_tool_custom1")
    check("J custom button on the dock", b ~= nil)
    check("J edit list row with Remove", find(editWin(), "td_e_curm_custom1") ~= nil)
    if b then b:set_active(true) end
end)
at(500, function()
    check("J custom button runs the menu entry", SNAP.n == 1, SNAP.n)
    local b = find(dockWin(), "td_tool_custom1")
    check("J plain entry not lit", b and not b:get_style_context():has_class("td-on"))
    find(editWin(), "td_e_cuadd"):set_active(true)
end)
at(500, function()
    local cp = I.cuPick()
    local b1 = cp and find(cp.win, "td_cu_1")
    check("J entry already on the dock is greyed", b1 and not b1:get_sensitive())
    if cp then find(cp.win, "td_cu_4"):set_active(true) end       -- Grid Snapping
end)
at(500, function()
    local b = find(dockWin(), "td_tool_custom2")
    check("J second custom button", b ~= nil and I.CUSTOM[2].label == "Grid Snapping")
    if b then b:set_active(true) end
end)
at(600, function()
    check("J tick entry turned on", gridItem:get_active() == true)
    local b = find(dockWin(), "td_tool_custom2")
    check("J custom button lit while the tick entry is on", b and b:get_style_context():has_class("td-on"))
    find(editWin(), "td_e_cuadd"):set_active(true)
end)
at(500, function()
    local cp = I.cuPick()
    if cp then find(cp.win, "td_cu_3"):set_active(true) end       -- Cut
end)
at(500, function()
    local b = find(dockWin(), "td_tool_custom3")
    check("J cut custom button", b ~= nil)
    if b then b:set_active(true) end
end)
at(400, function()
    check("J cut ran once", CUT.n == 1 and UNDO.n == 0, CUT.n)
    find(editWin(), "td_e_curm_custom1"):set_active(true)
end)
at(500, function()
    check("J removed in the edit list", I.CUSTOM[1] == nil and find(dockWin(), "td_tool_custom1") == nil
          and find(editWin(), "td_e_curm_custom1") == nil)
    find(editWin(), "td_e_cuadd"):set_active(true)
end)
at(500, function()
    local cp = I.cuPick()
    if cp then find(cp.win, "td_cu_cancel"):set_active(true) end
end)
at(1300, function()
    check("J cancel closes the list", I.cuPick() == nil)
    local txt = readFile(TOOLDOCK_SETTINGS_FILE)
    check("J saved", txt:find("CUSTOM2=Edit|Grid Snapping|Ctrl+G\n", 1, true) and txt:find("CUSTOM3=Edit|Cut|Ctrl+X\n", 1, true)
          and not txt:find("\nCUSTOM1=", 1, true) and txt:find("TOOLS=pen,autozoom,custom2,custom3\n", 1, true), txt)
    I.edit().close:set_active(true)
    toolDockToggle()
end)
at(1200, function()
    check("J closed", I.dock() == nil and I.edit() == nil and I.cuPick() == nil)
    mwin:destroy()
end)
-- K. 0.7.2: small screens: edit list resizable + size kept, height limit per screen, custom list placement
local K = {}
at(300, function()
    TOOLDOCK_WORKAREA = {x = 0, y = 0, width = 1366, height = 728}
    TOOLDOCK_MENU_ENTRIES = {}
    for i = 1, 60 do TOOLDOCK_MENU_ENTRIES[i] = {group = i <= 30 and "Edit" or "Plugin", label = "Entry " .. i, key = "Ctrl+" .. i} end
    I.CFG.TOOLS = {"pen", "eraser"}
    I.CFG.EDIT_X, I.CFG.EDIT_Y, I.CFG.EDIT_H = 880, 0, 0
    toolDockToggle()
end)
at(400, function() find(dockWin(), "td_plus"):set_active(true) end)
at(900, function()
    local e = I.edit()
    local w, h = e.win:get_size()
    K.w, K.h = w, h
    check("K edit list fits a 1366 x 728 screen", h <= 728 - 40 and w < 700, w .. "x" .. h)
    check("K edit list is resizable", e.win.resizable == true)
    check("K natural height kept at 0 (not resized by the user)", I.CFG.EDIT_H == 0)
    e.cuAdd:set_active(true)
end)
at(900, function()
    local cp = I.cuPick()
    local ex = I.edit().win:get_position()
    local x = cp and cp.win:get_position()
    local w = cp and cp.win:get_size()
    check("K no room on the right: list goes left of the edit list", cp and x + w <= ex and x >= 0,
          tostring(x) .. " + " .. tostring(w) .. " vs edit at " .. tostring(ex))
    if cp then cp.cancel:set_active(true) end
end)
at(400, function()
    I.edit().win:resize(K.w + 60, 420)           -- the user drags an edge
end)
at(600, function()
    local w, h = I.edit().win:get_size()
    check("K width stays the content's width (no empty space)", w == K.w, w .. " vs " .. K.w)
    check("K user height remembered", I.CFG.EDIT_H == h and h < K.h, I.CFG.EDIT_H)
    I.edit().close:set_active(true)
end)
at(500, function() find(dockWin(), "td_plus"):set_active(true) end)
at(900, function()
    local w, h = I.edit().win:get_size()
    check("K reopened at the user's height", w == K.w and h == I.CFG.EDIT_H, w .. "x" .. h)
    I.CFG.EDIT_H = 0
    I.rebuildDock()
end)
at(900, function()
    local w, h = I.edit().win:get_size()
    check("K back to the natural size", h > 420, w .. "x" .. h)
    -- moved to a smaller screen (a second monitor 1280 x 600)
    TOOLDOCK_WORKAREA = {x = 0, y = 0, width = 1280, height = 600}
    I.edit().win:move(40, 0)
end)
at(900, function()
    local w, h = I.edit().win:get_size()
    check("K on a smaller screen: not taller than it", h <= 600 - 40, w .. "x" .. h)
    check("K user height not changed by that", I.CFG.EDIT_H == 0)
    check("K log names the new screen", readFile(TOOLDOCK_LOG_FILE):find("edit list on a screen 1280 x 600", 1, true) ~= nil)
    I.edit().close:set_active(true)
    toolDockToggle()
    TOOLDOCK_WORKAREA, TOOLDOCK_MENU_ENTRIES = nil, nil
end)
at(1200, function() check("K closed", I.dock() == nil and I.edit() == nil) end)

-- L. 0.7.4: the dock never takes the keyboard, so GTK draws it as a window in the background
-- (":backdrop"), which greyed text and one-colour icons. Buttons must keep the normal text colour.
local L = {}
local function textColour(w)
    local c = w:get_style_context()
    local r = c:get_color(c:get_state())
    return {r.red, r.green, r.blue}
end
local function setBackdrop(x, on)
    if on then x:set_state_flags(Gtk.StateFlags.BACKDROP, false) else x:unset_state_flags(Gtk.StateFlags.BACKDROP) end
    if Gtk.Container:is_type_of(x) then for _, c in ipairs(x:get_children()) do setBackdrop(c, on) end end
end
local function sameColour(a, b) return math.abs(a[1] - b[1]) < 0.01 and math.abs(a[2] - b[2]) < 0.01 and math.abs(a[3] - b[3]) < 0.01 end
local function txt(c) return string.format("%.3f %.3f %.3f", c[1], c[2], c[3]) end
at(400, function() toolDockToggle() end)
at(900, function()
    L.normal = textColour(find(dockWin(), "td_plus"))
    setBackdrop(dockWin(), true)
end)
at(300, function()
    local back = textColour(find(dockWin(), "td_plus"))
    check("L light theme: background state keeps the text colour", sameColour(back, L.normal), txt(L.normal) .. " -> " .. txt(back))
    setBackdrop(dockWin(), false)
    Gtk.Settings.get_default().gtk_application_prefer_dark_theme = true
end)
at(600, function()
    L.dark = textColour(find(dockWin(), "td_plus"))
    setBackdrop(dockWin(), true)
end)
at(300, function()
    local back = textColour(find(dockWin(), "td_plus"))
    check("L dark theme: text is light", L.dark[1] > 0.8, txt(L.dark))
    check("L dark theme: background state keeps the text colour", sameColour(back, L.dark), txt(L.dark) .. " -> " .. txt(back))
    Gtk.Settings.get_default().gtk_application_prefer_dark_theme = false
    toolDockToggle()
end)
at(200, function() loop:quit() end)
loop:run()
main:destroy()
for _, l in ipairs(out) do print(l) end
print(fails == 0 and "all checks passed" or (fails .. " FAILED"))
os.remove(TOOLDOCK_SETTINGS_FILE)
return fails == 0 and "ok" or "failed"
