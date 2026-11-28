# Developing

Notes for anyone who wants to change these plugins. The user guide is in [README.md](README.md) and in each
plugin's own README.

## Layout

    autozoom/        main.lua, plugin.ini, README.md, CHANGELOG.md, tests/
    snapshot/        same
    tool-dock/       same
    preserve-view/   same (its tests use autozoom/tests/run_lua55.ps1)

Each plugin writes its own `settings.txt` next to `main.lua` (not tracked) and a log in the temp folder.

Dock icons: a plugin may add `dock.txt` (one line per Plugin menu entry: `<menu entry> = <icon name>`,
optionally `| <ON flag>`) and an `icons/` folder with `<icon name>.svg`. Draw the SVG on a 16 x 16 grid
with filled shapes only (no strokes) and name it `...-symbolic` so GTK colours it for the light or dark
theme. The tool dock (0.9+) reads these at start; nothing in the dock needs changing for a new plugin.

## Requirements

- Xournal++ 1.3.x. Since 1.3.0 the Windows and macOS releases ship Lua 5.5 and LuaGObject; the plugins
  need LuaGObject for their windows and for the GLib timer. If LuaGObject is missing they try `lgi`
  (Linux package `lua-lgi`; not tested). 1.2.x is not supported.
- `app.getScrollPos` exists only in the nightly (it goes into the next big release; 1.3.x only gets fixes).
  autozoom, snapshot and preserve-view use it when present. Without it they read the adjustments of the
  page canvas's `GtkScrolledWindow` (value = x / y, page size = width / height). Checked in the nightly:
  0.000 px difference at every zoom, scroll and page jump, also right after `setZoom`. The adjustments are
  kept after the first lookup (0.017 ms per read).
- Wayland doesn't let an app place its own windows or read the pointer on the whole screen. Floating
  windows can't be placed and pen tracking may not work there: use `GDK_BACKEND=x11` (XWayland).

## Rules (learned the hard way)

- Never connect a Lua handler to a GTK signal. A test handler on the canvas `event` signal crashed
  Xournal++ with a stack overflow about 80 s later. Read widgets from a GLib timer instead.
- Never `require("ffi")`: Xournal++ runs Lua 5.5, and an `ffi.dll` found on the system path may be built
  for another Lua version.
- Never call `app.getDocumentStructure` on every timer tick: it costs about 8 ms on a big document.
- Never change zoom or scroll while the pen tip is down.
- Scroll to whole pixels only. A decimal scroll position blurs the page.
- A plugin change needs a Xournal++ restart. Each plugin has its own Lua state, so plugins can't share
  variables (autozoom tells tool-dock its on / off state through the process environment
  `XOPP_AUTOZOOM_ON`).
- Don't give two plugins the same key. Ctrl+Alt+digit is AltGr on some keyboards (Irish, UK), so the
  defaults use Ctrl+Alt+F-keys and arrows.
- Keep the defaults quiet: no pop-ups, nothing that steals the keyboard.

## Page layout

autozoom, snapshot and preserve-view turn screen positions into (page, point on the page) from Xournal++'s
layout: 10 px before the first page and 15 px between pages (`src/core/gui/Layout.cpp`,
`XOURNAL_PADDING_BETWEEN = 15`), pages placed at

    floor(sum of the heights of the pages before it * s) + n * 15 + padding

where s = screen pixels per page point. s is not `app.getZoom()`: that is the zoom relative to 100 %, and
100 % is itself screen DPI / 72 pixels per point. s is read from the height of the whole scroll area:

    2 * 10 + (pages - 1) * 15 + (sum of all page heights) * s

The 15 px gaps don't scale with the zoom, so a plain "scroll times zoom ratio" lands pages away in a long
PDF. If a new Xournal++ build changes the layout, positions go wrong, so:

- preserve-view has *Check Page Step* (Ctrl+Alt+F10), which compares the computed step with a real one.
- autozoom and snapshot compare the scale read from the scroll area with zoom x screen DPI / 72 on every
  use. More than 5 % apart shows "layout check failed" and the numbers go to the log.

When the whole document fits in the view (zoom to fit on a short document), the scroll area is the view
itself and Xournal++ centres the pages in it. autozoom and snapshot then take s from zoom x DPI / 72 and add
the empty space above the first page, floor((view height - pages) / 2). preserve-view doesn't need this:
its page step uses the same estimate whenever the two numbers disagree by more than 3 %.

Single-column layout is assumed. Pages side by side, horizontal layout and "add vertical space" fall back
to the simple formula.

## How each plugin works

**autozoom.** The plugin API has no pen events and no timer, so a GLib timer runs every 16 ms while auto
zoom is on or the panel is open. It asks GDK for the pointer position on the page canvas (widget
`GtkXournal`) and the tip state (button 1); positions come out in page-area pixels, so no calibration is
needed. To keep a point fixed while zooming it converts the pen position to (page, point), zooms, reads
the new scroll range, and puts that point back under the pen. All movement uses a critically damped
spring. The panel is plain GTK widgets read by the same timer about 10 times a second (the "defaults"
button is a toggle the timer sets back). Window checks (is Xournal++ in front, is a menu or dialog over
the page) are cached: a full look at all ~40 windows every 2 s, the shown ones every 250 ms. Settings not
in the panel are in the `CFG` table at the top of `main.lua`: `RADIUS`, `ALIVE_MS`, `STALE_MS`,
`WRITE_GAP_MS`, `MOVE_PX`, `PAN_DELAY_MS`, `PAN_ALIVE_MS`, `TICK_MS` (16), `PAD` / `GAP` (10 / 15).

**snapshot.** A GLib timer polls the pointer on the page canvas and notes where the drag starts and ends,
while Xournal++'s own Select Rectangle tool draws the box. The two points become page points through the
page layout, the page is exported to a PNG in the temp folder (at the start of the mode when
`EARLY_EXPORT` is on), the region is cut out with GdkPixbuf, its background is made see-through, and the
picture is inserted with `app.addImages` at the same place and size, selected, and put on the GTK
clipboard. See-through background: `backgroundColours` (most common colours on a grid of points),
`fadeTable` (colour to alpha, one table entry per colour), `transparentCopy` (the whole picture through one
`string.gsub` over its pixels, 4 bytes each). If that fails, a solid copy is made and the log says why.
A see-through pixel keeps its own colour, so a program that ignores transparency shows the background.

**tool-dock.** The dock is a GTK window made with LuaGObject. One GLib timer runs only while the dock, the
edit list or the remove box is shown, and polls every button: a button found pressed in = a click, then it
springs back. The buttons are only asked when a press starts on the dock, so writing on the page costs
nothing. A long press is the button's `ACTIVE` state held for `LONG_MS`; a right-click is the right button
going down (`BUTTON3_MASK`) with the pointer over a dock button and no other window over the dock. The
grip is a button too: while it is pressed in, the timer moves the window by the pointer's screen movement
(`Gdk.Device:get_position`). Tools: `app.changeActionState("select-tool", app.C.Tool_...)`. Shapes are
drawing modes of the pen ("tool-draw-arrow" ...). Colours: `app.changeToolColor`. Thickness:
`app.changeActionState("tool-size", app.C.ToolSize_...)`, read back with `app.getActionState("tool-size")`
(0 to 4). Line styles (0.8): `app.changeActionState("tool-pen-line-style", "plain" | "dash" | "dashdot" |
"dot")`; `app.getActionState("tool-pen-line-style")` gives the CURRENT tool's style (`"none"` on the laser,
eraser, highlighter or select tools; the pen keeps its own, `app.getToolInfo("pen").lineStyle`). The lit
button follows the current tool's style, like Xournal++'s Pen Options menu, which ticks nothing off the pen
(checked live). Setting a style while on another tool makes Xournal++ switch to the pen by itself; a
drawing mode (arrow ...) stays on. Moving a button swaps two places in `TOOLS` (or `COLOURS`), stepping
over tools this build doesn't have. The move window is not modal: a press that starts off the dock and off
that window (checked with its frame extents) closes it. Custom buttons run the menu item itself. Facts checked: `app.getActionState("tool-color")` is
ARGB (`0xFF......`); `app.changeToolColor` on a tool without colour raises "has no color capability", with
`tool = "pen"` it works. The `:backdrop` CSS rule keeps the button text in the theme's normal colour.

**preserve-view.** A hop is a plain relative scroll of exactly one page pitch, which keeps the relative
view by construction (`app.scrollToPage()` can't: it scrolls the minimum amount to make the page visible).
The pitch is computed: `pageHeight * s + 15`, a decimal number of pixels, with the height of the page
being crossed. The decimal part of each hop is carried into the next one (`residual`), so the view stays
within one pixel of the true place however many hops. If GTK can't be reached, or s disagrees with
`getZoom() * getDisplayDpi() / 72` by more than 3 %, the estimate is used instead. The Page step window is
read by a GLib timer about 30 times a second while it's open; the page number is read only after a click,
a scroll, or every 3 s.

**Page number in the Page step window (preserve-view 2.8.1).** `app.getDocumentStructure` costs about
21 ms on a 1228-page document, so the window keeps the page tops (EDGE_PAD 10, PAGE_GAP 15, page heights
x pixels per point) and takes the page under the middle of the view: checked live at 3 zooms, 179 scroll
positions, 0 differences from Xournal++'s `currentPage`. Real read every 30 s and after a zoom change.

**Carry ink (preserve-view 2.8).** Runs only inside a forward hop that moved the view, never on a timer.
`app.setCurrentPage(from)` (it doesn't scroll), read the current layer with `getStrokes` / `getTexts` /
`getImages("layer")`, `app.setCurrentPage(to)`, read the target the same way, then add copies with
`addStrokes` / `addTexts` / `addImages` (`ref` left out), then `app.refreshPage()`: without it the
new ink is in the page but not drawn (2.8.1 fix; a mock test can't see this, only a look at the screen can). Facts checked live on 1.3.x: each add call is
its own undo step, even with `"grouped"`; `addImages` takes whole-number `maxWidth` / `maxHeight` only
("number has no integer representation"), so picture sizes are rounded and compared rounded; deleting =
`clearSelection` + `addToSelection(refs)` + `activateAction("delete")`, one undo step (the tool is read
before and put back if it changed). "Add only what is missing" compares items by a key (tool, colour,
width, point count, first and last point; text and place; picture place, size and data length). On / off
goes to the tool-dock through `XOPP_CARRYINK_ON`. Costs on a 420-page document: a hop 8 ms, a hop with a
carry 12-21 ms.

## Tests

The tests run with Xournal++'s own Lua 5.5, without Xournal++ itself. `run_lua55.ps1` loads `lua55.dll`
from `%LOCALAPPDATA%\Programs\Xournal++\bin` (a per-user install); change `$X` at its top if Xournal++ is
somewhere else. Run them from the plugin's folder:

    cd autozoom
    powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_mock.lua
    powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_gtk_smoke.lua
    powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\show_panel.lua

    cd snapshot
    powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_mock.lua
    powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_gtk_smoke.lua
    powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_pixbuf.lua

    cd tool-dock
    powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_mock.lua
    powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\test_gtk_smoke.lua
    powershell -ExecutionPolicy Bypass -File tests\run_lua55.ps1 tests\show_dock.lua
    powershell -ExecutionPolicy Bypass -File tests\grab_small_screens.ps1 [out folder]

    cd preserve-view
    powershell -ExecutionPolicy Bypass -File ..\autozoom\tests\run_lua55.ps1 tests\test_mock.lua
    powershell -ExecutionPolicy Bypass -File ..\autozoom\tests\run_lua55.ps1 tests\test_gtk_smoke.lua
    powershell -ExecutionPolicy Bypass -File ..\autozoom\tests\run_lua55.ps1 tests\test_carry.lua

- `test_mock.lua`: a fake clock, GTK and `app` with the real page layout.
- `test_carry.lua` (preserve-view): carry ink on a fake document that keeps strokes, texts and pictures per
  page (add / replace / leave, tick boxes, Clear, last page, settings).
- `test_gtk_smoke.lua`: real LuaGObject, GLib timer and GTK windows with a fake `app` (keys, panels,
  buttons, saving). tool-dock's also checks the grip drag, pickers, custom buttons, small screens and the
  light / dark theme.
- `test_pixbuf.lua` (snapshot): the real crop and the see-through background.
- `show_panel.lua`, `show_dock.lua`: show the windows so you can look at them. `grab_small_screens.ps1`:
  pictures of the dock and lists on faked 1366 x 728, 1280 x 680 and 1920 x 1032 screens.

Tests use their own settings and log files in `%TEMP%`. Don't run them from Python: Python loads its own
`libffi-8.dll`, which has the same name as the one LuaGObject needs and breaks GTK calls that return a
decimal number.
