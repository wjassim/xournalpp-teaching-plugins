-- Real GdkPixbuf test (no Xournal++): makes a page-sized PNG with one coloured block, lets the plugin
-- cut that block out, reads the cut file back and checks size and colour.
-- Run:  powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_pixbuf.lua
local PLUGIN = PLUGIN_PATH or ((os.getenv("LOCALAPPDATA") or ".") .. [[\xournalpp\plugins\snapshot\main.lua]])
local TEMP = os.getenv("TEMP") or "."
SNAPSHOT_TEST = true
SNAPSHOT_LOG_FILE = TEMP .. "\\snapshot_test.log"
app = {}

local out, fails = {}, 0
local function check(name, cond, detail)
    out[#out + 1] = (cond and "PASS " or "FAIL ") .. name .. ((not cond and detail) and ("  -> " .. tostring(detail)) or "")
    if not cond then fails = fails + 1 end
end

local lgo = require("LuaGObject")
local Pix = lgo.require("GdkPixbuf", "2.0")
dofile(PLUGIN)
local I = SNAPSHOT_INTERNALS

-- page 960 x 540 pt at 2 px per pt = 1920 x 1080 px, white, red block at pt (100, 50) size 200 x 100
local page = Pix.Pixbuf.new(Pix.Colorspace.RGB, false, 8, 1920, 1080)
page:fill(0xffffffff)
local block = page:new_subpixbuf(200, 100, 400, 200)
block:fill(0xff0000ff)
local src, dst = TEMP .. "\\snapshot_pixbuf_page.png", TEMP .. "\\snapshot_pixbuf_cut.png"
os.remove(dst)
check("test page written", page:savev(src, "png", {}, {}) == true)

I.CFG.TRANSPARENT = false
local t0 = os.clock()
local rect, err = I.cropFile(src, dst, {x = 100, y = 50, w = 200, h = 100}, 960, 540)
check("cropFile succeeds", rect ~= nil, err)
check("crop rectangle in pixels", rect and rect.x == 200 and rect.y == 100 and rect.w == 400 and rect.h == 200)
local cut = Pix.Pixbuf.new_from_file(dst)
check("cut file size 400 x 200", cut and cut:get_width() == 400 and cut:get_height() == 200,
      cut and (cut:get_width() .. "x" .. cut:get_height()))
if cut then
    local onePx = cut:new_subpixbuf(0, 0, 1, 1):scale_simple(1, 1, Pix.InterpType.NEAREST)
    local whole = cut:scale_simple(1, 1, Pix.InterpType.BILINEAR)
    local bytes = whole:get_pixels()
    local rr, gg, bb = tostring(bytes):byte(1, 3)
    check("cut is the red block (average colour)", rr and rr > 240 and gg < 15 and bb < 15,
          tostring(rr) .. "," .. tostring(gg) .. "," .. tostring(bb))
end
local bad, berr = I.cropFile(TEMP .. "\\no_such_file.png", dst, {x = 0, y = 0, w = 10, h = 10}, 960, 540)
check("missing page file gives an error, no crash", bad == nil and berr ~= nil)
out[#out + 1] = string.format("crop of a 1920 px page took %.2f s", os.clock() - t0)

-- transparent background: box larger than the red block, so white is the background
I.CFG.TRANSPARENT = true
local t1 = os.clock()
local r2, pic = I.cropFile(src, dst, {x = 50, y = 25, w = 400, h = 200}, 960, 540)
check("transparent crop succeeds", r2 ~= nil and r2.w == 800 and r2.h == 400, pic)
check("white found as the background", r2 and r2.note == "background 255,255,255 removed", r2 and r2.note)
local clear = Pix.Pixbuf.new_from_file(dst)
check("file has an alpha channel, same size", clear and clear:get_has_alpha() and clear:get_width() == 800 and clear:get_height() == 400)
if clear then
    local px, stride = clear:get_pixels(), clear:get_rowstride()
    local function at(x, y) return px:byte(y * stride + x * 4 + 1, y * stride + x * 4 + 4) end
    local r, g, b, a = at(5, 5)
    check("background pixel is fully see-through", a == 0, a)
    r, g, b, a = at(300, 200)
    check("red block stays solid red", r == 255 and g == 0 and b == 0 and a == 255, table.concat({r, g, b, a}, ","))
end
check("returned picture is the transparent one", pic and pic:get_has_alpha() == true)
out[#out + 1] = string.format("transparent crop took %.2f s", os.clock() - t1)

-- colour to alpha, pixel by pixel: laid back on the background it gives the first colour again
local T = I.fadeTable({{255, 255, 255}}, 0)
local function back(k)
    local v = T[k]
    local r, g, b, a = v:byte(1, 4)
    local f = a / 255
    return math.floor(r * f + 255 * (1 - f) + 0.5), math.floor(g * f + 255 * (1 - f) + 0.5),
           math.floor(b * f + 255 * (1 - f) + 0.5), a
end
local r, g, b, a = back(string.char(128, 128, 128, 255))
check("soft edge of a letter: half see-through black", a >= 126 and a <= 128 and math.abs(r - 128) <= 1 and math.abs(g - 128) <= 1, table.concat({r, g, b, a}, ","))
r, g, b, a = back(string.char(253, 234, 234, 255))
check("light tint on white: mostly see-through, same look on white", a < 30 and math.abs(r - 253) <= 2 and math.abs(g - 234) <= 2 and math.abs(b - 234) <= 2, table.concat({r, g, b, a}, ","))
r, g, b, a = back(string.char(0, 0, 0, 255))
check("black stays solid", a == 255 and r == 0)
local T2 = I.fadeTable({{253, 234, 234}}, 0)
check("tinted background itself becomes see-through", T2[string.char(253, 234, 234, 255)]:byte(4) == 0)
check("white on a tinted background is kept", T2[string.char(255, 255, 255, 255)]:byte(4) > 0)

-- a rectangle dragged along a frame: the frame colour must not win
local W2, H2 = 300, 200
local frame = Pix.Pixbuf.new(Pix.Colorspace.RGB, true, 8, W2, H2)
frame:fill(0x1e90ffff)
frame:new_subpixbuf(4, 4, W2 - 8, H2 - 8):fill(0xeef6ffff)
local fl = I.backgroundColours(frame:get_pixels(), W2, H2, frame:get_rowstride())
check("frame around the picture: the inside colour is the background", #fl == 1 and fl[1][1] == 0xee and fl[1][2] == 0xf6 and fl[1][3] == 0xff,
      #fl .. ": " .. table.concat(fl[1], ","))

-- a tinted card with white page around it, a pale outline, a big strong block and a letter
local card = Pix.Pixbuf.new(Pix.Colorspace.RGB, true, 8, 400, 300)
card:fill(0xffffffff)                                       -- white page
card:new_subpixbuf(30, 30, 340, 240):fill(0xf7c8c8ff)       -- pale outline of the card
card:new_subpixbuf(32, 32, 336, 236):fill(0xfdeaeaff)       -- pink fill
card:new_subpixbuf(40, 40, 150, 100):fill(0xc9005cff)       -- strong block, over 5 % of the picture
card:new_subpixbuf(250, 200, 20, 20):fill(0x212529ff)       -- a "letter"
local cl = I.backgroundColours(card:get_pixels(), 400, 300, card:get_rowstride())
check("card + page: two background colours, the strong block is not one", #cl == 2 and cl[1][2] == 0xea and cl[2][2] == 0xff,
      #cl .. ": " .. table.concat(cl[1], ",") .. (cl[2] and (" + " .. table.concat(cl[2], ",")) or ""))
local T3 = I.fadeTable(cl, 0.20)
local function alpha(r, g, b) return T3[string.char(r, g, b, 255)]:byte(4) end
check("white page around the card is see-through", alpha(255, 255, 255) == 0)
check("pink fill is see-through", alpha(0xfd, 0xea, 0xea) == 0)
check("pale outline of the card is cut off", alpha(0xf7, 0xc8, 0xc8) == 0, alpha(0xf7, 0xc8, 0xc8))
check("strong block stays solid", alpha(0xc9, 0x00, 0x5c) == 255, alpha(0xc9, 0x00, 0x5c))
check("letter stays solid", alpha(0x21, 0x25, 0x29) >= 215, alpha(0x21, 0x25, 0x29))
check("highlighter yellow on white stays", alpha(255, 255, 128) >= 120, alpha(255, 255, 128))
local keep = T3[string.char(0xf7, 0xc8, 0xc8, 255)]
check("a see-through pixel keeps its own colour (for Paint)", keep:byte(1) == 0xf7 and keep:byte(2) == 0xc8)
check("FAINT_CUT = 0 keeps the outline", I.fadeTable(cl, 0)[string.char(0xf7, 0xc8, 0xc8, 255)]:byte(4) > 0)
I.CFG.BG_NEAR = 0
check("BG_NEAR = 0: one background colour only", #I.backgroundColours(card:get_pixels(), 400, 300, card:get_rowstride()) == 1)
I.CFG.BG_NEAR = 60
os.remove(src)
os.remove(dst)

out[#out + 1] = (fails == 0 and "ALL PASS" or ("FAILED " .. fails))
return table.concat(out, "\n")
