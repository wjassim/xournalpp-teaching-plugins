# tool-dock changelog

## 0.7.4 (2026-11-19)
- Text and one-colour icons (F7, +, zoom, magnifier, camera, the size dot) no longer turn grey. The dock
  never takes the keyboard, so after a click GTK draws it as a window in the background (`:backdrop`)
  while Xournal++'s own colour icons stay white. Dock buttons now keep the theme's normal text colour
  (`@theme_fg_color`; a theme without that name loads the rest without it).

## 0.7.3
- The edit list changes its height only (a wider window only showed empty space); its width is the
  content's width (`EDIT_H` kept, `EDIT_W` gone).
- If LuaGObject is missing, the plugin tries `lgi` (many Linux builds; not tested).
- Checked on the stable Xournal++ 1.3.8.

## 0.7.2
- The edit list can be resized and keeps that size. Dragged to another monitor it takes that screen's
  height limit.
- The custom button list opens right of the edit list, or left of it when there is no room, or at the
  screen's right edge.
- A Wayland display is noted in the log.

## 0.7.1
- The custom button list leaves out the entries a tick box already gives (pen, shapes, select, undo, zoom
  in / out, auto zoom ...). The tick box ones work better: a shape switches to the pen first, Pen turns
  shape modes off.

## 0.7
- Custom buttons: pick any menu entry that has a shortcut (or any Plugin menu entry) and the dock gets a
  button that runs it.
- The 0.6 per-button shortcut keys are gone (too many keys). Old `KEY_<button>` lines in `settings.txt`
  are ignored and dropped.

## 0.6
- Shortcut keys for dock buttons, colours and the 5 thicknesses.
- "Auto zoom on / off" button: presses the autozoom plugin's own menu entry, lit while auto zoom is on
  (needs autozoom 0.13).

## 0.5
- Shapes fixed. In Xournal++ 1.3 rectangle, ellipse, arrow, double arrow, axes, spline, ruler and shape
  recognizer are drawing modes of the pen / highlighter, not tools. A shape button now switches to the pen
  (when the tool is not the pen or highlighter) and turns its mode on; pressed again = freehand. The button
  is lit while its mode is on. Pen and Highlighter buttons always give freehand.

## 0.4
- Faster: the buttons are asked only when a press starts on the dock; a press on the page (writing) is
  left alone until it lifts.
- New tools: axes, double arrow, select rectangle / region on all layers, link.
- New command buttons: zoom in, zoom out, zoom to fit, zoom 100 %, undo, redo, and on / off helpers lit
  while on: ruler, shape recognizer, grid snapping, rotation snapping, set square, compass; new page.

## 0.3
- The thickness button and picker use Xournal++'s own thickness icons (they follow the light / dark theme).
- A tool without a size (select, hand, text ...) gets the pen's size.
- Faster: one tick 2.6 ms before, 0.18 ms now.
- Light and dark theme: the border, grip and colour outlines use the theme's text colour.

## 0.2
- Grip instead of the Windows title bar; line thickness button with a 5-size picker.

## 0.1 (2026-11-17)
- Tool and colour buttons, edit list, three shapes, three button sizes.
