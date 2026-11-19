# preserve-view changelog

## 2.7 (2026-11-18)
- Runs on the stable Xournal++ 1.3.x too (tested on 1.3.8). The nightly's `app.getScrollPos` is used when
  present; without it the page area's scroll bars give the same numbers.

## 2.6.1
- If LuaGObject is missing, the plugin tries `lgi` (Linux builds; not tested).

## 2.6
- The Page step window reads the page list only after a click, a scroll, or every 3 s (it was every
  300 ms, which costs about 8 ms on a big document).

## 2.4
- Floating window "Page step": big Previous / Next buttons for the pen, the page number and the page step
  check.

## 2.1 - 2.3
- The page step is computed from Xournal++'s page layout instead of measured, so every hop is exact and
  the first hop at a new zoom is quick. The decimal part of each hop is carried into the next one, so the
  view stays within one pixel of the true place however many hops.
- The zoom scale is read from the scroll area (screen DPI / 72 pixels per point at 100 %).

## 2.0
- The page step was measured with jumps to the end of the document.
