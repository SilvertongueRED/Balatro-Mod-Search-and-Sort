# Balatro Mod Search and Sort

Search, filter and sort your Balatro Mods Menu — without messing up the load order!

## Features

- **Live search** — type in the **Search** box next to the page selector (bottom of the Mods menu) and the list narrows as you type. It matches the mod's name, id, folder name and author. Type several words and every word has to match. Press **Clear** to empty the box. (Click the box, or press **S** on the keyboard / **R3** (press the right stick) on a controller, to start typing; Esc leaves the box. **Hold** S / R3 for about half a second to clear the search instead. The hints are shown next to the page selector.)
- **Show filter** — **Showing:** tells you what is listed, and the **Next:** button beside it cycles **All Mods → Enabled → Disabled**. It always starts on All Mods when you open the menu.
- **Sort** — click the **Next:** button to cycle between sort modes. The **Now:** label shows the current one (it is remembered between sessions):
  - **A to Z** — alphabetical by display name (default)
  - **Last Updated** — most recently modified mod files first
  - **Config Changed** — most recently changed mod config files first
- **Restart prompt** — after you switch a mod on or off, leaving the Mods menu (Back / Esc / B) asks what to do instead of instantly restarting:
  - **Restart now** — closes Balatro and starts it again by itself (Windows: a small hidden helper waits for the game to exit, force-closes it if it hangs, then relaunches the game and checks that it really started: through Steam normally, or by starting the game directly when Steam is still holding its "game running" flag, which can last over a minute after a launch. The helper is started through the Windows Task Scheduler so Steam doesn't think the game is still running; it writes `bms_close_helper.log` in Balatro's save folder)
  - **Later (close game)** — closes the game (force-closing it if it hangs); start it again whenever you like
  - **Go back** (or Esc / B) — returns to the Mods menu

- **Controller shoulders** — in the Mods menu **LB / RB** turn the mod pages (glyphs shown beside the page selector) and **LT / RT** switch the top tabs Mods / Credits / Config (glyphs shown beside the tab strip), the same way Balatro Mod Updater does it.

The page selector (Page x/y) follows whatever the search / filter / sort currently shows.

## Installation

Requires [Steamodded](https://github.com/Steamopollys/Steamodded) 1.x.

Drop the `Balatro-Mod-Search-and-Sort` folder into your Balatro `Mods` directory (requires Steamodded and Lovely).

## Changelog

### 2.2.1
- Fixed: with a controller, pressing the Showing / Next filter button (for example into Disabled, when nothing matches) no longer drops the controller focus off the button.
- Holding **S** (keyboard) or **R3** (controller) now clears the search; a quick tap still jumps to the search box.
- New mod icon.

### 2.2.0
- Renamed to **Balatro Mod Search and Sort**.
- New live search box in the Mods menu (name / id / folder / author, all words must match) with a Clear button and a "Found: x/y" counter.
- New **Showing / Next** filter button: All Mods → Enabled → Disabled.
- New **Restart now / Later (close game) / Go back** prompt when leaving the Mods menu after toggling mods. Restart relaunches the game itself through a small Windows helper (Steamodded's built-in restart only closed the game for some setups).
- Sorting now returns to page 1 and keeps the page selector in sync.
- The list keeps its position when a search or filter leaves only a few mods.
- Controller / keyboard: D-pad or stick Left/Right now moves straight between the two **Next:** buttons (sort and filter) instead of dropping to the mods below.
- Controller: when a search / filter leaves only a few mods, D-pad / stick Up and Down now walk row by row (no more jumping over mods), and if the list is ever pushed out of place it is put back automatically.
- Restart now no longer waits for Steam's slow "game running" flag: if it is still set a few seconds after the game closes, the game is started directly.
- New hotkey: **S** (keyboard) or **R3** (controller) jumps to the search box from anywhere in the Mods menu; a hint is shown beside the page selector.
- Controller: **LB / RB** now turn the mod list pages and **LT / RT** switch the top tabs (Mods / Credits / Config); the matching glyphs are shown next to the page selector and the tab strip.
- Holding **S** (keyboard) or **R3** (controller) clears the search; a second hint line next to the page selector says so. A quick tap still jumps to the search box.
- Fixed: after a search, pressing **Clear** with a controller could push the mod list down and to the right; the menu now notices this and re-lays itself out immediately.
- A small `bms_layout.log` is written in the save folder only if the list layout does something unexpected.

### 2.1.0
- The sort button now shows the NEXT sort mode ("Next: ..."), and a separate "Now: ..." label shows the CURRENT sort.
