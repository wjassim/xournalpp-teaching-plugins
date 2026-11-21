# snapshot changelog

## 0.11 (2026-11-21)
- **Lit on the dock:** while snapshot waits for your drag (from the press of the button until the copy is
  made, or until you stop it) it publishes `XOPP_SNAPSHOT_ON` = 1, so tool-dock 0.8.2 lights its camera
  button, the same way it does for auto zoom.
- **Quicker feel on the press:** the page is made in advance 0.2 s after the press (was 0.06 s), so the lit
  button and the new tool are drawn before Xournal++ is held up by it. New setting `EARLY_DELAY_MS` (200).
- **Shorter hold-up:** the page picture is now 4 pixels per page point (was 6), so 3840 px wide for a
  960 pt page. Measured on a 1228-page PDF: making it takes 0.19 s instead of 0.39 s. The copies look the
  same even zoomed in; zoomed in further than that the picture grows with the zoom, as before. An old
  settings.txt keeps its own value: change `PX_PER_PT=6` to 4 there.
- **Note when a drag is not used** (see the fix below): with the floating window closed, a small note pops
  up beside the pen for 2 s: "Too quick: the page was still loading. Drag again." With the window open, its
  status line says it.
- Fix: a quick drag right after pressing the snapshot button could copy the wrong place. The page is made
  in advance when the mode starts, and that holds Xournal++ up for about 0.4 s. The pen position can't be
  read while that runs, so a drag that began in that time was first seen half way, and the copy started
  there: narrower, and beside the box you drew. Such a drag is now not used. Nothing is copied, the window
  says "too quick (the page was still loading): drag again", and the next drag works (the page is ready by
  then). New setting `LATE_MS` (100).

## 0.10 (2026-11-19)
- Fix: with a short document that fits in the view (for example zoom to fit on a one-page file), the copy
  was about 5 % too small and a little off, and the window said "copied (layout check failed, see the
  log)". The scroll area is then the view itself, not the pages, and Xournal++ centres the pages in it.
  The scale now comes from zoom x DPI / 72 in that case, and the space above the first page is counted.

## 0.9 (2026-11-18)
- Runs on the stable Xournal++ 1.3.x too (tested on 1.3.8). Without the nightly's `app.getScrollPos` the
  page area's scroll bars are read, which give the same numbers (checked: 0.000 px difference).

## 0.8
- Smooth rectangle: the page list (~8 ms for 420 pages) is read once per mode instead of every 16 ms tick.
- Quick copy: the page is exported and loaded when the mode starts (`EARLY_EXPORT=true`), so on release
  only the cut is left. The log times every step.

## 0.7
- The "is Xournal++ in front?" check (asks ~40 windows, 2 ms) is kept for 250 ms instead of running at every
  16 ms tick, so Xournal++ stays quick while the mode waits.

## 0.6
- The mode waits while another program is in front of Xournal++: a drag there copies nothing.

## 0.5
- Several background colours: a copy that holds a tinted card and the white page around it loses both
  (`BG_SHARE`, `BG_NEAR`).
- Pale leftovers go too (`FAINT_CUT`): the thin pale outline of a card, a faint tint.

## 0.4
- Transparent background (tick box in the window, on by default), "colour to alpha".
- Every copy also goes to the clipboard.

## 0.3
- When the view is zoomed in further than about 360 %, the picture follows the zoom, so it stays sharp
  (`ZOOM_HEADROOM`, `MAX_PAGE_PX`).

## 0.2 and earlier
- First versions: copy a dragged box of the page as a picture, already selected.
