# Balatro Mod Search and Sort

Search, filter and sort your Balatro Mods Menu — without messing up the load order!

## Features

- **Live search** — type in the **Search** box next to the page selector (bottom of the Mods menu) and the list narrows as you type. It matches the mod's name, id, folder name and author. Type several words and every word has to match. Press **Clear** to empty the box. (Click the box, or press **S** on the keyboard / **R3** (press the right stick) on a controller, to start typing; Esc leaves the box. **Hold** S / R3 for about half a second to clear the search instead. The hints are shown next to the page selector.)
- **Show filter** — **Showing:** tells you what is listed, and the **Next:** button beside it cycles **All Mods → Enabled → Disabled**. It always starts on All Mods when you open the menu.
- **Sort** — click the **Next:** button to cycle between sort modes. The **Now:** label shows the current one (it is remembered between sessions):
  - **A to Z** — alphabetical by display name (default)
  - **Last Updated** — most recently modified mod files first
  - **Config Changed**: mods whose settings you changed most recently first. The mod remembers a fingerprint of every mod's settings and notes when one changes (saved in `config/BalatroModSort_cfgtimes.txt`), so changes are picked up the next time the Mods menu is opened. Mods you have not changed since 2.2.3 or newer was installed stay in A to Z order below the changed ones.
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

### 2.2.6
- Fixed: the Mods list sometimes stayed blank for a few seconds when the menu opened (or until you changed page). Steamodded fills the list from an event in the game's main queue, and with many mods that queue can be backed up. The list is now filled on the first frame the menu is up.

### 2.2.5
- Fixed: a crash (`attempt to index field 'OVERLAY_MENU' (a nil value)`, in Steamodded's `src/ui.lua`) when the Mods menu was closed while its list was still being updated, seen during a boss blind. The list update now does nothing when the menu is no longer open.
- New mod icon (it was only in the repository after 2.2.4, now it is in the release package too).

### 2.2.4
- Fixed: **Config Changed** now also notices mods that keep their settings outside Steamodded's config, such as **Trance** (it stores them in its own `config/Trance.lua` and a global `Trance_config`, and only writes the file when the Options menu opens). Changing a Trance colour or font now puts Trance at the top the next time you open the Mods menu. Opening a mod's Options menu without changing anything no longer counts as a change.
- Trance (and any mod with its own file in the config folder) starts from that file's last saved time instead of "never".

### 2.2.3
- Fixed: **Config Changed** sorting did nothing and looked like A to Z. It used the modification time of each mod's config file, but Steamodded rewrites every mod's config file whenever the Mods menu is closed, so all of them had the same time. It now tracks when a mod's settings actually change (Trance, Mod Updater and any other mod with settings) and sorts newest change first.
- The first time 2.2.3 runs it only records a starting point for every mod, so nothing is "changed" yet; change a setting in any mod and it moves to the top the next time you open the Mods menu.

### 2.2.2
- Fixed: holding **S** on the keyboard now clears the search, also while the cursor is still in the search box (S used to just type an "s").
- Fixed: with a controller, leaving the search box with **B** could leave the on-screen keyboard behind, after which the keyboard and controller stopped responding while the mouse still worked. A leftover keyboard is now closed automatically.

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
