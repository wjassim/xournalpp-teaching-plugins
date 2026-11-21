-- Mock test of carry ink (2.8): a fake Xournal++ that keeps strokes, texts and pictures per page,
-- with the API behaviour checked live (setCurrentPage does not scroll, add* writes to the current
-- page, addImages wants whole-number sizes, addToSelection + "delete" deletes).
-- Run from the plugin folder:
--   powershell -ExecutionPolicy Bypass -File ..\autozoom\tests\run_lua55.ps1 tests\test_carry.lua
local dir = (os.getenv("LOCALAPPDATA") or ""):gsub(string.char(92), "/") .. "/xournalpp/plugins/preserve-view/"
local fails, checks = 0, 0
PRESERVE_VIEW_TEST = true
PRESERVE_VIEW_SETTINGS_FILE = (os.getenv("TEMP") or ".") .. "/preserve_view_carry_settings.txt"
os.remove(PRESERVE_VIEW_SETTINGS_FILE)
local function check(cond, msg)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. msg) end
end

-- 6 pages of 540 pt at 2 px per point, view 1080 px; page n starts at 10 + (n-1) * 1095
local N, S, VIEW = 6, 2, 1080
local PITCH = 540 * S + 15
local total = 20 + (N - 1) * 15 + N * 540 * S
local y = 300
local cur = 1
local pages = {}
for i = 1, N do pages[i] = {strokes = {}, texts = {}, images = {}} end
local selection, tool, undoSteps, nextRef = {}, 1, 0, 0
local function ref() nextRef = nextRef + 1 return {id = nextRef} end
local function copyList(t)
    local out = {}
    for _, it in ipairs(t) do local c = {} for k, v in pairs(it) do c[k] = v end out[#out + 1] = c end
    return out
end
local function viewPage() return math.min(N, math.floor((y + VIEW / 2 - 10) / PITCH) + 1) end
local badImageSize = false
local refreshed = {}     -- page -> app.refreshPage() calls (without one, added ink is not drawn: seen live)
app = {
    refreshPage = function() refreshed[cur] = (refreshed[cur] or 0) + 1 end,
    registerUi = function() end,
    openDialog = function() end,
    getZoom = function() return S / (96 / 72) end,
    getDisplayDpi = function() return 96 end,
    getScrollPos = function() return {x = 0, y = y, width = 1920, height = VIEW} end,
    getDocumentStructure = function()
        local p = {}
        for i = 1, N do p[i] = {pageHeight = 540, pageWidth = 960} end
        return {pages = p, currentPage = cur}
    end,
    scrollToPos = function(_, dy, rel)
        y = math.max(0, math.min(total - VIEW, rel and (y + dy) or dy))
        cur = viewPage()                     -- Xournal++ follows the view (checked live)
    end,
    scrollToPage = function() end,
    setCurrentPage = function(n) cur = n end,   -- no scrolling (checked live)
    getStrokes = function(kind)
        if kind == "selection" then return selection end
        return copyList(pages[cur].strokes)
    end,
    getTexts = function() return copyList(pages[cur].texts) end,
    getImages = function() return copyList(pages[cur].images) end,
    addStrokes = function(o)
        for _, s in ipairs(o.strokes) do
            assert(s.ref == nil, "ref must not be passed on")
            s.ref = ref(); table.insert(pages[cur].strokes, s)
        end
        undoSteps = undoSteps + 1
    end,
    addTexts = function(o) for _, t in ipairs(o.texts) do t.ref = ref(); table.insert(pages[cur].texts, t) end undoSteps = undoSteps + 1 end,
    addImages = function(o)
        for _, i in ipairs(o.images) do
            if math.type(i.maxWidth) ~= "integer" or math.type(i.maxHeight) ~= "integer" then badImageSize = true end
            table.insert(pages[cur].images, {x = i.x, y = i.y, width = i.maxWidth, height = i.maxHeight, data = i.data, ref = ref()})
        end
        undoSteps = undoSteps + 1
    end,
    clearSelection = function() selection = {} end,
    addToSelection = function(refs) selection = refs; tool = 6 end,   -- selecting switches to a select tool
    activateAction = function(a)
        if a ~= "delete" then return end
        local gone = {}
        for _, r in ipairs(selection) do gone[r] = true end
        for _, g in ipairs({"strokes", "texts", "images"}) do
            local keep = {}
            for _, it in ipairs(pages[cur][g]) do if not gone[it.ref] then keep[#keep + 1] = it end end
            pages[cur][g] = keep
        end
        selection = {}
        undoSteps = undoSteps + 1
    end,
    getActionState = function(a) if a == "select-tool" then return tool end end,
    changeActionState = function(a, v) if a == "select-tool" then tool = v end end,
}
package.preload["LuaGObject"] = function() error("no GTK in this test") end

local function stroke(x0, y0, toolName, colour)
    return {x = {x0, x0 + 10, x0 + 20}, y = {y0, y0 + 5, y0}, pressure = {0.5, 0.7, 0.6},
            tool = toolName or "pen", width = 1.41, color = colour or 0xff0000, fill = -1, lineStyle = "plain", ref = ref()}
end
local function count(n, g) return #pages[n][g] end

dofile(dir .. "main.lua")
local I = PRESERVE_VIEW_INTERNALS
initUi()
check(I.carryOn() == false, "carry ink off at start by default")

-- page 1 writing: 2 pen strokes, 1 highlighter, 1 text, 1 picture with a decimal size
pages[1].strokes = {stroke(100, 100), stroke(100, 150), stroke(50, 300, "highlighter", 0xffff00)}
pages[1].texts = {{text = "x = 2", x = 300, y = 200, color = 255, font = {name = "Sans", size = 12}, ref = ref()}}
pages[1].images = {{x = 50.5, y = 60.25, width = 200.4, height = 90.6, data = "PNGDATA", ref = ref()}}

-- 1) carry off: Next copies nothing
nextPageKeepView()
check(cur == 2 and count(2, "strokes") == 0, "carry off: nothing copied")
previousPageKeepView()
check(cur == 1, "back on page 1")

-- 2) carry on: Next copies everything to page 2, at the same place
carryInkToggle()
check(I.carryOn() == true, "toggle turns carry on")
local u0 = undoSteps
nextPageKeepView()
check(cur == 2, "Next reaches page 2 (now " .. cur .. ")")
check(count(2, "strokes") == 3 and count(2, "texts") == 1 and count(2, "images") == 1, "all writing carried")
local s2 = pages[2].strokes
check(s2[1].x[2] == 110 and s2[1].y[3] == 100 and s2[1].pressure[2] == 0.7 and s2[1].width == 1.41, "stroke copied exactly")
check(s2[3].tool == "highlighter", "highlighter stays a highlighter")
check(pages[2].texts[1].text == "x = 2" and pages[2].texts[1].x == 300, "text copied at the same place")
local im = pages[2].images[1]
check(im.x == 50.5 and im.y == 60.25 and im.width == 200 and im.height == 91 and not badImageSize, "picture: same place, whole-number size")
check(undoSteps - u0 == 3, "one undo step per kind (" .. (undoSteps - u0) .. ")")
check((refreshed[2] or 0) >= 1, "page 2 redrawn after the carry (app.refreshPage)")
check(count(1, "strokes") == 3, "page 1 keeps its writing")

-- 3) Previous never carries; Next again after adding a line on page 1 (add only what is missing)
table.insert(pages[2].strokes, stroke(400, 400, "pen", 0x00ff00))   -- own writing on page 2
previousPageKeepView()
check(cur == 1 and count(1, "strokes") == 3, "Previous carries nothing back")
table.insert(pages[1].strokes, stroke(100, 450))                    -- new line on page 1
nextPageKeepView()
check(count(2, "strokes") == 5, "add: only the new line added, own line kept (" .. count(2, "strokes") .. ")")
check(count(2, "texts") == 1 and count(2, "images") == 1, "add: no doubled text or picture")
check(I.carryStats().added == 1 and I.carryStats().mode == "add", "carry stats say 1 added")

-- 4) replace: page 2 becomes a copy of page 1 (own green line goes); the tool is put back
I.CFG.CARRY_EXISTING = "replace"
previousPageKeepView()
tool = 1
nextPageKeepView()
check(count(2, "strokes") == 4 and count(2, "texts") == 1 and count(2, "images") == 1, "replace: exact copy")
local green = false
for _, s in ipairs(pages[2].strokes) do if s.color == 0x00ff00 then green = true end end
check(not green, "replace: own writing deleted")
check(tool == 1, "replace: tool put back after the delete")

-- 5) leave: nothing changes on a page that has writing
I.CFG.CARRY_EXISTING = "leave"
previousPageKeepView()
table.insert(pages[1].strokes, stroke(600, 100))
nextPageKeepView()
check(count(2, "strokes") == 4, "leave: page 2 unchanged")

-- 5b) replace, but the delete fails: only what is missing is added (no second copy on top)
I.CFG.CARRY_EXISTING = "replace"
local realAction = app.activateAction
app.activateAction = function(a) if a == "delete" then error("delete refused") end end
previousPageKeepView()
nextPageKeepView()
app.activateAction = realAction
check(count(2, "strokes") == 5 and count(2, "texts") == 1 and count(2, "images") == 1,
      "replace with a failed delete: no doubles (" .. count(2, "strokes") .. " strokes)")
check(I.carryStats().mode == "replace failed, added" and I.carryStats().added == 1, "failed delete falls back to add")
table.remove(pages[2].strokes)      -- page 2 back to 4 strokes for the next checks

-- 6) tick boxes: no highlighter, no text, no pictures
I.CFG.CARRY_EXISTING = "add"
I.CFG.CARRY_HIGHLIGHTER, I.CFG.CARRY_TEXT, I.CFG.CARRY_PICTURES = false, false, false
nextPageKeepView()        -- page 2 -> 3: page 3 is empty
check(cur == 3, "on page 3")
local hl = 0
for _, s in ipairs(pages[3].strokes) do if s.tool == "highlighter" then hl = hl + 1 end end
check(count(3, "strokes") == 3 and hl == 0 and count(3, "texts") == 0 and count(3, "images") == 0,
      "only pen strokes carried (" .. count(3, "strokes") .. " strokes, " .. hl .. " highlighter)")
I.CFG.CARRY_HIGHLIGHTER, I.CFG.CARRY_TEXT, I.CFG.CARRY_PICTURES = true, true, true

-- 7) last page: Next is blocked, nothing carried; empty page: nothing happens
for _ = 1, 10 do nextPageKeepView() end
check(cur == N, "reached the last page")
local before = count(N, "strokes")
nextPageKeepView()
check(count(N, "strokes") == before, "blocked Next carries nothing")
pages[N - 1] = {strokes = {}, texts = {}, images = {}}
pages[N] = {strokes = {}, texts = {}, images = {}}
previousPageKeepView()
u0 = undoSteps
nextPageKeepView()
check(undoSteps == u0 and I.carryStats().mode == "empty", "empty page: nothing added")

-- 8) clear page: everything on the page goes (all kinds, ticks ignored), one undo step, tool back
app.setCurrentPage(2)
I.CFG.CARRY_PEN = false
tool = 1
u0 = undoSteps
clearPageInk()
check(count(2, "strokes") == 0 and count(2, "texts") == 0 and count(2, "images") == 0, "clear: page empty")
check(undoSteps - u0 == 1 and tool == 1, "clear: one undo step, tool back")
check(count(1, "strokes") > 0, "clear: other pages untouched")
I.CFG.CARRY_PEN = true

-- 9) carry off again: Next copies nothing
carryInkToggle()
check(I.carryOn() == false, "toggle turns carry off")
app.setCurrentPage(1); y = 300; cur = 1
pages[2] = {strokes = {}, texts = {}, images = {}}
nextPageKeepView()
check(count(2, "strokes") == 0, "off again: nothing copied")

-- 10) settings file: carry settings saved and read back, bad values keep the default
I.CFG.CARRY_EXISTING = "replace"
I.CFG.CARRY_TEXT = false
I.saveSettings()
local f = io.open(PRESERVE_VIEW_SETTINGS_FILE, "r")
local txt = f:read("a")
f:close()
check(txt:find("CARRY_EXISTING=replace", 1, true) and txt:find("CARRY_TEXT=false", 1, true)
      and txt:find("KEY_CARRY=none", 1, true) and txt:find("CARRY_AT_START=false", 1, true), "carry settings written")
f = io.open(PRESERVE_VIEW_SETTINGS_FILE, "w")
f:write("CARRY_EXISTING=sometimes\nCARRY_AT_START=true\nCARRY_PICTURES=false\nKEY_CARRY=<Control><Alt>F1\n")
f:close()
I.CFG.CARRY_EXISTING = "add"
I.loadSettings()
check(I.CFG.CARRY_EXISTING == "add", "bad CARRY_EXISTING keeps the default")
check(I.CFG.CARRY_AT_START == true and I.CFG.CARRY_PICTURES == false and I.CFG.KEY_CARRY == "<Control><Alt>F1",
      "carry settings read back")

os.remove(PRESERVE_VIEW_SETTINGS_FILE)
print(string.format("%d checks, %d failed", checks, fails))
