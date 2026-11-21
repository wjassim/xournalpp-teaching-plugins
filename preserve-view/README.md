# preserve-view

Next / previous page without losing your place. If you're zoomed in on the top left corner of a page and go
to the next one, you land on the top left corner of the next page, at the same zoom.

I made it for slide decks where each page is one step of the same slide: going forward should look like
the next step appearing, not like the view jumping somewhere else.

![preserve-view demo](../docs/images/preserve-view.gif)

Go to the next page and stay in the same spot, at the same zoom.

It can also take your writing with you (**carry ink**, see below): what you wrote on this page shows up
on the next page at the same place, so you can keep working while the next step appears.

Version 2.8.1. Needs Xournal++ 1.3.8 or newer (stable or nightly). What changed in each version:
[CHANGELOG.md](CHANGELOG.md).

## Keys (also in the Plugin menu)

| Key | Does | Name in settings.txt |
|---|---|---|
| Ctrl+Alt+Right | next page, same view | `KEY_NEXT` |
| Ctrl+Alt+Left | previous page, same view | `KEY_PREVIOUS` |
| Ctrl+Alt+Down | nudge the view down a little | `KEY_NUDGE_DOWN` |
| Ctrl+Alt+Up | nudge the view up a little | `KEY_NUDGE_UP` |
| Ctrl+Alt+F10 | check the page step | `KEY_CHECK` |
| Ctrl+Alt+F11 | show the Page step window | `KEY_PANEL` |

To change a key: close Xournal++, open `settings.txt` in this folder and edit the `KEY_...` line, for
example `KEY_NEXT=<Control>Page_Down`, or `none` for no key.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/images/menu-preserve-view-dark.png">
  <img alt="The preserve-view entries in the Plugin menu" src="../docs/images/menu-preserve-view-light.png">
</picture>

## Page step window (Ctrl+Alt+F11)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/images/pagestep-dark.png">
  <img alt="The Page step window with Previous and Next buttons next to the page" src="../docs/images/pagestep-light.png">
</picture>

A small floating window with big **Previous** and **Next** buttons you can tap with the pen (no key
presses while you write), the page number, the **Carry ink** and **Clear** buttons, the page step check and
the carry settings (folded away until you open them). It stays above Xournal++, never takes the keyboard,
and remembers its place.

You can also add a Next / Previous button to the tool-dock with a custom button
(*Plugin > Next Page (Keep View)*).

## Carry ink

My decks build up one step per page: the next page is the same slide plus one more line. When I write on
a page and go to the next one, my writing stays behind on the old page. With carry ink on, **Next** copies
what I wrote on this page to the next page, at the same place.

- Turn it on and off with the **Carry ink** button in the Page step window (it stays lit while on), or
  *Plugin > Carry ink: on / off*. The tool-dock can have a button for it too (lit while on).
- Only going forward carries. **Previous** never changes anything.
- **Clear** (or *Plugin > Clear page ink*) wipes your writing on the current page, for when a new step
  starts on a fresh layout. One undo brings it back.
- No shortcut keys by default. If you want one, set `KEY_CARRY` / `KEY_CLEAR` in `settings.txt`.
- Strokes (pen and highlighter together), text and pictures each come back with their own undo step, so
  undoing a whole carry can take up to three presses.
- Only the ticked kinds and only the current layer are copied.
- If this page has nothing to carry, Next leaves the next page alone (even with *Replace it*).

**Carry settings** (open them in the Page step window):

- what to carry: pen, highlighter, text, pictures;
- what to do when the next page already has writing:
  - *Add only what is missing* (default): your writing on the next page stays, only what's new on this
    page is added. Handy when you go back, add a line, and go forward again. It only ever adds, never
    removes, so a few things can show up twice or come back:
    - you move or change something on this page: the next page gets the new one and keeps the old one;
    - you edit a text box here: the new text lands on top of the old one there;
    - you erase part of a stroke on the next page: the whole stroke comes back on top of the pieces;
    - you erase something on the next page: it comes back the next time you go forward.

    If you often go back and fix things, *Replace it* is the cleaner choice.
  - *Replace it*: the next page gets an exact copy of this page's writing. Writing you added there goes
    (only the ticked kinds). Undo takes a few presses: one for each kind copied, then one for the
    delete. If the delete ever fails, it adds only what is missing instead, so nothing is doubled.
  - *Leave it*: nothing happens on that page.
- whether carry ink is on when Xournal++ starts.

Nothing runs while you write. The copy happens once per **Next**, and takes a few milliseconds.

## Check Page Step

The plugin works out exactly how far one page is from Xournal++'s page layout. After a Xournal++ update,
open a PDF with a few pages and choose *Plugin > preserve-view > Check Page Step* (or Ctrl+Alt+F10).
"Check OK." means everything's fine. You won't need it otherwise.

## Settings (`settings.txt` in this folder)

The plugin writes this file itself. Change it with Xournal++ closed.

| Setting | Default | What it means |
|---|---|---|
| `NUDGE_PX` | 5 | how far one nudge moves the view (screen pixels) |
| `PANEL_AT_START` | false | open the Page step window when Xournal++ starts |
| `PANEL_X`, `PANEL_Y` | -1 | window place (saved by itself) |
| `KEY_...` | see above | shortcut keys |
| `KEY_CARRY`, `KEY_CLEAR` | none | keys for carry ink on / off and clear page ink |
| `CARRY_AT_START` | false | carry ink is on when Xournal++ starts |
| `CARRY_PEN`, `CARRY_HIGHLIGHTER`, `CARRY_TEXT`, `CARRY_PICTURES` | true | what Next carries |
| `CARRY_EXISTING` | add | next page already has writing: `add`, `replace` or `leave` |

The carry settings are easier to change in the Page step window; the file is written for you.

## Good to know

- If something looks wrong, the log is in `%TEMP%\preserve-view.log`.
- Pages of different heights work too.
- On the last page, a view far down the page can land a little short, because Xournal++ won't scroll past
  the end of the document. Going back still returns to the right place.
- It expects one page per row (the normal layout), not pages side by side.
