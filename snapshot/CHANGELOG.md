# snapshot changelog

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
