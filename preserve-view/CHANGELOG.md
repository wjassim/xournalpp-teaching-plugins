# preserve-view changelog

## 2.8.1 (2026-11-20)
- Fix: carried ink did not show on the next page. Xournal++ kept it in the page but did not draw it until
  the page was redrawn; the plugin now asks for the redraw (`app.refreshPage`) after a carry.
- Page step window: the page number now comes from the scroll position (the page under the middle of the
  view, which is Xournal++'s own current page). The page list is read only every 30 s or after a zoom
  change. On a 1228-page document that read takes about 21 ms, and the window used to do it 3 times a
  second while scrolling and every 3 s when still: small pauses gone (longest window check now about 3 ms).
- Carry ink, *Replace it*: if the delete on the next page fails, only what is missing is added, so the
  writing is not doubled. README explains undo after a replace and when *Add only what is missing* can
  bring things back twice.

## 2.8 (2026-11-20)
- Carry ink: with it on, Next copies your writing (pen, highlighter, text, pictures) on this page to the
  next page at the same place. Previous never carries. On / off with the Carry ink button in the Page step
  window (lit while on), the Plugin menu, or the tool-dock (0.7.5).
- Clear page ink: wipes the writing on the current page in one undo step.
- Carry settings in the Page step window, folded away until opened: what to carry, and what to do when the
  next page already has writing (add only what is missing / replace / leave).
- New settings: `CARRY_AT_START`, `CARRY_PEN`, `CARRY_HIGHLIGHTER`, `CARRY_TEXT`, `CARRY_PICTURES`,
  `CARRY_EXISTING`, `KEY_CARRY`, `KEY_CLEAR` (no keys by default).
- New test: `tests/test_carry.lua`.

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
