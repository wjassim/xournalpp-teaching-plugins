# autozoom changelog

## 0.17 (2026-11-24)
- **Pause now stops everything:** while paused there is no zoom in, no zoom out, no edge slide and no
  follow glide, so the view stays exactly where it is. Before, the edge slide and the follow glide kept
  working (and the edge slide even worked when not zoomed in). A zoom in or out already under way when you
  press pause finishes first. Ctrl+Alt+F6 still zooms in or out by hand. The menu entry keeps its name
  ("Auto zoom: pause zoom in / out"), so the tool-dock button keeps working; the panel button is now called
  "Pause auto zoom".
- Own icon for a tool-dock button that opens the settings panel (`dock.txt` + `icons/`, needs tool-dock 0.9).

## 0.16.1 (2026-11-21)
- Fix: zoomed in, a long press that doesn't write (dragging a Select Rectangle box for a snapshot, or
  dragging a selection) didn't count as being busy. After 3 s the zoom out started and ran the moment you
  let go, so the view jumped away from the box you had just drawn. Any press on the page now holds the
  zoom; the zoom-out wait starts when you let go.

## 0.16 (2026-11-21)
- **Pause zoom in / out:** a new button in the settings panel, a new Plugin menu entry, and a button for
  tool-dock (0.8). While paused the zoom stays as it is: no zoom in and no zoom out by itself. The edge
  slide and the follow glide keep working, the edge slide also when you're not zoomed in. Ctrl+Alt+F6
  still zooms in or out. Press again and it zooms by itself again (the zoom-out wait starts fresh, so
  it doesn't jump out at once). Pausing while auto zoom is off switches it on, paused; switching it off
  ends the pause. No key at first (`KEY_PAUSE` in settings.txt). Published as `XOPP_AUTOZOOM_PAUSED` = 1 / 0
  so tool-dock can light its button.

## 0.15 (2026-11-19)
- Fix: with a short document zoomed out so far that it fits in the view (for example zoom to fit on a
  one-page file), the zoom-in did not keep the spot under the pen (40-80 px off). The scroll area is then
  the view itself, not the pages, and Xournal++ centres the pages in it. The scale now comes from
  zoom x DPI / 72 in that case, and the space above the first page is counted.

## 0.14 (2026-11-18)
- Runs on the stable Xournal++ 1.3.x too (tested on 1.3.8). The nightly's `app.getScrollPos` returns the
  visible rectangle, which is the page area's scroll bars. Without it the plugin reads the scroll bars
  itself (value = x / y, page size = width / height). Checked in the nightly: 0.000 px difference at every
  zoom, scroll and page jump, also right after `setZoom`. The nightly still uses `app.getScrollPos`.
  On stable the log says once "no app.getScrollPos ...".

## 0.13.1
- If LuaGObject is missing, the plugin tries `lgi` (Linux builds; not tested).

## 0.13
- ON / OFF is published for tool-dock (process environment `XOPP_AUTOZOOM_ON` = 1 / 0, set only when it
  changes), so the dock's "Auto zoom" button is lit while auto zoom is on.

## 0.12
- Faster. The full look at all ~40 windows of Xournal++ runs every `WIN_FULL_MS` = 2 s; every 250 ms only
  the windows that were shown are asked (usually 2 to 4); no active window found = full look at once.
  While not zoomed and not sliding, only every `IDLE_EVERY` = 2nd tick runs (32 ms; hover needs 400 ms
  anyway). The main window's GDK window is kept instead of asked every tick.

## 0.11
- Faster. Xournal++ has about 40 windows (most are hidden menus). 0.8 asked all of them at every tick
  (16 ms) whether one is active (2.2 ms), and 0.10 also asked for their frames (3.5 ms), so Xournal++ felt
  slow. Now one look at all windows is kept for `WIN_CACHE_MS` = 250 ms. The log gets one line a minute
  with the tick cost.
- The eraser no longer starts a zoom (`ERASER_ZOOMS` = false; true = as before).
- The log line of every zoom start names the tool, e.g. "IDLE -> IN (hover, tool 1)".

## 0.10
- The pen over the title bar or border of any floating window (Snapshot, this panel, a dialog) no longer
  zooms. Windows draws the title bar, so GTK finds "no window" there and 0.9 took it for the page. Now the
  outer rectangle of every shown Xournal++ window is checked too (`get_frame_extents`).
- A press that starts off the page (dragging the dock or a window, a scroll bar) stays "off the page" until
  the tip lifts, even when the pen then crosses the page.

## 0.9
- Settings panel in five groups with headings; resizable (size remembered); scroll bar on short screens;
  a saved place that is off the screen is pulled back on screen.

## 0.8
- No zoom while another program is in front of Xournal++. The check was there since 0.1 but never ran:
  `is_active` is a property in LuaGObject and was called as a method. Now the property is read on every
  window of Xournal++: the pen counts only while one of them is the active window.

## 0.7
- The pen is ignored while something of Xournal++ lies in front of the page at the pen: an open menu, a
  dialog, or another floating window (Snapshot, Page step). Before, a menu over the page counted as the
  page, and a tap on the Snapshot button counted as writing.

## 0.6
- A zoom by hand is learned as the new level only after it has rested for 0.7 s, and only when it ends at
  x 1.25 or more (`LEARN_SETTLE_MS`, `LEARN_MIN`). A hand zoom that ends lower is taken as "zoom out": the
  plugin lets go and the level stays.
- No edge slide while the hand or a selection tool is in use.

## 0.5
- Shortcut keys can be changed in `settings.txt`.
- Layout self-check.

## 0.4
- Every scroll goes to a whole pixel (a decimal scroll position blurs the page).

## 0.3
- No zoom while a selection tool or the hand is in use, or while something is selected (so dragging a
  snapshot copy does not zoom).

## 0.2
- Spring movement, follow, settings panel, learned zoom level, no pop-ups.

## 0.1 (2026-11-13)
- First version.
