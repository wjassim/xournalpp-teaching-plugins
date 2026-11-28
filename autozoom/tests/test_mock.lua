-- Mock test for the autozoom plugin: fake clock, fake GLib timers, fake GTK widgets, fake app
-- with the real Xournal++ page layout (fixed gaps that do not scale).
local PLUGIN = PLUGIN_PATH or ((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\autozoom\main.lua]])
AUTOZOOM_SETTINGS_FILE = (os.getenv("TEMP") or ".") .. "\\autozoom_mock_settings.txt"
AUTOZOOM_LOG_FILE = (os.getenv("TEMP") or ".") .. "\\autozoom_test.log"
os.remove(AUTOZOOM_SETTINGS_FILE)
local out, fails = {}, 0
local function check(name, cond, detail)
    out[#out + 1] = (cond and "PASS " or "FAIL ") .. name .. ((not cond and detail) and ("  -> " .. tostring(detail)) or "")
    if not cond then fails = fails + 1 end
end

local W
local function world(opts)
    opts = opts or {}
    W = {clock = 0, timers = {}, dialogs = {}, reg = 0, zoom = opts.zoom or 1.337, sx = 0, sy = 0,
         vw = 2175, vh = 1224, n = opts.n or 1221, K = 119.529412 / 72, P = 10, G = 15,
         pen = {x = 800, y = 500, down = false}, active = true, ceil = opts.ceil,
         zoomCallsWhileDown = 0, zoomCalls = 0, failScroll = false}
    function W.hpx(z) local v = 540 * z * W.K if W.ceil then v = math.ceil(v) end return v end
    function W.wpx(z) return 960 * z * W.K end
    -- pages: their own height; scroll area: never smaller than the view (Xournal++ then centres the
    -- pages in it, W.oy above the first page)
    function W.content(z) return 2 * W.P + W.n * W.hpx(z) + (W.n - 1) * W.G end
    function W.uv(z) return math.max(W.vh, W.content(z)) end
    function W.oy(z) return math.max(0, math.floor((W.vh - W.content(z)) / 2)) end
    function W.uh(z) return math.max(W.vw, W.wpx(z) + 21) end
    function W.clamp()
        W.sx = math.max(0, math.min(W.uh(W.zoom) - W.vw, W.sx))
        W.sy = math.max(0, math.min(W.uv(W.zoom) - W.vh, W.sy))
    end
    -- ground truth: document point under view point (qx, qy)
    function W.docAt(qx, qy)
        local z = W.zoom
        local Y, X = W.sy + qy - W.oy(z), W.sx + qx
        local pitch = W.hpx(z) + W.G
        local i = math.max(0, math.min(W.n - 1, math.floor((Y - W.P) / pitch)))
        return {i = i, v = (Y - W.P - i * pitch) / z, h = (X - (W.uh(z) - W.wpx(z)) / 2) / z}
    end
    app = {}
    function app.getZoom() return W.zoom end
    function app.getDisplayDpi() return 120 end      -- rounded: the real 100 % is 119.53 / 72 px per point
    function app.setZoom(z)
        W.zoomCalls = W.zoomCalls + 1
        if W.pen.down then W.zoomCallsWhileDown = W.zoomCallsWhileDown + 1 end
        W.zoom = z W.clamp()
    end
    function app.getScrollPos()
        if W.failScroll then error("boom") end
        return {x = W.sx, y = W.sy, width = W.vw, height = W.vh}
    end
    function app.scrollToPos(x, y, rel)
        if W.pen.down then W.zoomCallsWhileDown = W.zoomCallsWhileDown + 1 end
        if rel then x, y = W.sx + x, W.sy + y end
        W.sx, W.sy = x, y W.clamp()
    end
    function app.getDocumentStructure()
        local pages = {}
        for i = 1, W.n do pages[i] = {pageWidth = 960.0, pageHeight = 540.0} end
        return {pages = pages, currentPage = 1}
    end
    function app.registerUi() W.reg = W.reg + 1 end
    function app.openDialog(m) W.dialogs[#W.dialogs + 1] = m end

    local canvas = {name = "GtkXournal"}
    local scrolled = {name = "GtkScrolledWindow", isScrolled = true, children = {canvas}}
    local top = {name = "mainWindow", children = {scrolled}}
    local function widget(w)
        function w:get_name() return self.name end
        function w:get_visible() return true end
        function w:get_children() return self.children end
    end
    widget(canvas) widget(scrolled) widget(top)
    -- As in the real LuaGObject: `is_active` is a property (a plain boolean), not a method.
    setmetatable(top, {__index = function(_, k) if k == "is_active" then return W.active end end})
    local gdkwin = {}
    function gdkwin:get_device_position() return gdkwin, W.pen.x, W.pen.y, {BUTTON1_MASK = W.pen.down or nil} end
    function canvas:get_window() return gdkwin end
    function scrolled:get_vadjustment() return {get_upper = function() return W.uv(W.zoom) end,
                                                get_page_size = function() return W.vh end} end
    function scrolled:get_hadjustment() return {get_upper = function() return W.uh(W.zoom) end} end
    -- W.menu = a menu is open (it holds the grab); W.over = a floating window under the pointer
    local topGdk = {}
    function topGdk:get_effective_toplevel() return topGdk end
    function gdkwin:get_effective_toplevel() return topGdk end
    function top:get_window() return topGdk end
    local otherGdk = {}
    function otherGdk:get_effective_toplevel() return otherGdk end
    local menuWidget = {get_toplevel = function() return {} end}
    -- W.frame = the pointer is on the title bar of another window (only its frame contains it)
    local frameWin = {get_visible = function() return W.frame == true end,
                      get_window = function() return {is_viewable = function() return true end,
                          get_frame_extents = function() return {x = 0, y = 0, width = 5000, height = 5000} end} end}
    local Gtk = {Window = {list_toplevels = function() if W.frame then return {top, frameWin} end return {top} end},
                 grab_get_current = function() return W.menu and menuWidget or nil end,
                 Container = {is_type_of = function(_, w) return w.children ~= nil end},
                 ScrolledWindow = {is_type_of = function(_, w) return w.isScrolled == true end}}
    local Gdk = {Display = {get_default = function()
        return {get_default_seat = function() return {get_pointer = function()
            return {get_position = function() return nil, 100, 100 end,
                    get_window_at_position = function()
                if W.noWinAt then error("no such call") end
                return W.over and otherGdk or gdkwin
            end}
        end} end}
    end}}
    local GLib = {PRIORITY_DEFAULT = 0,
                  get_monotonic_time = function() return W.clock * 1000 end,
                  setenv = function(k, v) W.env = W.env or {} W.env[k] = v end,
                  timeout_add = function(_, ms, fn) W.timers[#W.timers + 1] = {ms = ms, fn = fn, due = W.clock + ms} return #W.timers end}
    package.loaded["LuaGObject"] = {GLib = GLib, require = function(n) return n == "Gtk" and Gtk or Gdk end}
    autozoomToggle, autozoomNow, autozoomPanel, autozoomPause, initUi = nil, nil, nil, nil, nil
    dofile(PLUGIN)
    W.sy = opts.sy or (W.P + 800 * (W.hpx(W.zoom) + W.G) + 100)
    W.sx = opts.sx or 0
    W.clamp()
end

local function live() local c = 0 for _, t in ipairs(W.timers) do if not t.dead then c = c + 1 end end return c end

-- advance the fake clock by ms; `script(t)` runs before every tick to move the pen
local function pump(ms, script)
    local stop = W.clock + ms
    local guard = 0
    while true do
        local best
        for _, t in ipairs(W.timers) do if not t.dead and (not best or t.due < best.due) then best = t end end
        if not best or best.due > stop then W.clock = stop return end
        W.clock = best.due
        if script then script(W.clock) end
        if best.fn() then best.due = W.clock + best.ms else best.dead = true end
        guard = guard + 1
        if guard > 100000 then error("runaway timer") end
    end
end

-- the user zooms by hand: the middle of the view stays where it is (as Xournal++ does)
local function userZoom(z)
    local d = W.docAt(W.vw / 2, W.vh / 2)
    W.zoom = z
    W.sy = W.P + d.i * (W.hpx(z) + W.G) + d.v * z - W.vh / 2
    W.sx = (W.uh(z) - W.wpx(z)) / 2 + d.h * z - W.vw / 2
    W.clamp()
end
local jit = 0
-- hover jitter of a real pen: changes every tick, also when the plugin reads only every 2nd tick (0.12)
local function hoverAt(x, y) return function(t) jit = (math.floor((t or 0) / 16)) % 3 W.pen.x, W.pen.y, W.pen.down = x + jit, y, false end end
local function frozen() return function() end end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end
-- Scroll positions: the plugin scrolls to whole pixels (v0.4, no blur), so a return to a saved view is
-- within 0.5 px of it.
local function sameDoc(a, b, z, tolPx)
    return a.i == b.i and math.abs(a.v - b.v) * z <= tolPx and math.abs(a.h - b.h) * z <= tolPx
end
local function docDiff(a, b, z)
    return string.format("page %d->%d dv %.2fpx dh %.2fpx", a.i, b.i, (b.v - a.v) * z, (b.h - a.h) * z)
end

-- 1. load, registration, globals
local before = {}
for k in pairs(_G) do before[k] = true end
world()
initUi()
local extra = {}
for k in pairs(_G) do
    if not before[k] and k ~= "app" and k ~= "autozoomToggle" and k ~= "autozoomNow" and k ~= "autozoomPanel" and k ~= "autozoomPause" and k ~= "initUi" then extra[#extra + 1] = k end
end
check("loads and registers 4 menu entries", W.reg == 4, W.reg)
check("no new globals besides the callbacks", #extra == 0, table.concat(extra, ","))
check("off at startup: no timer", live() == 0)

-- 2. toggle
autozoomToggle()
check("toggle on starts exactly one timer", live() == 1 and #W.dialogs == 0, #W.dialogs)
autozoomToggle() pump(100)
check("toggle off stops the timer", live() == 0 and #W.dialogs == 0)
for _ = 1, 10 do autozoomToggle() pump(50) autozoomToggle() pump(50) end
autozoomToggle() pump(200)
check("many toggles leave one timer", live() == 1, live())

-- 3. frozen pen (lifted away) must not trigger
world() autozoomToggle()
local z0, sx0, sy0 = W.zoom, W.sx, W.sy
pump(3000, frozen())
check("frozen pen does not zoom", W.zoom == z0 and W.zoomCalls == 0)

-- 4. hover dwell zooms in about the pen, deep in a long document
local d0 = W.docAt(800, 500)
pump(300, hoverAt(800, 500))
check("no zoom before the dwell time", W.zoom == z0)
pump(2600, hoverAt(800, 500))
check("hover zooms in by 1.6", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)
local d1 = W.docAt(800, 500)
check("point under the pen stays under the pen (page 800)", sameDoc(d0, d1, W.zoom, 1.0), docDiff(d0, d1, W.zoom))

-- 5. idle -> zoom out to the exact start
pump(500, hoverAt(800, 500))
check("still zoomed before the idle time", near(W.zoom / z0, 1.6, 1e-9))
pump(6000, frozen())
check("zooms out to the exact saved zoom and scroll", W.zoom == z0 and near(W.sx, sx0, 0.5) and near(W.sy, sy0, 0.5),
      string.format("zoom %.6f sx %.3f sy %.3f (want %.6f %.3f %.3f)", W.zoom, W.sx, W.sy, z0, sx0, sy0))

-- 6. re-arm: pen still hovering at the same spot must not zoom in again
pump(2000, hoverAt(800, 500))
check("no re-zoom while the pen stays where it was", W.zoom == z0)
pump(2600, hoverAt(1200, 700))
check("zooms again after the pen moved away and dwelt", near(W.zoom / z0, 1.6, 1e-9))

-- 7. writing trigger: view never changes while the tip is down
world() autozoomToggle()
z0, sx0, sy0 = W.zoom, W.sx, W.sy
d0 = W.docAt(900, 600)
local function writing(t)
    jit = 1 - jit
    W.pen.x, W.pen.y, W.pen.down = 900 + jit, 600, (t % 250) < 150
end
pump(140, writing)
check("no zoom in the first 140 ms of writing", W.zoomCalls == 0)
pump(9000, writing)
check("writing zooms in fully, only in the gaps between strokes", near(W.zoom / z0, 1.6, 1e-9) and W.zoomCallsWhileDown == 0,
      string.format("ratio %.4f, view changes with tip down %d", W.zoom / z0, W.zoomCallsWhileDown))
d1 = W.docAt(900, 600)
check("writing spot stays under the pen", sameDoc(d0, d1, W.zoom, 1.5), docDiff(d0, d1, W.zoom))
pump(10000, writing)
check("stays zoomed while writing goes on", near(W.zoom / z0, 1.6, 1e-9))

-- 8. page change while zoomed in: return to the same place on the next page
local pitch1 = W.hpx(W.zoom) + W.G
W.sy = W.sy + pitch1
W.pen.down = false
pump(7000, frozen())
local pitch0 = W.hpx(z0) + W.G
check("after a page hop, zoom-out lands one page further (same place)", W.zoom == z0 and near(W.sy, sy0 + pitch0, 0.5) and near(W.sx, sx0, 0.5),
      string.format("sy %.3f want %.3f, sx %.3f want %.3f", W.sy, sy0 + pitch0, W.sx, sx0))

-- 9. manual zoom while zoomed in: becomes the new zoom level (learned and saved)
world() autozoomToggle()
z0, sx0, sy0 = W.zoom, W.sx, W.sy
pump(3000, hoverAt(800, 500))
userZoom(z0 * 2.0)
pump(1500, hoverAt(800, 500))
check("manual zoom while zoomed in is kept, plugin stays active", near(W.zoom / z0, 2.0, 1e-9), W.zoom / z0)
pump(7000, frozen())
check("after a learned zoom it still zooms out to the saved view", W.zoom == z0 and near(W.sx, sx0, 0.5) and near(W.sy, sy0, 0.5),
      string.format("zoom %.4f sx %.2f sy %.2f", W.zoom, W.sx, W.sy))
pump(3000, hoverAt(1200, 700))
check("the next zoom-in uses the learned level 2.0", near(W.zoom / z0, 2.0, 1e-9), W.zoom / z0)
local fset = io.open(AUTOZOOM_SETTINGS_FILE, "r")
local saved = fset and fset:read("a") or ""
if fset then fset:close() end
check("learned level is saved to the settings file", saved:find("FACTOR=2.0", 1, true) ~= nil, saved:match("FACTOR=[^\n]*"))
os.remove(AUTOZOOM_SETTINGS_FILE)

-- 9b. dialled back to the base zoom (or below) while zoomed in: let go, level unchanged
world() autozoomToggle()
z0 = W.zoom
pump(3000, hoverAt(800, 500))
userZoom(z0 * 0.9)
local syUser = W.sy
pump(6000, frozen())
check("zoom dialled below the base is kept (plugin lets go)", near(W.zoom, z0 * 0.9, 1e-9) and near(W.sy, syUser), W.zoom / z0)
pump(3000, hoverAt(1200, 700))
check("level not learned from that: next zoom-in is 1.6", near(W.zoom / (z0 * 0.9), 1.6, 1e-9), W.zoom / (z0 * 0.9))

-- 9c. manual zoom during the zoom movement: let go
world() autozoomToggle()
z0 = W.zoom
pump(700, hoverAt(800, 500))
W.zoom = 3.0 W.clamp()
pump(6000, frozen())
check("manual zoom during the movement is kept (no snap back)", W.zoom == 3.0, W.zoom)

-- 10. toggle off while zoomed in restores the view
world() autozoomToggle()
z0, sx0, sy0 = W.zoom, W.sx, W.sy
pump(3000, hoverAt(800, 500))
autozoomToggle() pump(100)
check("toggle off restores zoom and scroll", W.zoom == z0 and near(W.sy, sy0, 0.5) and near(W.sx, sx0, 0.5) and live() == 0)

-- 11. inactive window: no trigger
world() autozoomToggle()
z0 = W.zoom
W.active = false
pump(3000, hoverAt(800, 500))
check("no zoom while another window is active", W.zoom == z0)

-- 11b. an open menu over the page: hover and pen presses on it do not zoom
world() autozoomToggle()
z0 = W.zoom
W.menu = true
pump(3000, hoverAt(800, 500))
check("no hover zoom while a menu is open", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
pump(1500, function(t) W.pen.x, W.pen.y, W.pen.down = 800, 500, (t % 250) < 150 end)
check("no writing zoom from presses on an open menu", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
W.menu = false
pump(2000, hoverAt(900, 600))
check("zooms again once the menu is closed", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)

-- 11c. another floating window (Snapshot, Page step) under the pointer
world() autozoomToggle()
z0 = W.zoom
W.over = true
pump(3000, hoverAt(800, 500))
pump(1500, function(t) W.pen.x, W.pen.y, W.pen.down = 800, 500, (t % 250) < 150 end)
check("no zoom with the pen on another floating window", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
W.over = false
pump(2000, hoverAt(900, 600))
check("zooms again with the pen back on the page", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)

-- 11c2. pen on the title bar of a floating window (Windows draws it: no GTK window there)
world() autozoomToggle()
z0 = W.zoom
W.frame = true
pump(3000, hoverAt(800, 500))
pump(1500, function(t) W.pen.x, W.pen.y, W.pen.down = 800, 500, (t % 250) < 150 end)
check("no zoom with the pen on a window title bar", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
W.frame = false
pump(2500, hoverAt(900, 600))
check("zooms again off the title bar", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)

-- 11c3. a press that starts on a floating window and drags across the page (moving the dock)
world() autozoomToggle()
z0 = W.zoom
W.over = true
W.pen.x, W.pen.y, W.pen.down = 800, 500, true
pump(100)
W.over = false
pump(3000, function(t) W.pen.x, W.pen.y, W.pen.down = 800 + t / 10, 500, true end)
check("no zoom while dragging from a window across the page", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
pump(300, function() W.pen.down = false end)
pump(9000, function(t) W.pen.x, W.pen.y, W.pen.down = 900, 600, (t % 250) < 150 end)
check("writing after the lift zooms again", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)

-- 11d. zoomed in, pen held at the edge but on a menu: no edge slide
world() autozoomToggle()
pump(2500, hoverAt(800, 500))
W.menu = true
local sxM = W.sx
pump(1500, hoverAt(2150, 600))
check("no edge slide under an open menu", near(W.sx, sxM), W.sx - sxM)
W.menu = false

-- 11e. the window question cannot be answered: works as before
world() autozoomToggle()
z0 = W.zoom
W.noWinAt = true
pump(2500, hoverAt(800, 500))
check("window call missing: still zooms", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)

-- 12. error inside a tick stops the timer
world() autozoomToggle()
W.failScroll = true
pump(500, hoverAt(800, 500))
W.failScroll = false
check("tick error stops the timer (no runaway)", live() == 0)
autozoomToggle() pump(100)
check("can be switched on again after an error", live() == 1, live())

-- 13. layout with page heights rounded up to whole pixels
world({ceil = true}) autozoomToggle()
z0, sx0, sy0 = W.zoom, W.sx, W.sy
d0 = W.docAt(1500, 300)
pump(3000, hoverAt(1500, 300))
d1 = W.docAt(1500, 300)
check("rounded page heights: pen spot kept within 2 px", near(W.zoom / z0, 1.6, 1e-9) and sameDoc(d0, d1, W.zoom, 2.0), docDiff(d0, d1, W.zoom))
pump(7000, frozen())
check("rounded page heights: exact return", W.zoom == z0 and near(W.sy, sy0) and near(W.sx, sx0))

-- 14. edge pan: only with the tip up for a while, never between strokes
world() autozoomToggle()
pump(3000, hoverAt(800, 500))
local sxZ = W.sx
local function writeAtEdge(t) jit = 1 - jit W.pen.x, W.pen.y, W.pen.down = 2150 + jit, 600, (t % 250) < 150 end
pump(3000, writeAtEdge)
check("no pan between strokes at the edge", near(W.sx, sxZ), W.sx - sxZ)
pump(2600, hoverAt(2150, 600))
check("pen held at the right edge slides the view right", W.sx > sxZ + 100, W.sx - sxZ)
pump(700, hoverAt(1000, 600))
local sxP = W.sx
pump(1500, hoverAt(1000, 600))
check("pan stops (softly) when the pen leaves the edge", near(W.sx, sxP), W.sx - sxP)

-- 15. manual key
world() autozoomToggle()
z0, sy0 = W.zoom, W.sy
autozoomNow() pump(3000, frozen())
check("key zooms in even with a frozen pen", near(W.zoom / z0, 1.6, 1e-9))
autozoomNow() pump(3000, frozen())
check("key zooms out again to the start", W.zoom == z0 and near(W.sy, sy0, 0.5))

-- 16. short document (3 pages), near the top
world({n = 3, sy = 0}) autozoomToggle()
z0, sx0, sy0 = W.zoom, W.sx, W.sy
d0 = W.docAt(700, 400)
pump(3000, hoverAt(700, 400))
d1 = W.docAt(700, 400)
check("3-page document: pen spot kept within 2 px", sameDoc(d0, d1, W.zoom, 2.0), docDiff(d0, d1, W.zoom))
pump(7000, frozen())
check("3-page document: exact return", W.zoom == z0 and near(W.sy, sy0) and near(W.sx, sx0))

-- 16b. one page, zoomed out so far that the whole page fits in the view (zoom fit): the scroll area is
-- then the view, not the page, and the page sits in the middle of it (0.15)
world({n = 1, zoom = 1.0, sy = 0}) autozoomToggle()
z0, sx0, sy0 = W.zoom, W.sx, W.sy
check("one page fits in the view, not after the zoom (test set-up)", W.content(z0) < W.vh and W.oy(z0) > 100
      and W.content(z0 * 1.6) > W.vh and W.wpx(z0 * 1.6) > W.vw, W.oy(z0))
d0 = W.docAt(900, 500)
pump(3000, hoverAt(900, 500))
d1 = W.docAt(900, 500)
check("page fits in the view: zoomed in", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)
check("page fits in the view: pen spot kept within 2 px", sameDoc(d0, d1, W.zoom, 2.0), docDiff(d0, d1, W.zoom))
pump(7000, frozen())
check("page fits in the view: exact return", W.zoom == z0 and near(W.sy, sy0) and near(W.sx, sx0))

-- 17. follow: writing outside the still zone, the view glides after it with the tip up
world() autozoomToggle()
pump(3000, hoverAt(800, 500))
local sxF, syF = W.sx, W.sy
local function writeRight(t) jit = 1 - jit W.pen.x, W.pen.y, W.pen.down = 1900 + jit, 600, (t % 250) < 150 end
pump(2000, writeRight)
check("follow: no movement between letters", near(W.sx, sxF) and near(W.sy, syF) and W.zoomCallsWhileDown == 0, W.sx - sxF)
pump(200, hoverAt(1900, 600))
check("follow: still waiting 200 ms after the pen went up", near(W.sx, sxF), W.sx - sxF)
pump(4000, hoverAt(1900, 600))
-- still zone 60 % of 2175: right edge at 1087.5 + 652.5 = 1740; the ink at 1900 must come to it
check("follow: view glides so the writing sits at the still-zone edge", near(W.sx - sxF, 160, 2) and near(W.sy, syF, 0.01),
      string.format("dx %.2f dy %.2f", W.sx - sxF, W.sy - syF))

-- 18. smoothness: zoom steps are small, never backwards, and a turn-round has no jump
world() autozoomToggle()
z0 = W.zoom
local last, maxStep, backwards = W.zoom, 0, 0
local function watch(f) return function(t) f(t) local d = math.log(W.zoom / last) if d < -1e-12 then backwards = backwards + 1 end maxStep = math.max(maxStep, math.abs(d)) last = W.zoom end end
pump(3000, watch(hoverAt(800, 500)))
check("zoom in: no step bigger than 2.5 % and never backwards", maxStep < 0.025 and backwards == 0, string.format("max %.4f back %d", maxStep, backwards))
for _ = 1, 200 do                     -- idle, until the zoom out is under way (not tied to a fixed time)
    pump(32, watch(frozen()))
    if W.zoom < z0 * 1.4 then break end
end
local mid = W.zoom
check("zoom out is under way", mid < z0 * 1.59 and mid > z0 * 1.01, mid / z0)
maxStep = 0
local function penDown() W.pen.x, W.pen.y, W.pen.down = 900, 600, true end
pump(100, watch(penDown))
check("writing during zoom out: view frozen while the tip is down", W.zoomCallsWhileDown == 0 and W.zoom == last)
pump(3500, watch(hoverAt(900, 600)))
check("turn-round goes back in to 1.6 without a jump", near(W.zoom / z0, 1.6, 1e-9) and maxStep < 0.025, string.format("ratio %.4f max %.4f", W.zoom / z0, maxStep))

-- 19. settings file: loaded at start; edge slide alone (not zoomed in)
do
    local f = io.open(AUTOZOOM_SETTINGS_FILE, "w")
    f:write("FACTOR=2.0\nPAN_IDLE=true\nHOVER_TRIGGER=false\nIDLE_MS=999999\nJUNK=1\nZOOM_MS=abc\n")
    f:close()
end
world({sx = 0}) initUi() autozoomToggle()
W.zoom = 2.5 W.clamp()
z0 = W.zoom
local sxI = W.sx
pump(2500, hoverAt(2150, 600))
check("edge slide when not zoomed in (setting from the file)", W.sx > sxI + 100 and W.zoom == z0, W.sx - sxI)
autozoomNow() pump(3000, frozen())
check("zoom level 2.0 read from the settings file (IDLE_MS clamped to 15 s)", near(W.zoom / z0, 2.0, 1e-9), W.zoom / z0)
os.remove(AUTOZOOM_SETTINGS_FILE)
-- 9c. zoomed out by hand in steps while zoomed in, ending just above the base zoom:
-- that is "zoom out", the small steps on the way are never learned as the zoom level
world() autozoomToggle()
z0 = W.zoom
pump(3000, hoverAt(800, 500))
for _, f in ipairs({1.87, 1.70, 1.55, 1.41, 1.28, 1.16}) do
    userZoom(z0 * f)
    pump(150, hoverAt(800, 500))
end
pump(6000, frozen())
check("hand zoom out to x 1.16: plugin lets go, view kept", near(W.zoom / z0, 1.16, 1e-9), W.zoom / z0)
local zUser = W.zoom
pump(3000, hoverAt(1200, 700))
check("level not learned from the steps: next zoom-in is still 1.6", near(W.zoom / zUser, 1.6, 1e-9), W.zoom / zUser)
os.remove(AUTOZOOM_SETTINGS_FILE)

-- 9d. a hand zoom in steps that ends at a real level: only the last one is learned
world() autozoomToggle()
z0 = W.zoom
pump(3000, hoverAt(800, 500))
for _, f in ipairs({1.8, 2.0, 2.2}) do
    userZoom(z0 * f)
    pump(150, hoverAt(800, 500))
end
pump(8000, frozen())
pump(3000, hoverAt(1200, 700))
check("hand zoom in steps: the level where it rested (2.2) is learned", near(W.zoom / z0, 2.2, 1e-9), W.zoom / z0)
os.remove(AUTOZOOM_SETTINGS_FILE)

-- 9e. edge slide: with the pen, not with the hand tool
for _, hand in ipairs({false, true}) do
    world() autozoomToggle()
    W.tool = 1
    app.C = {Tool_pen = 1, Tool_hand = 13}
    function app.getActionState(a) return W.tool end
    pump(3000, hoverAt(800, 500))
    W.tool = hand and 13 or 1
    pump(300, hoverAt(800, 500))
    local sxA = W.sx
    pump(1500, hoverAt(W.vw - 20, 500))
    if hand then check("hand tool: no edge slide", near(W.sx, sxA, 0.5), W.sx - sxA)
    else check("pen: edge slide moves the view", W.sx - sxA > 50, W.sx - sxA) end
end

-- 20. tools that do not write, and dragging a selection, never zoom (v0.3)
local function withTools()
    world() autozoomToggle()
    W.tool, W.sel, W.selAsked = 1, {}, 0
    app.C = {Tool_pen = 1, Tool_highlighter = 3, Tool_selectRect = 6}
    function app.getActionState(a) return W.tool end
    function app.getStrokes(kind) W.selAsked = W.selAsked + 1 return W.sel end
    z0 = W.zoom
end
withTools()
W.tool = 6
pump(6000, writing)
check("Select Rectangle tool: a drag does not zoom", W.zoom == z0 and W.zoomCalls == 0)
pump(3000, hoverAt(800, 500))
check("Select Rectangle tool: hovering does not zoom", W.zoom == z0 and W.zoomCalls == 0)
W.tool = 1
pump(9000, writing)
check("back on the pen: writing zooms again", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)

withTools()
W.sel = {{x = {1, 2}, y = {1, 2}}}
pump(6000, writing)
check("pen tool with a selection: dragging it does not zoom", W.zoom == z0 and W.zoomCalls == 0)
check("selection is asked once per pen-down, not at every tick", W.selAsked > 0 and W.selAsked < 40, W.selAsked)
pump(3000, hoverAt(800, 500))
check("hovering over a selection does not zoom", W.zoom == z0 and W.zoomCalls == 0)
W.sel = {}
pump(9000, writing)
check("selection gone: writing zooms again", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)

-- 20b. zoomed in, then a long drag with Select Rectangle (a snapshot): no zoom out on the release (v0.16.1)
withTools()
pump(6000, writing)
pump(500, hoverAt(800, 500))
local zIn = W.zoom
W.tool = 6
pump(5000, function(t) W.pen.x, W.pen.y, W.pen.down = 700 + (t or 0) / 25, 450 + (t or 0) / 50, true end)
pump(400, hoverAt(900, 550))
check("zoomed in: a 5 s Select Rectangle drag does not zoom out on the release", W.zoom == zIn, W.zoom / z0)
pump(4000, frozen())
check("zoomed in: still zooms out after the idle time once the drag ended", W.zoom == z0, W.zoom / z0)

for _, t in ipairs({3, 23}) do     -- highlighter, laser pointer pen
    withTools()
    W.tool = t
    pump(9000, writing)
    check("tool " .. t .. " counts as writing", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)
end
withTools()
app.C = nil
W.tool = 23
pump(9000, writing)
check("laser pointer zooms without app.C too", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)
withTools()
app.C = nil
W.tool = 13
pump(6000, writing)
check("hand tool does not zoom", W.zoom == z0 and W.zoomCalls == 0)
withTools()
app.C.Tool_eraser, app.C.Tool_hand = 2, 13
W.tool = 2
pump(6000, writing)
check("eraser does not zoom (0.11)", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
withTools()
app.C.Tool_eraser, app.C.Tool_hand = 2, 13
W.tool = 2
pump(6000, hoverAt(700, 450))
check("eraser hovering still does not zoom", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
withTools()
app.C = nil
W.tool = 2
pump(6000, writing)
check("eraser does not zoom without app.C", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
withTools()
app.C.Tool_eraser, app.C.Tool_hand = 2, 13
W.tool = 13
pump(6000, hoverAt(700, 450))
check("hand hovering still does not zoom", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)

-- 30. pause (0.16, 0.17): everything stops: no zoom in / out, no edge slide, no follow
local function env(k) return W.env and W.env[k] end
local function writeAt(x, y) return function(t) jit = 1 - jit W.pen.x, W.pen.y, W.pen.down = x + jit, y, (t % 250) < 150 end end
world()
autozoomPause()
check("pause while OFF switches on, paused", env("XOPP_AUTOZOOM_ON") == "1" and env("XOPP_AUTOZOOM_PAUSED") == "1" and live() == 1,
      tostring(env("XOPP_AUTOZOOM_ON")) .. " " .. tostring(env("XOPP_AUTOZOOM_PAUSED")))
z0 = W.zoom
pump(3000, hoverAt(800, 500))
check("paused: hovering does not zoom in", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
pump(3000, writeAt(800, 500))
check("paused: writing does not zoom in", W.zoom == z0 and W.zoomCalls == 0, W.zoomCalls)
local syE = W.sy
pump(2600, hoverAt(800, 1215))
check("paused, not zoomed in: no edge slide", W.sy == syE and W.zoom == z0, W.sy - syE)
pump(1500, hoverAt(800, 500))
autozoomPause()
check("pause ended", env("XOPP_AUTOZOOM_PAUSED") == "0" and env("XOPP_AUTOZOOM_ON") == "1")
pump(3000, hoverAt(800, 500))
check("after the pause: hover zooms in again", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)
local zZ = W.zoom
autozoomPause()
pump(8000, frozen())
check("paused while zoomed in: no zoom out", W.zoom == zZ, W.zoom / z0)
local sxZ2 = W.sx
pump(2600, hoverAt(2150, 600))
check("paused while zoomed in: no edge slide", W.sx == sxZ2 and W.zoom == zZ, W.sx - sxZ2)
pump(500, hoverAt(1000, 600))
local sxF, syF = W.sx, W.sy
pump(200, writeAt(1000, 1080))
pump(3000, hoverAt(1000, 600))
check("paused while zoomed in: no follow glide", W.sx == sxF and W.sy == syF and W.zoom == zZ, W.sy - syF)
autozoomNow() pump(3000, frozen())
check("paused: Ctrl+Alt+F6 still zooms out", W.zoom == z0, W.zoom / z0)
autozoomNow() pump(3000, frozen())
check("paused: Ctrl+Alt+F6 still zooms in", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)
pump(8000, frozen())
check("paused: zoomed in by key stays in", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)
autozoomPause()
pump(1000, frozen())
check("pause ended while zoomed in: no instant zoom out", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)
local sxR = W.sx
pump(2600, hoverAt(2150, 600))
check("pause ended: edge slide works again", W.sx > sxR + 100, W.sx - sxR)
pump(300, hoverAt(1000, 600))
pump(6000, frozen())
check("pause ended: zooms out after the idle time", W.zoom == z0, W.zoom / z0)
autozoomPause() autozoomToggle()
check("switching OFF ends the pause", env("XOPP_AUTOZOOM_PAUSED") == "0" and env("XOPP_AUTOZOOM_ON") == "0")
autozoomToggle()
pump(3000, hoverAt(800, 500))
check("on again: not paused", near(W.zoom / z0, 1.6, 1e-9), W.zoom / z0)

out[#out + 1] = (fails == 0) and "\nall checks passed" or ("\nFAILED: " .. fails)
return table.concat(out, "\n")
