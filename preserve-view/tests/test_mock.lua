-- Mock test of preserve-view: a fake Xournal++ layout with the real placement rule
-- (page top = floor(heights before * zoom) + index * 15 + padding, whole-pixel scrolling).
-- Run: powershell -ExecutionPolicy Bypass -File ..\autozoom\tests\run_lua55.ps1 tests\test_mock.lua
local dir = (os.getenv("LOCALAPPDATA") or ""):gsub(string.char(92), "/") .."/xournalpp/plugins/preserve-view/"
local fails, checks = 0, 0
PRESERVE_VIEW_SETTINGS_FILE = (os.getenv("TEMP") or ".") .. "/preserve_view_test_settings.txt"
local function check(cond, msg)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. msg) end
end

-- zoom = screen pixels per page point. The plugin only sees zoom / K100 (app.getZoom) and
-- either the scroll area height (mock GTK) or the rounded DPI.
local function run(zoom, heights, wholePixels, gtk, K100)
    local N, VIEW, PAD, gapPx = #heights, 1080, 10, 15
    local cum = {0}
    for i = 1, N do cum[i + 1] = cum[i] + heights[i] end
    local function top(n) return math.floor(cum[n] * zoom) + (n - 1) * gapPx + PAD end
    local total = top(N) + math.ceil(heights[N] * zoom) + PAD
    local y, dialogs, pageJumps = 0, {}, 0
    local function setY(v)
        if wholePixels then v = math.floor(v + 0.5) end
        y = math.max(0, math.min(v, total - VIEW))
    end
    local function current()
        local c = y + VIEW / 2
        for n = N, 1, -1 do if c >= top(n) - gapPx / 2 then return n end end
        return 1
    end
    local before = {PRESERVE_VIEW_SETTINGS_FILE = true}
    for k in pairs(_G) do before[k] = true end
    app = {
        getScrollPos = function() return {x = 0, y = y, width = 1920, height = VIEW} end,
        getZoom = function() return zoom / K100 end,
        getDisplayDpi = function() return math.floor(K100 * 72 + 0.5) end,
        getDocumentStructure = function()
            local p = {}
            for i = 1, N do p[i] = {pageHeight = heights[i], pageWidth = 960} end
            return {pages = p, currentPage = current()}
        end,
        scrollToPos = function(dx, dy, rel) if rel then setY(y + dy) else setY(dy) end end,
        scrollToPage = function(n)      -- gtk_adjustment_clamp_page
            pageJumps = pageJumps + 1
            local lo, up = top(n), top(n) + math.floor(heights[n] * zoom)
            local v = y
            if v + VIEW < up then v = up - VIEW end
            if v > lo then v = lo end
            setY(v)
        end,
        openDialog = function(m) dialogs[#dialogs + 1] = m end,
        registerUi = function() end,
    }
    -- mock LuaGObject: window > box > scrolled window > canvas "GtkXournal"
    local function widget(name, kids)
        return {get_name = function() return name end, get_children = function() return kids or {} end,
                get_visible = function() return true end, kind = name, isBox = kids ~= nil,
                get_vadjustment = function() return {get_upper = function() return math.max(total, VIEW) end} end}
    end
    local win = widget("win", {widget("box", {widget("side"), widget("scrolled", {widget("GtkXournal")})})})
    package.loaded["LuaGObject"] = gtk and {require = function() return {
        Window = {list_toplevels = function() return {win} end},
        ScrolledWindow = {is_type_of = function(_, w) return w.kind == "scrolled" end},
        Container = {is_type_of = function(_, w) return w.isBox end}} end} or nil
    package.preload["LuaGObject"] = (not gtk) and function() error("no GTK in this test") end or nil
    dofile(dir .. "main.lua")
    local tag = string.format("zoom %.4f whole=%s gtk=%s K100=%.4f", zoom, tostring(wholePixels), tostring(gtk), K100)

    pageJumps = 0
    local offset = 137
    setY(top(3) + offset)
    local start, worst = y, 0
    for i = 1, 30 do
        nextPageKeepView()
        local d = math.abs((y - top(3 + i)) - offset)
        if d > worst then worst = d end
    end
    check(worst <= 1.0, tag .. " forward drift " .. worst)
    for i = 1, 30 do previousPageKeepView() end
    check(math.abs(y - start) <= 1.0, tag .. " return error " .. math.abs(y - start))
    check(pageJumps == 0, tag .. " a hop must never jump to another page (" .. pageJumps .. ")")
    -- to the very end and back: clamp shortfall carried; blocked presses move nothing
    local moves = 0
    local realScroll = app.scrollToPos
    app.scrollToPos = function(...)    -- count only presses that really moved the view
        local y0 = y
        realScroll(...)
        if y ~= y0 then moves = moves + 1 end
    end
    local zoomedOut = heights[1] * zoom * 2 < VIEW   -- several pages in the window: view stops before the end page is "current"
    for i = 1, N + 5 do nextPageKeepView() end
    check(zoomedOut or current() == N, tag .. " reaches last page")
    local fwd = moves
    for i = 1, fwd do previousPageKeepView() end
    check(math.abs(y - start) <= 1.0, tag .. " return from end error " .. math.abs(y - start))
    moves = 0
    for i = 1, N + 5 do previousPageKeepView() end   -- to page 1, then blocked
    check(zoomedOut or current() == 1, tag .. " reaches first page")
    local back = moves
    for i = 1, back do nextPageKeepView() end
    check(math.abs(y - start) <= 1.0, tag .. " return from start error " .. math.abs(y - start))
    do
        local n0, y0 = #dialogs, y
        recalibrate()
        local fits = heights[N - 1] * zoom + 15 + heights[N] * zoom <= VIEW
        local want = fits and "Check failed" or "Check OK."
        check(#dialogs == n0 + 1 and dialogs[#dialogs]:find(want, 1, true) ~= nil, tag .. " step check: " .. tostring(dialogs[#dialogs]))
        check(math.abs(y - y0) <= 1.0, tag .. " step check restores view")
    end
    local allowed = {app = 1, nextPageKeepView = 1, previousPageKeepView = 1, nudgeDown = 1, nudgeUp = 1,
                     recalibrate = 1, debugShowScrollPos = 1, initUi = 1,
                     preserveViewPanel = 1}
    do  -- nudge uses the step from the settings
        local y0 = y
        nudgeDown()
        check(y - y0 == 5 or y == y0, tag .. " nudge down by 5")
    end
    for k in pairs(_G) do
        if not before[k] and not allowed[k] then check(false, "leaked global " .. tostring(k)) end
    end
    for k in pairs(allowed) do _G[k] = nil end
end

local same, mixed = {}, {}
for i = 1, 40 do same[i] = 540; mixed[i] = (i % 3 == 0) and 720 or 540 end
for _, z in ipairs({1.0, 2.3137, 2.26667, 3.71, 0.61}) do
    for _, whole in ipairs({true, false}) do
        -- with GTK: any screen DPI (K100 = DPI / 72, here not a whole DPI) must be exact
        run(z, same, whole, true, 1.3379)
        if z > 2 then run(z, mixed, whole, true, 1.3379) end   -- mixed heights: exact when one page fills the window
        -- without GTK: exact only when the DPI is a whole number (96 dpi: K100 = 4/3)
        run(z, same, whole, false, 96 / 72)
    end
end
print(string.format("%d checks, %d failed", checks, fails))
