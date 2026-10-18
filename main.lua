--- STEAMODDED HEADER
--- MOD_NAME: Balatro Mod Search and Sort
--- MOD_ID: BalatroModSort
--- MOD_AUTHOR: [SilvertongueRED, ChatGPT, Claude]
--- MOD_DESCRIPTION: Search and sort your Mods menu as you type, with a restart prompt after toggling mods — without changing load order.
--- PRIORITY: 1000000000
--- BADGE_COLOUR: 5A2D82
--- BADGE_TEXT_COLOUR: FFFFFF
--- DISPLAY_NAME: Balatro Mod Search and Sort
--- VERSION: 2.2.0
--- PREFIX: bms

-- Balatro Mod Search and Sort (display-only)
-- This mod patches Steamodded's Mods menu builder so the list can be searched
-- (live, as you type) and sorted by multiple criteria without changing the
-- underlying load order (priority-based). It also replaces the instant
-- "restart" that happens when you leave the Mods menu after toggling a mod
-- with a "Restart now / Later (close game)" prompt.
--
-- Sort modes:
--   A→Z             – alphabetical by display name (default)
--   Recently Updated – by mod file modification time (newest first)
--   Config Changed   – by config file modification time (newest first)

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function _safe_lower(s)
  s = tostring(s or "")
  return string.lower(s)
end

-- modicon info
SMODS.Atlas {
  key = 'modicon',
  path = 'modicon.png',
  px = 64,
  py = 64,
  inject = function(self)
    self.full_path = (self.mod and self.mod.path or SMODS.path) .. self.path
    local file_data = assert(SMODS.NFS.newFileData(self.full_path),
      ('Failed to collect file data for Atlas %s'):format(self.key))
    self.image_data = assert(love.image.newImageData(file_data),
      ('Failed to initialize image data for Atlas %s'):format(self.key))
    self.image = love.graphics.newImage(self.image_data,
      { mipmaps = true, dpiscale = 1 })
    G[self.atlas_table][self.key_noloc or self.key] = self
  end,
}

local function _display_name(mod)
  -- Prefer localized name if available, else mod.name, else mod.id
  local name = mod and (mod.name or mod.id) or ""
  if type(localize) == "function" and mod and mod.id and G and G.localization and G.localization.descriptions
     and (G.localization.descriptions.Mod or {})[mod.id] then
    local ok, loc = pcall(function()
      return localize({ type = "name_text", set = "Mod", key = mod.id })
    end)
    if ok and type(loc) == "string" and loc ~= "ERROR" and loc ~= "" then
      name = loc
    end
  end
  return name
end

-- Retrieve a named upvalue from a Lua function, returns nil on any failure.
local function _try_get_upvalue(func, name)
  if not debug or type(debug.getupvalue) ~= "function" then return nil end
  local i = 1
  while true do
    local n, v = debug.getupvalue(func, i)
    if n == nil then break end
    if n == name then return v end
    i = i + 1
  end
  return nil
end

----------------------------------------------------------------------
-- Sort modes
----------------------------------------------------------------------

local SORT_MODES  = { "alpha", "updated", "config" }
local SORT_LABELS = {
  alpha   = "A to Z",
  updated = "Last Updated",
  config  = "Config Changed",
}

local _current_sort = "alpha"

local _SORT_SAVE_PATH = "config/BalatroModSort_sort.txt"

local function _save_sort_mode()
  pcall(function()
    if love and love.filesystem and type(love.filesystem.write) == "function" then
      love.filesystem.write(_SORT_SAVE_PATH, _current_sort)
    end
  end)
end

local function _load_sort_mode()
  pcall(function()
    if love and love.filesystem and type(love.filesystem.read) == "function" then
      local ok, data = pcall(love.filesystem.read, _SORT_SAVE_PATH)
      if ok and type(data) == "string" then
        data = data:match("^%s*(.-)%s*$") -- trim whitespace
        for _, m in ipairs(SORT_MODES) do
          if m == data then
            _current_sort = data
            return
          end
        end
      end
    end
  end)
end

_load_sort_mode()

local function _next_sort_mode()
  for i, m in ipairs(SORT_MODES) do
    if m == _current_sort then
      _current_sort = SORT_MODES[(i % #SORT_MODES) + 1]
      _save_sort_mode()
      return
    end
  end
  _current_sort = SORT_MODES[1]
  _save_sort_mode()
end

----------------------------------------------------------------------
-- File-time helpers
----------------------------------------------------------------------

-- Return the modification time (epoch seconds) of a file, or 0.
local function _file_modtime(path)
  if not path or path == "" then return 0 end
  -- NativeFS (bundled with Steamodded) — works with real filesystem paths.
  if NFS and type(NFS.getInfo) == "function" then
    local ok, info = pcall(NFS.getInfo, path)
    if ok and type(info) == "table" and info.modtime then return info.modtime end
  end
  -- love.filesystem — works inside the save / fused directory.
  if love and love.filesystem and type(love.filesystem.getInfo) == "function" then
    local ok, info = pcall(love.filesystem.getInfo, path)
    if ok and type(info) == "table" and info.modtime then return info.modtime end
  end
  return 0
end

-- Most-recent modification time of a mod's own files.
local function _mod_update_time(mod)
  if not mod or not mod.path then return 0 end
  -- Try the main source file first.
  local t = _file_modtime(mod.path .. "/" .. (mod.main_file or "main.lua"))
  if t > 0 then return t end
  -- Fall back to the mod directory itself.
  return _file_modtime(mod.path)
end

-- Most-recent modification time of a mod's saved config file.
local function _config_change_time(mod)
  if not mod or not mod.id then return 0 end
  -- Only meaningful for mods that expose configuration.
  if not (mod.config_tab or mod.config) then return 0 end
  -- Steamodded stores per-mod config under the save directory.
  local save = ""
  if love and love.filesystem and type(love.filesystem.getSaveDirectory) == "function" then
    save = love.filesystem.getSaveDirectory()
  end
  local candidates = {}
  if save ~= "" then
    table.insert(candidates, save .. "/config/" .. mod.id .. ".jkr")
  end
  table.insert(candidates, "config/" .. mod.id .. ".jkr")
  for _, p in ipairs(candidates) do
    local t = _file_modtime(p)
    if t > 0 then return t end
  end
  return 0
end

----------------------------------------------------------------------
-- Sorting
----------------------------------------------------------------------

-- File timestamps don't change while the Mods menu is open, so they are cached
-- per sort mode (cleared every time the menu is built) - searching re-sorts on
-- every keystroke and must not hit the filesystem each time.
local _ts_cache = { updated = {}, config = {} }

local function _sorted_copy(mod_list)
  local t = {}
  for i, v in ipairs(mod_list or {}) do t[i] = v end

  if _current_sort == "updated" then
    local cache = _ts_cache.updated
    for _, m in ipairs(t) do
      if cache[m] == nil then cache[m] = _mod_update_time(m) end
    end
    table.sort(t, function(a, b)
      local ta, tb = cache[a] or 0, cache[b] or 0
      if ta ~= tb then return ta > tb end  -- newest first
      local na, nb = _safe_lower(_display_name(a)), _safe_lower(_display_name(b))
      if na ~= nb then return na < nb end
      return tostring(a.id or "") < tostring(b.id or "")
    end)

  elseif _current_sort == "config" then
    local cache = _ts_cache.config
    for _, m in ipairs(t) do
      if cache[m] == nil then cache[m] = _config_change_time(m) end
    end
    table.sort(t, function(a, b)
      local ta, tb = cache[a] or 0, cache[b] or 0
      if ta ~= tb then return ta > tb end  -- newest first
      local na, nb = _safe_lower(_display_name(a)), _safe_lower(_display_name(b))
      if na ~= nb then return na < nb end
      return tostring(a.id or "") < tostring(b.id or "")
    end)

  else -- "alpha" (default)
    table.sort(t, function(a, b)
      local na, nb = _safe_lower(_display_name(a)), _safe_lower(_display_name(b))
      if na ~= nb then return na < nb end
      return tostring(a.id or "") < tostring(b.id or "")
    end)
  end

  return t
end

----------------------------------------------------------------------
-- Pagination constants matching Steamodded's defaults (src/ui.lua ~line 1959).
----------------------------------------------------------------------

local MODS_ROWS_PER_PAGE = 4
local MODS_COLS_PER_ROW  = 3
-- Scale at which each mod box is rendered (Steamodded passes 0.75 * 0.5).
local MOD_BOX_SCALE      = 0.375

-- Inlined pagination logic from Steamodded's recalculateModsList (src/ui.lua ~line 1959).
-- Returns: nil, nil, showingList, startIndex, endIndex, modsRowPerPage, modsColPerRow
local function _inline_recalc(page, total)
  page = page or 1
  local startIndex = (page - 1) * MODS_ROWS_PER_PAGE * MODS_COLS_PER_ROW + 1
  local endIndex   = startIndex + MODS_ROWS_PER_PAGE * MODS_COLS_PER_ROW - 1
  local showingList = total > 0
  return nil, nil, showingList, startIndex, endIndex, MODS_ROWS_PER_PAGE, MODS_COLS_PER_ROW
end

----------------------------------------------------------------------
-- Search (filters the list live while you type)
----------------------------------------------------------------------

local SEARCH_MAX_LEN = 20

-- ref_table for the text input: the input writes the typed text to _search.text
-- on every key press.
local _search = { text = "" }
local _applied_query = ""     -- (normalised) query the list is currently showing
local _pager_args = nil       -- Steamodded's page-selector table, found when the menu is built
local _refresh_pending = false

-- Which mods to show: everything, only enabled, or only disabled.
-- "Enabled" follows the checkbox in the list (so a mod you just ticked off counts
-- as disabled right away, even though the game only applies it after a restart).
-- Not saved: it always starts on "All" when the Mods menu is opened, so mods can
-- never look like they have gone missing.
local FILTER_MODES  = { "all", "enabled", "disabled" }
local FILTER_LABELS = { all = "All Mods", enabled = "Enabled", disabled = "Disabled" }
local _filter_mode = "all"

local function _mod_is_enabled(mod)
  if mod.should_enable ~= nil then return mod.should_enable and true or false end
  return not mod.disabled
end

local function _next_filter_mode()
  for i, m in ipairs(FILTER_MODES) do
    if m == _filter_mode then
      _filter_mode = FILTER_MODES[(i % #FILTER_MODES) + 1]
      return
    end
  end
  _filter_mode = FILTER_MODES[1]
end

local function _peek_next_filter()
  for i, m in ipairs(FILTER_MODES) do
    if m == _filter_mode then return FILTER_MODES[(i % #FILTER_MODES) + 1] end
  end
  return FILTER_MODES[1]
end

local function _normalise_query(text)
  local words = {}
  for w in string.gmatch(_safe_lower(text), "%S+") do words[#words + 1] = w end
  return words, table.concat(words, " ")
end

-- Everything a mod can be found by: display name, name, id, folder and author(s).
local function _mod_haystack(mod)
  local parts = {}
  local function add(v)
    if type(v) == "string" then
      if v ~= "" then parts[#parts + 1] = v end
    elseif type(v) == "table" then
      for _, x in ipairs(v) do add(x) end
    end
  end
  add(_display_name(mod))
  add(mod.name)
  add(mod.display_name)
  add(mod.id)
  add(mod.author)
  if type(mod.path) == "string" then add(mod.path:match("([^/\\]+)[/\\]*$")) end
  return _safe_lower(table.concat(parts, " "))
end

-- The mods the list should show right now: sorted, then narrowed by the
-- Enabled/Disabled filter and the search.
-- Every word typed has to appear somewhere in the mod's name / id / folder / author.
-- Returns: list, is_narrowed (a search or an Enabled/Disabled filter is active), total
local function _visible_mods()
  local sorted = _sorted_copy(SMODS.mod_list)
  local total = #sorted
  local words = _normalise_query(_search.text)
  if #words == 0 and _filter_mode == "all" then return sorted, false, total end
  local out = {}
  for _, m in ipairs(sorted) do
    local pass = true
    if _filter_mode == "enabled" then pass = _mod_is_enabled(m)
    elseif _filter_mode == "disabled" then pass = not _mod_is_enabled(m) end
    local hay = pass and #words > 0 and _mod_haystack(m) or ""
    local all = pass
    if all then
      for _, w in ipairs(words) do
        if not string.find(hay, w, 1, true) then
          all = false
          break
        end
      end
    end
    if all then out[#out + 1] = m end
  end
  return out, true, total
end

local function _page_count(n)
  return math.max(1, math.ceil(n / (MODS_ROWS_PER_PAGE * MODS_COLS_PER_ROW)))
end

-- Steamodded's "Page x/y" selector is built once from the full mod count. When the
-- search narrows the list, rewrite its options in place (the arrows and the label
-- read the same table every time they are used).
local function _sync_pager(total_mods, page)
  local a = _pager_args
  if type(a) ~= "table" then return end
  local pages = _page_count(total_mods)
  page = math.max(1, math.min(tonumber(page) or 1, pages))
  local label = (type(localize) == "function" and localize("k_page")) or "Page"
  local opts = {}
  for i = 1, pages do opts[i] = label .. " " .. i .. "/" .. pages end
  a.options = opts
  a.current_option = page
  a.current_option_val = opts[page]
end

local function _reset_search_state()
  _search.text = ""
  _applied_query = ""
  _filter_mode = "all"
  _pager_args = nil
  _refresh_pending = false
  _ts_cache = { updated = {}, config = {} }
end

----------------------------------------------------------------------
-- UI helpers
----------------------------------------------------------------------

-- Try to locate createClickableModBox: first by upvalue name, then by probing all
-- function-type upvalues of old_fn.  Returns nil when the debug library is absent
-- or no matching candidate is found.
local function _find_create_box(old_fn)
  if not debug or type(debug.getupvalue) ~= "function" then return nil end

  -- Try the known upvalue name first.
  local cb = _try_get_upvalue(old_fn, "createClickableModBox")
  if cb then return cb end

  -- Iterate every upvalue and test function-type candidates.
  -- createClickableModBox(modInfo, scale) returns a {n = G.UIT.C, ...} table.
  if not (G and G.UIT and SMODS and SMODS.mod_list and SMODS.mod_list[1]) then
    return nil
  end
  local i = 1
  while true do
    local n, v = debug.getupvalue(old_fn, i)
    if n == nil then break end
    if type(v) == "function" then
      -- Save and restore SMODS.LAST_VIEWED_MODS_PAGE around the probe call,
      -- because calling recalculateModsList (another upvalue) with a non-number
      -- argument would corrupt this global and cause a crash later.
      local saved_page = SMODS.LAST_VIEWED_MODS_PAGE
      local ok, result = pcall(v, SMODS.mod_list[1], MOD_BOX_SCALE)
      SMODS.LAST_VIEWED_MODS_PAGE = saved_page
      if ok and type(result) == "table" and result.n == G.UIT.C then
        return v
      end
    end
    i = i + 1
  end
  return nil
end

-- Build the shared single-pass mod-grid body used when create_box is available.
-- Uses column-major ordering so that reading top-to-bottom per column gives
-- sorted order (matching the original Steamodded layout direction).
local function _build_grid(sorted, startIndex, endIndex, modsRowPerPage, modsColPerRow, create_box)
  -- Collect the page's mods into a flat list.
  local page_mods = {}
  local id = 0
  for _, modInfo in ipairs(sorted) do
    id = id + 1
    if id >= startIndex and id <= endIndex then
      table.insert(page_mods, modInfo)
    end
    if id >= endIndex then break end
  end

  -- Place mods into a 2-D grid using column-major order.
  local grid = {}
  for r = 1, modsRowPerPage do grid[r] = {} end
  for i, modInfo in ipairs(page_mods) do
    local col = math.floor((i - 1) / modsRowPerPage) + 1
    local row = ((i - 1) % modsRowPerPage) + 1
    grid[row][col] = create_box(modInfo, MOD_BOX_SCALE)
  end

  -- Convert grid rows into UI row nodes.
  local modNodes = {}
  for r = 1, modsRowPerPage do
    if grid[r][1] then
      table.insert(modNodes, {
        n = G.UIT.R,
        config = { padding = 0, align = "lc" },
        nodes = grid[r]
      })
    end
  end
  return modNodes
end

----------------------------------------------------------------------
-- Sort-mode button (appears at the top of the mod list)
----------------------------------------------------------------------

local function _peek_next_sort()
  for i, m in ipairs(SORT_MODES) do
    if m == _current_sort then
      return SORT_MODES[(i % #SORT_MODES) + 1]
    end
  end
  return SORT_MODES[1]
end

-- Top row of the list. Two groups, each "Now: <current>" (info) + "Next: <next>"
-- (the button - click / press A to switch to that option):
--   Sort : [ Now: A to Z    ] [ Next: Last Updated ]
--   Show : [ Showing: All   ] [ Next: Enabled      ]      [ Found: x/y ]  (only while narrowed)
-- ids of the two buttons (controller navigation / focus below)
local BTN_SORT_ID, BTN_FILTER_ID = "bms_sort_btn", "bms_filter_btn"

local function _sort_button_row(found, total)
  local btn_colour    = HEX and HEX("5A2D82") or {0.35, 0.18, 0.51, 1}
  local filter_colour = HEX and HEX("2F5D8A") or {0.18, 0.36, 0.54, 1}
  local pill_colour   = HEX and HEX("2B2B35") or {0.17, 0.17, 0.21, 1}
  local dim_text      = HEX and HEX("A9A9B8") or {0.66, 0.66, 0.72, 1}
  local scale = 0.27
  local cur  = SORT_LABELS[_current_sort] or SORT_LABELS.alpha
  local nxt  = SORT_LABELS[_peek_next_sort()] or SORT_LABELS.alpha
  local show_cur = FILTER_LABELS[_filter_mode] or FILTER_LABELS.all
  local show_nxt = FILTER_LABELS[_peek_next_filter()] or FILTER_LABELS.all

  local function pill(label, value, minw)
    return {
      n = G.UIT.C,
      config = { align = "cm", padding = 0.07, r = 0.1, minw = minw, minh = 0.36, colour = pill_colour },
      nodes = {
        { n = G.UIT.T, config = { text = label, scale = scale, colour = dim_text } },
        { n = G.UIT.T, config = { text = value, scale = scale, colour = G.C.WHITE, shadow = true } },
      }
    }
  end
  local function button(text, func, colour, minw, id)
    return {
      n = G.UIT.C,
      config = { align = "cm", padding = 0.07, r = 0.1, minw = minw, minh = 0.36,
                 colour = colour, hover = true, shadow = true, button = func, id = id },
      nodes = {
        { n = G.UIT.T, config = { text = text, scale = scale, colour = G.C.WHITE, shadow = true } },
      }
    }
  end
  local function gap(w) return { n = G.UIT.C, config = { minw = w }, nodes = {} } end

  return {
    n = G.UIT.R,
    config = { padding = 0.05, align = "cm" },
    nodes = {
      pill("Now: ", cur, 2.4),
      gap(0.12),
      button("Next: " .. nxt, "bms_cycle_sort", btn_colour, 2.4, BTN_SORT_ID),
      gap(0.4),
      pill("Showing: ", show_cur, 2.4),
      gap(0.12),
      button("Next: " .. show_nxt, "bms_cycle_filter", filter_colour, 2.2, BTN_FILTER_ID),
      found and gap(0.4) or nil,
      found and pill("Found: ", tostring(found) .. "/" .. tostring(total or found), 1.7) or nil,
    }
  }
end

----------------------------------------------------------------------
-- Refresh the mods list UI (after a sort / search / filter change)
----------------------------------------------------------------------

local function _refresh_mods_list(page)
  page = tonumber(page) or SMODS.LAST_VIEWED_MODS_PAGE or 1
  SMODS.LAST_VIEWED_MODS_PAGE = page
  -- Use Steamodded's own DynamicUIManager when available; otherwise replicate
  -- the exact same UIBox config that updateDynamicAreas uses.
  pcall(function()
    if SMODS.GUI.DynamicUIManager and type(SMODS.GUI.DynamicUIManager.updateDynamicAreas) == "function" then
      SMODS.GUI.DynamicUIManager.updateDynamicAreas({
        ["modsList"] = SMODS.GUI.dynamicModListContent(page)
      })
    elseif G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID then
      local area = G.OVERLAY_MENU:get_UIE_by_ID("modsList")
      if not (area and area.config and area.config.object) then return end
      area.config.object:remove()
      area.config.object = UIBox{
        definition = SMODS.GUI.dynamicModListContent(page),
        config = { offset = { x = 0, y = 0.5 }, align = "cm", parent = area }
      }
    end
  end)
end

-- Small diagnostic log (bms_layout.log in the save folder): only written when the
-- list layout does something unexpected, at most 80 lines per game start.
local _diag_lines = 0
local function _diag(msg)
  if _diag_lines >= 80 then return end
  _diag_lines = _diag_lines + 1
  pcall(function()
    if love and love.filesystem and love.filesystem.append then
      local t = (G and G.TIMERS and G.TIMERS.REAL) or 0
      love.filesystem.append("bms_layout.log", string.format("%.2f %s\n", t, msg))
    end
  end)
end

-- Safety net: a freshly built list always has its ROOT exactly on the box. If
-- something outside this mod (seen once with a controller) lays the list out a
-- second time, the ROOT ends up displaced (the whole list sits too far down and
-- right). Notice that and rebuild the list, which always lays out correctly.
local _heal_pending = false
local _last_heal = 0

-- The list's area node must stay 0 x 0 with no_role (see _inject_search_ui). If
-- something resets that, the whole page lays out wrongly; put it back.
local function _area_config_broken()
  local area = G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID and G.OVERLAY_MENU:get_UIE_by_ID("modsList")
  local c = area and area.config
  if not c or not G.OVERLAY_MENU:get_UIE_by_ID("bms_search_row") then return false end
  return c.w ~= 0 or c.h ~= 0 or not c.no_role
end

local function _list_displaced()
  if not (G and G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID) then return false end
  local area = G.OVERLAY_MENU:get_UIE_by_ID("modsList")
  local box = area and area.config and area.config.object
  if not (box and box._bms_list and box.T and box.UIRoot and box.UIRoot.T) then return false end
  return math.abs(box.UIRoot.T.x - box.T.x) > 0.1 or math.abs(box.UIRoot.T.y - box.T.y) > 0.1
end

-- One-line dump of the Mods page layout (used by the diagnostic log).
local function _layout_snapshot(tag)
  pcall(function()
    local ov = G.OVERLAY_MENU
    if not (ov and ov.get_UIE_by_ID) then return end
    local tc = ov:get_UIE_by_ID("tab_contents")
    local obj = tc and tc.config and tc.config.object
    local parts = {}
    local function walk(n, depth)
      if depth > 4 or #parts > 40 or not (n and n.T) then return end
      local c = n.config or {}
      parts[#parts + 1] = string.format("%s%s:%.1f,%.1f,%.1fx%.1f", string.rep(">", depth),
        tostring(c.id or c.button or n.UIT or "?"), n.T.x, n.T.y, n.T.w, n.T.h)
      if n.children then
        for _, ch in pairs(n.children) do
          if type(ch) == "table" and ch.T and ch.config then walk(ch, depth + 1) end
        end
      end
    end
    if obj and obj.UIRoot then walk(obj.UIRoot, 0) end
    local area = ov:get_UIE_by_ID("modsList")
    local ac = area and area.config or {}
    _diag(string.format("snapshot %s: area cfg w=%s h=%s no_role=%s | %s", tag, tostring(ac.w), tostring(ac.h),
      tostring(ac.no_role), table.concat(parts, " ")))
  end)
end

local _last_state = nil
local _STATE_NAMES = { "boxX", "boxY", "rootX", "rootY", "areaX", "areaY", "alignX", "alignY", "rowX", "rowY", "ovX", "ovY" }
local function _track_list_state()
  local ov = G.OVERLAY_MENU
  local area = ov and ov.get_UIE_by_ID and ov:get_UIE_by_ID("modsList")
  local box = area and area.config and area.config.object
  if not (box and box.T and box.UIRoot and box.UIRoot.T and area.T) then _last_state = nil return end
  local row = ov:get_UIE_by_ID("bms_search_row")
  local al = box.alignment and box.alignment.offset
  local st = { box.T.x, box.T.y, box.UIRoot.T.x, box.UIRoot.T.y, area.T.x, area.T.y,
               al and al.x or 0, al and al.y or 0,
               row and row.T and row.T.x or 0, row and row.T and row.T.y or 0,
               ov.T and ov.T.x or 0, ov.T and ov.T.y or 0, box = box }
  if _last_state and _last_state.box == box then
    local diffs = {}
    for k = 1, 12 do
      if math.abs(st[k] - _last_state[k]) > 0.05 then
        diffs[#diffs + 1] = string.format("%s %.2f->%.2f", _STATE_NAMES[k], _last_state[k], st[k])
      end
    end
    if #diffs > 0 then
      _diag("list layout changed: " .. table.concat(diffs, ", ") .. " controller=" ..
        tostring(G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller))
    end
  end
  _last_state = st
end

-- The signature seen on a real PC (bms_layout.log): about 0.02 s after Clear on a controller
-- the list's area node (0 x 0, centred in its row) jumped by half of the row's width and
-- height - its alignment offset had been applied twice - and the Search: label dropped
-- with it, while everything else stayed. Detect it by comparing the area with the centre of
-- its row, and cure it with one clean relayout of the tab (which resets all offsets).
local _area_heals = 0
local function _area_off_centre()
  local ov = G.OVERLAY_MENU
  local area = ov and ov.get_UIE_by_ID and ov:get_UIE_by_ID("modsList")
  local row = area and area.parent
  if not (area and area.T and row and row.T) then return nil end
  local dx = area.T.x - (row.T.x + row.T.w / 2)
  local dy = area.T.y - (row.T.y + row.T.h / 2)
  if math.abs(dx) > 0.35 or math.abs(dy) > 0.35 then return area, dx, dy end
  return nil
end

local function _heal_area_if_off_centre()
  local ok, area, dx, dy = pcall(_area_off_centre)
  if not (ok and area) then return false end
  _area_heals = _area_heals + 1
  _diag(string.format("area off centre by %.2f,%.2f (offset %.2f,%.2f) - relayout #%d controller=%s", dx, dy,
    area.role and area.role.offset and area.role.offset.x or 0, area.role and area.role.offset and area.role.offset.y or 0,
    _area_heals, tostring(G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller)))
  pcall(_layout_snapshot, "area off centre")
  if _area_heals <= 6 then
    pcall(function() area.UIBox:recalculate() end)
  end
  local ok2, area2, dx2, dy2 = pcall(_area_off_centre)
  if ok2 and area2 then
    -- still off: move the area itself back
    pcall(function()
      area2.role.offset.x = area2.role.offset.x - dx2
      area2.role.offset.y = area2.role.offset.y - dy2
      area2:move_with_major(0)
    end)
    _diag("relayout was not enough, moved the area back by hand")
  end
  return true
end

local function _heal_list_if_displaced()
  pcall(_track_list_state)
  if _heal_pending then return end
  pcall(_heal_area_if_off_centre)
  local now = (G.TIMERS and G.TIMERS.REAL) or 0
  if now - _last_heal < 0.4 then return end
  local ok, bad = pcall(_list_displaced)
  local ok_c, broken = pcall(_area_config_broken)
  local restored = ok_c and broken
  if ok_c and broken then
    _diag("area config was reset, restoring")
    pcall(function()
      local area = G.OVERLAY_MENU:get_UIE_by_ID("modsList")
      area.config.w, area.config.h, area.config.no_role = 0, 0, true
    end)
    bad = true
    ok = true
  end
  if not (ok and bad) then return end
  _heal_pending = true
  _last_heal = now
  G.E_MANAGER:add_event(Event({
    trigger = "immediate", blocking = false, blockable = false,
    func = function()
      _heal_pending = false
      if restored then pcall(function() G.OVERLAY_MENU:recalculate() end) end
      _refresh_mods_list(SMODS.LAST_VIEWED_MODS_PAGE)
      return true
    end
  }))
end

-- Sort / search / filter changed: go back to page 1, fix the "Page x/y" selector
-- and rebuild the list.
local function _apply_view_change()
  local list = _visible_mods()
  _sync_pager(#list, 1)
  _refresh_mods_list(1)
end

-- Called from inside the UI update loop (the search box watcher), so the actual
-- rebuild is deferred to the event queue; several keystrokes in one frame only
-- cause one rebuild.
local function _schedule_view_change()
  if _refresh_pending then return end
  _refresh_pending = true
  G.E_MANAGER:add_event(Event({
    trigger = "immediate",
    blocking = false,
    blockable = false,
    func = function()
      _refresh_pending = false
      _apply_view_change()
      return true
    end
  }))
end

----------------------------------------------------------------------
-- Search box (lives in the static part of the Mods menu, above the list, so it
-- is NOT rebuilt - and does not lose the keyboard - while the list updates)
----------------------------------------------------------------------

local function _walk(node, fn)
  if type(node) ~= "table" then return end
  fn(node)
  if type(node.nodes) == "table" then
    for _, child in ipairs(node.nodes) do _walk(child, fn) end
  end
end

-- "Search: [ type here ] [Clear]"
-- Its first node's `func` runs every frame and notices when the text changed.
local function _build_search_group()
  local input = create_text_input({
    w = 3.1,
    max_length = SEARCH_MAX_LEN,
    text_scale = 0.3,
    prompt_text = "Type to search mods...",
    ref_table = _search,
    ref_value = "text",
    extended_corpus = true,   -- allows spaces, - _ . and digits
    colour = HEX and HEX("3A3550") or nil,
    hooked_colour = HEX and HEX("5A2D82") or nil,
  })
  -- The blinking cursor is 0.4 tall by default; make it match the smaller text.
  _walk(input, function(n)
    if n.config and n.config.id == "position" then n.config.h = 0.32 end
  end)

  return {
    n = G.UIT.R,
    config = { id = "bms_search_row", align = "cm", padding = 0 },
    nodes = {
      {
        n = G.UIT.C,
        config = { align = "cm", padding = 0.04, func = "bms_search_watch" },
        nodes = {
          { n = G.UIT.T, config = { text = "Search:", scale = 0.32, colour = G.C.WHITE, shadow = true } },
        }
      },
      input,
      { n = G.UIT.C, config = { minw = 0.1 }, nodes = {} },
      {
        n = G.UIT.C,
        config = {
          align = "cm", padding = 0.06, r = 0.1, minw = 0.9, minh = 0.4,
          colour = G.C.RED, hover = true, shadow = true, button = "bms_clear_search",
        },
        nodes = {
          { n = G.UIT.T, config = { text = "Clear", scale = 0.3, colour = G.C.WHITE, shadow = true } },
        }
      },
    }
  }
end

-- Find the column that holds the 'modsList' dynamic area (Steamodded's static page).
local function _find_modslist_column(node)
  if type(node) ~= "table" or type(node.nodes) ~= "table" then return nil end
  for i, child in ipairs(node.nodes) do
    if type(child) == "table" and type(child.nodes) == "table" then
      for _, grandchild in ipairs(child.nodes) do
        if type(grandchild) == "table" and grandchild.config and grandchild.config.id == "modsList" then
          return node, i
        end
      end
    end
  end
  for _, child in ipairs(node.nodes) do
    local col, idx = _find_modslist_column(child)
    if col then return col, idx end
  end
  return nil
end

-- Find Steamodded's "Page x/y" option selector table (its arrows reference it).
local function _find_pager_args(node)
  local found = nil
  _walk(node, function(n)
    if found then return end
    local c = n.config
    if type(c) == "table" and c.button == "option_cycle"
       and type(c.ref_table) == "table" and type(c.ref_table.options) == "table" then
      found = c.ref_table
    end
  end)
  return found
end

-- Layout (nothing here makes the menu taller, so it still fits the screen):
--  * The search box goes on the same line as the "Page x/y" selector, in the free
--    space to its left. The selector stays centred.
--  * The list's area node is pinned: size 0 x 0 (what Steamodded's placeholder has)
--    and `no_role`. Whenever the menu re-lays itself out - clicking into the search
--    box and typing both do - the game resizes every area node to its object and
--    re-aligns the object to it. With the real size the area would grow and push
--    everything around; with 0 x 0 the list would be re-aligned as if it were 0 x 0
--    big (its top-left corner lands on the centre: bottom-right of the screen).
--    `no_role` makes the game leave the list alone; it keeps aligning itself to the
--    area every frame, like it does in plain Steamodded.
local PAGER_SIDE_WIDTH = 5.7  -- (the LB/RB glyph slots next to the page selector take ~1.6 of the old 6.5 x 2)
local SEARCH_LEVEL_SPACER = 0.4

local function _inject_search_ui(tree)
  local col, list_idx = _find_modslist_column(tree)
  if not col then return false end

  -- the row that holds the page selector
  local pager_idx = nil
  for i = list_idx + 1, #col.nodes do
    if _find_pager_args(col.nodes[i]) then pager_idx = i break end
  end
  if not pager_idx then return false end

  local pager_row = col.nodes[pager_idx]
  col.nodes[pager_idx] = {
    n = G.UIT.R,
    config = { align = "cm", padding = 0 },
    nodes = {
      -- The spacer above the search group pushes it down to the height of the page
      -- selector itself (the selector has an empty label row above it).
      { n = G.UIT.C, config = { align = "cm", minw = PAGER_SIDE_WIDTH }, nodes = {
        { n = G.UIT.R, config = { minh = SEARCH_LEVEL_SPACER }, nodes = {} },
        _build_search_group(),
      } },
      { n = G.UIT.C, config = { align = "cm" }, nodes = { pager_row } },
      -- right side: the hotkey hint (same height trick as the search group)
      { n = G.UIT.C, config = { align = "cm", minw = PAGER_SIDE_WIDTH }, nodes = {
        { n = G.UIT.R, config = { minh = SEARCH_LEVEL_SPACER }, nodes = {} },
        { n = G.UIT.R, config = { align = "cm" }, nodes = {
          { n = G.UIT.T, config = { text = "Press S or R3 to search", scale = 0.3,
              colour = { 0.84, 0.86, 0.92, 1 }, shadow = true } },
        } },
        { n = G.UIT.R, config = { align = "cm" }, nodes = {
          { n = G.UIT.T, config = { text = "Hold S or R3 to clear", scale = 0.3,
              colour = { 0.84, 0.86, 0.92, 1 }, shadow = true } },
        } },
      } },
    }
  }

  -- fixed size for the list's area node
  for _, n in ipairs(col.nodes[list_idx].nodes or {}) do
    if type(n) == "table" and n.config and n.config.id == "modsList" then
      n.config.w = 0
      n.config.h = 0
      n.config.no_role = true
    end
  end

  _pager_args = _find_pager_args(tree)
  return true
end

-- The list is centred on its area, so a page with fewer mods (the last page, or a
-- search with a few matches) would float down and sideways. Keep the top of the list
-- where a full page has it: remember the tallest list built so far and shift shorter
-- ones up by half of the difference.
local _full_list_h = 0

local function _pin_list_top()
  if not (G and G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID) then return end
  local area = G.OVERLAY_MENU:get_UIE_by_ID("modsList")
  local box = area and area.config and area.config.object
  if not (box and box.T and box.alignment and box.alignment.offset) then return end
  box._bms_list = true   -- see _guard_list_recalculate
  local h = box.T.h
  if type(h) ~= "number" or h <= 0 then return end
  if h > _full_list_h then _full_list_h = h end
  box.alignment.offset.y = 0.5 - (_full_list_h - h) / 2
  if type(box.align_to_major) == "function" then box:align_to_major() end
end

----------------------------------------------------------------------
-- Restart prompt (replaces the instant restart after toggling mods)
----------------------------------------------------------------------

local _prompt_box = nil   -- the overlay menu of the prompt while it is showing

local function _needs_restart()
  return SMODS and SMODS.full_restart and SMODS.full_restart ~= 0
end

-- Names of the mods the player has switched on / off in this session of the menu.
local function _pending_changes()
  local turning_on, turning_off = {}, {}
  for _, m in ipairs(SMODS.mod_list or {}) do
    if m.should_enable ~= nil then
      local was_enabled = not m.disabled
      if m.should_enable and not was_enabled then
        turning_on[#turning_on + 1] = _display_name(m)
      elseif (not m.should_enable) and was_enabled then
        turning_off[#turning_off + 1] = _display_name(m)
      end
    end
  end
  return turning_on, turning_off
end

local function _names_line(prefix, names)
  if #names == 0 then return nil end
  local shown = {}
  for i = 1, math.min(3, #names) do
    local n = tostring(names[i])
    if #n > 24 then n = n:sub(1, 22) .. "..." end
    shown[#shown + 1] = n
  end
  local line = prefix .. table.concat(shown, ", ")
  if #names > 3 then line = line .. " +" .. (#names - 3) .. " more" end
  return line
end

local function _restart_prompt_definition()
  local turning_on, turning_off = _pending_changes()
  local contents = {
    {
      n = G.UIT.R, config = { align = "cm", padding = 0.08 },
      nodes = {{ n = G.UIT.T, config = { text = "Restart needed", scale = 0.7, colour = G.C.WHITE, shadow = true } }}
    },
    {
      n = G.UIT.R, config = { align = "cm", padding = 0.04 },
      nodes = {{ n = G.UIT.T, config = { text = "Your mod changes only take effect after Balatro restarts.", scale = 0.36, colour = G.C.UI.TEXT_LIGHT } }}
    },
  }
  for _, line in ipairs({ _names_line("Turning off: ", turning_off) or false, _names_line("Turning on: ", turning_on) or false }) do
    if line then
      contents[#contents + 1] = {
        n = G.UIT.R, config = { align = "cm", padding = 0.02 },
        nodes = {{ n = G.UIT.T, config = { text = line, scale = 0.3, colour = HEX and HEX("A9A9B8") or G.C.UI.TEXT_LIGHT } }}
      }
    end
  end
  contents[#contents + 1] = {
    n = G.UIT.R, config = { align = "cm", padding = 0.25 },
    nodes = {
      UIBox_button({
        label = { "Restart now" }, button = "bms_restart_now", colour = G.C.GREEN,
        minw = 3.6, minh = 0.9, scale = 0.5, col = true, focus_args = { snap_to = true },
      }),
      { n = G.UIT.C, config = { minw = 0.25 }, nodes = {} },
      UIBox_button({
        label = { "Later (close game)" }, button = "bms_restart_later", colour = G.C.RED,
        minw = 4.6, minh = 0.9, scale = 0.5, col = true,
      }),
    }
  }
  return create_UIBox_generic_options({
    back_func = "bms_restart_back",
    back_label = "Go back",
    contents = contents,
  })
end

local function _show_restart_prompt()
  G.SETTINGS.paused = true
  G.FUNCS.overlay_menu({
    definition = _restart_prompt_definition(),
    -- Esc must not slam the prompt shut: we handle it ourselves (= "Go back").
    config = { no_esc = true },
  })
  _prompt_box = G.OVERLAY_MENU
end

local function _kill_background_threads()
  for _, mgr in ipairs({ "SOUND_MANAGER", "SAVE_MANAGER", "HTTP_MANAGER" }) do
    pcall(function()
      local m = G and G[mgr]
      if m and m.channel then m.channel:push({ type = "kill" }) end
    end)
  end
end

-- Closing / restarting the game.
-- Steamodded's own restart (love.event.quit("restart")) does not relaunch the game on
-- every setup: here the game window closed, the Lovely console hung around for ~30 s
-- and nothing came back. So on Windows a tiny hidden PowerShell helper does it:
-- it waits for Balatro to exit (and force-closes it if it hangs), then - for a
-- restart - starts the game again through Steam (or the exe when it isn't a Steam
-- install). The script is written to Balatro's save folder.
local STEAM_APP_ID = "2379780"
local HELPER_PATH  = "bms_close_helper.ps1"
local TASK_NAME    = "BMS_Restart"
local LAUNCHER_PATH = "bms_launch_helper.ps1"

local function _ps_quote(s) return "'" .. tostring(s):gsub("'", "''") .. "'" end

local function _spawn_close_helper(relaunch)
  if not (love and love.system and love.system.getOS and love.system.getOS() == "Windows") then return false end
  if not (love.filesystem and love.filesystem.write and love.filesystem.getSaveDirectory) then return false end
  if type(os.execute) ~= "function" then return false end

  local exe = love.filesystem.getSource and love.filesystem.getSource() or ""
  exe = tostring(exe):gsub("/", "\\")
  local dir = exe:match("^(.*)\\[^\\]*$") or ""
  local is_steam = exe:lower():find("steamapps", 1, true) ~= nil

  local steam_url = "steam://rungameid/" .. STEAM_APP_ID
  local have_exe = exe:lower():match("%.exe$") ~= nil
  if not is_steam and not have_exe then return false end

  -- Why this is more than "wait, then start": Balatro can take several seconds to
  -- shut down (the game window is gone but the Lovely console and the process stay),
  -- and Steam keeps treating the game as running for a few seconds after the process
  -- ends - a launch request in that window is silently ignored. So: close the game
  -- quickly, wait until it is really gone, give Steam a moment, then ask Steam to
  -- start it and CHECK that it came up, retrying and finally starting the exe itself.
  local lines = {
    "$ErrorActionPreference = 'SilentlyContinue'",
    "$log = Join-Path $PSScriptRoot 'bms_close_helper.log'",
    "function Log($m) { Add-Content -Path $log -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $m) }",
    "Set-Content -Path $log -Value ('helper started, relaunch=" .. tostring(relaunch and true or false) .. "')",
    "$p = Get-Process -Name 'Balatro'",
    "if ($p) { $p | Wait-Process -Timeout 3 }",
    "$p = Get-Process -Name 'Balatro'",
    "if ($p) { Log 'game still running after 3s, force closing'; $p | Stop-Process -Force }",
    "for ($i = 0; $i -lt 30 -and (Get-Process -Name 'Balatro'); $i++) { Start-Sleep -Milliseconds 500 }",
    "Log 'game process is gone'",
  }
  if relaunch then
    local more = {
      "Start-Sleep -Seconds 2",
      -- Steam keeps its own 'running' flag for the game, and it can stay set for a
      -- minute after the process is gone; launch requests are ignored meanwhile (the
      -- first two requests used to be lost, the third worked ~70 s later). Wait for
      -- the flag to clear (at most 90 s), then ask once and verify.
      "$flag = 'HKCU:\\Software\\Valve\\Steam\\Apps\\" .. STEAM_APP_ID .. "'",
      "function Test-SteamRunning { $v = (Get-ItemProperty -Path $flag -Name Running -ErrorAction SilentlyContinue).Running; return ($v -eq 1) }",
      -- (measured: Steam keeps the flag set for ~75 s after a launch, so a restart
      -- soon after starting the game would wait that long. When the flag is still set
      -- after a few seconds, start the exe directly instead; the folder has
      -- steam_appid.txt, so Steam features still work.)
      "$w = 0",
      "$maxwait = " .. (have_exe and "6" or "90"),
      "while ((Test-SteamRunning) -and $w -lt $maxwait) { Start-Sleep -Seconds 1; $w++ }",
      "$up = $false",
      "if (Test-SteamRunning) { Log ('Steam still marks the game as running after ' + $w + 's') } else { Log ('Steam running flag clear after ' + $w + 's') }",
      "Start-Sleep -Seconds 1",
      (have_exe and ("if (Test-SteamRunning) { Log 'starting the exe directly'; Start-Process -FilePath " .. _ps_quote(exe) ..
        " -WorkingDirectory " .. _ps_quote(dir) .. "; for ($i = 0; $i -lt 70; $i++) { Start-Sleep -Milliseconds 500; if (Get-Process -Name 'Balatro') { $up = $true; break } } }") or "$null = 0"),
      "for ($try = 1; $try -le 3 -and -not $up; $try++) {",
      "  Log ('asking Steam to start the game, try ' + $try)",
      "  Start-Process " .. _ps_quote(steam_url),
      "  for ($i = 0; $i -lt 70; $i++) { Start-Sleep -Milliseconds 500; if (Get-Process -Name 'Balatro') { $up = $true; break } }",
      "  if (-not $up) { Start-Sleep -Seconds 5 }",
      "}",
    }
    if have_exe then
      more[#more + 1] = "if (-not $up) { Log 'Steam did not start it, starting the exe directly'; Start-Process -FilePath " ..
        _ps_quote(exe) .. " -WorkingDirectory " .. _ps_quote(dir) .. " }"
    end
    more[#more + 1] = "if ($up) { Log 'game is running again' }"
    more[#more + 1] = "Unregister-ScheduledTask -TaskName '" .. TASK_NAME .. "' -Confirm:$false | Out-Null"
    for _, l in ipairs(more) do lines[#lines + 1] = l end
  end
  local ok = pcall(love.filesystem.write, HELPER_PATH, table.concat(lines, "\r\n") .. "\r\n")
  if not ok then return false end

  local script = (love.filesystem.getSaveDirectory() .. "/" .. HELPER_PATH):gsub("/", "\\")
  local ps = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. script .. '"'

  -- The helper must NOT be a child of the game: Steam counts everything the game
  -- started as part of the running game, so while the helper is alive Steam answers
  -- "Game already running" to the relaunch (and the helper waits for it forever).
  -- Starting it through the Windows Task Scheduler makes it a child of the
  -- scheduler instead. If that is not possible, fall back to a plain start.
  local function ok_code(r) return r == 0 or r == true end
  local ran_ok = false
  if relaunch then
    -- A second tiny script registers and starts the scheduled task (with the
    -- "also run on battery" settings, which the plain schtasks command can't set).
    local launcher = {
      "$ErrorActionPreference = 'Stop'",
      "try {",
      "  $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument " ..
        _ps_quote('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. script .. '"'),
      "  $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable",
      "  Register-ScheduledTask -TaskName '" .. TASK_NAME .. "' -Action $a -Settings $s -Force | Out-Null",
      "  Start-ScheduledTask -TaskName '" .. TASK_NAME .. "'",
      "  exit 0",
      "} catch { exit 1 }",
    }
    local wrote = pcall(love.filesystem.write, LAUNCHER_PATH, table.concat(launcher, "\r\n") .. "\r\n")
    if wrote then
      local launcher_file = (love.filesystem.getSaveDirectory() .. "/" .. LAUNCHER_PATH):gsub("/", "\\")
      local okc, rc = pcall(os.execute, 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. launcher_file .. '"')
      ran_ok = okc and ok_code(rc)
    end
  end
  if not ran_ok then
    -- `start` gives the helper its own window (hidden), so it survives the game's
    -- console closing.
    local okp = pcall(os.execute, 'start "" ' .. ps)
    ran_ok = okp
  end
  return ran_ok
end

-- relaunch = true: restart the game; false: just close it.
local function _close_game(relaunch)
  pcall(function() SMODS.save_all_config() end)
  pcall(function() G:save_settings() end)
  _kill_background_threads()
  if _spawn_close_helper(relaunch) then
    love.event.quit()
  elseif relaunch then
    -- no helper available (not Windows?): Steamodded's own restart
    if not pcall(function() SMODS.restart_game() end) then love.event.quit() end
  else
    love.event.quit()
  end
end

-- If the text box is still "hooked" when its menu goes away, every key press would
-- be swallowed by a box that no longer exists.
local function _drop_stale_hook()
  local h = G and G.CONTROLLER and G.CONTROLLER.text_input_hook
  if h and h.config and type(h.config.ref_table) == "table" and h.config.ref_table.ref_table == _search then
    G.CONTROLLER.text_input_hook = nil
  end
end

----------------------------------------------------------------------
-- Install the extra handlers (safe to call more than once)
----------------------------------------------------------------------

-- Why the list must not be re-laid out together with the menu:
-- Clicking into the search box (and typing, and pressing Esc in it) makes the game
-- re-lay out the whole menu with UIBox:recalculate. That reaches the list's area
-- node, which calls recalculate() on the list as well. A UIBox lays itself out
-- starting from where it currently sits, and the list has already been moved to its
-- place by its alignment - so every such re-layout adds its own position a second
-- time: the whole list jumps down and to the right (about +1.7 / +2.7 units) and
-- stays there until it is rebuilt. The list is rebuilt from scratch whenever it
-- changes, so it never needs that re-layout: skip it while the menu is doing its own.
local _recalc_depth = 0
local function _guard_list_recalculate()
  if not (UIBox and type(UIBox.recalculate) == "function") then return end
  if UIBox._bms_guarded then return end
  UIBox._bms_guarded = true
  local old_recalculate = UIBox.recalculate
  UIBox.recalculate = function(self, ...)
    if self._bms_list and _recalc_depth > 0 then return end
    if self._bms_list then
      pcall(function()
        _diag("list box recalculated on its own: " .. tostring(debug and debug.traceback and debug.traceback("", 2)))
      end)
    end
    _recalc_depth = _recalc_depth + 1
    local ok, r1, r2, r3 = pcall(old_recalculate, self, ...)
    _recalc_depth = _recalc_depth - 1
    if not ok then error(r1, 0) end
    return r1, r2, r3
  end
end

-- Controller / keyboard-arrow navigation.
-- 1) The game moves the focus to the nearest control (by distance) in the pressed
--    direction. Next to each other, the sort button and the filter button lose to
--    the mod tiles under them, so Left / Right between the two is handled here.
-- 2) When a search / filter / last page leaves only a few mods, the empty gap
--    under the list makes "nearest" skip over things (Up from the page selector
--    jumps over the mods, Down from the tabs lands on the search row, ...). On such
--    short lists Up / Down walk row by row instead: the next row in that direction
--    that has a control lined up with the current one, the closest one sideways.
--    Full pages keep the game's own behaviour.
local function _list_is_partial()
  if not (G and G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID) then return false end
  if not G.OVERLAY_MENU:get_UIE_by_ID("bms_search_row") then return false end
  local area = G.OVERLAY_MENU:get_UIE_by_ID("modsList")
  local box = area and area.config and area.config.object
  return (box and box.T and _full_list_h > 0 and box.T.h < _full_list_h - 0.05) and true or false
end

local ROW_TOL = 0.3   -- controls whose centres are this close sit in one row

local function _row_nav(ctrl, dir)
  local cur = ctrl.focused.target
  if not (cur and cur.T) then return false end
  local function geo(n)
    local g = n
    local fa = n.config and n.config.focus_args
    if fa and type(fa.funnel_to) == "table" and fa.funnel_to.T then g = fa.funnel_to end
    return g.T.x, g.T.x + g.T.w, g.T.x + g.T.w / 2, g.T.y + g.T.h / 2
  end
  local cl, cr, cx, cy = geo(cur)
  local items = {}
  for _, v in pairs(G.MOVEABLES) do
    if v ~= cur and v.T and ctrl:is_node_focusable(v) then
      local l, r, x, y = geo(v)
      local beyond = (dir == "D" and y > cy + ROW_TOL) or (dir == "U" and y < cy - ROW_TOL)
      if beyond then items[#items + 1] = { node = v, l = l, r = r, x = x, y = y } end
    end
  end
  if #items == 0 then return false end
  table.sort(items, function(a, b) return math.abs(a.y - cy) < math.abs(b.y - cy) end)
  -- walk the rows nearest first; the first row with a control lined up wins
  local i = 1
  while i <= #items do
    local row_y = items[i].y
    local best, best_d = nil, math.huge
    local j = i
    while j <= #items and math.abs(items[j].y - row_y) <= ROW_TOL do
      local it = items[j]
      local overlap = math.min(cr, it.r) - math.max(cl, it.l)
      if overlap > 0.05 then
        local d = math.abs(it.x - cx)
        if d < best_d then best, best_d = it, d end
      end
      j = j + 1
    end
    if best then
      ctrl.focused.prev_target = cur
      cur.states.focus.is = false
      ctrl.focused.target = best.node
      best.node.states.focus.is = true
      if G.VIBRATION then G.VIBRATION = G.VIBRATION + 0.7 end
      return true
    end
    i = j
  end
  return false
end

local function _guard_button_navigation()
  if not (Controller and type(Controller.update_focus) == "function") then return end
  if Controller._bms_nav then return end
  Controller._bms_nav = true
  local old_update_focus = Controller.update_focus
  Controller.update_focus = function(self, dir, ...)
    if (dir == "U" or dir == "D") and self.focused and self.focused.target
       and self.HID and self.HID.controller and not self.interrupt.focus
       and not self.screen_keyboard and not self.text_input_hook
       and not (self.locked and not (G.SETTINGS and G.SETTINGS.paused)) then
      local ok, partial = pcall(_list_is_partial)
      if ok and partial then
        local ok2, handled = pcall(_row_nav, self, dir)
        if ok2 and handled then return end
      end
    end
    if (dir == "L" or dir == "R") and self.focused and self.focused.target then
      local t = self.focused.target
      local b = t.config and t.config.button
      local want_id = (dir == "R" and b == "bms_cycle_sort" and BTN_FILTER_ID)
                   or (dir == "L" and b == "bms_cycle_filter" and BTN_SORT_ID)
      if want_id and G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID then
        local node = G.OVERLAY_MENU:get_UIE_by_ID(want_id)
        if node and self:is_node_focusable(node) then
          self.focused.prev_target = t
          t.states.focus.is = false
          self.focused.target = node
          node.states.focus.is = true
          if G.VIBRATION then G.VIBRATION = G.VIBRATION + 0.7 end
          return
        end
      end
    end
    return old_update_focus(self, dir, ...)
  end
end

-- After pressing one of the two buttons the list (and with it the button) is
-- rebuilt; put the controller focus back on the new button so the player can
-- keep pressing it or step to its neighbour.
local function _refocus_button(id)
  pcall(function()
    local c = G.CONTROLLER
    if not (c and c.HID and c.HID.controller and G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID) then return end
    local node = G.OVERLAY_MENU:get_UIE_by_ID(id)
    if node and c:is_node_focusable(node) then
      c.focused.target = node
      node.states.focus.is = true
      c:update_cursor()
    end
  end)
end

-- Hotkey: S (keyboard) or R3 (press the right stick) jumps to the search box and
-- starts typing, from anywhere in the Mods menu.
local function _focus_search_box()
  local C = G and G.CONTROLLER
  if not (C and G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID) then return false end
  if C.text_input_hook or C.screen_keyboard or C.locked then return false end
  local row = G.OVERLAY_MENU:get_UIE_by_ID("bms_search_row")
  if not row then return false end
  local box = G.OVERLAY_MENU:get_UIE_by_ID("text_input", row)
  if not box then return false end
  G.FUNCS.select_text_input(box)
  return true
end

-- Tap = jump to the search box (on release); hold for HOLD_CLEAR_SECS = clear the search.
local HOLD_CLEAR_SECS = 0.6
local _hold = nil  -- { id = "s" | "rightstick", t0 = seconds, fired = bool }

local function _search_available()
  local C = G and G.CONTROLLER
  if not (C and G.OVERLAY_MENU and G.OVERLAY_MENU.get_UIE_by_ID) then return false end
  if C.text_input_hook or C.screen_keyboard or C.locked then return false end
  return G.OVERLAY_MENU:get_UIE_by_ID("bms_search_row") ~= nil
end

local function _hold_begin(id)
  local now = (G.TIMERS and G.TIMERS.REAL) or 0
  if _hold and _hold.id == id and now - _hold.t0 < 10 then return true end -- key repeat
  if not _search_available() then return false end
  _hold = { id = id, t0 = now, fired = false }
  return true
end

local function _hold_end(id)
  local h = _hold
  if not (h and h.id == id) then return end
  _hold = nil
  if not h.fired then pcall(_focus_search_box) end
end

-- called every frame by the search row's watcher
local function _hold_tick()
  local h = _hold
  if not h or h.fired then return end
  local now = (G.TIMERS and G.TIMERS.REAL) or 0
  if now - h.t0 < HOLD_CLEAR_SECS then return end
  h.fired = true
  if G.FUNCS.bms_clear_search then pcall(G.FUNCS.bms_clear_search) end
end

local function _guard_hotkeys()
  if not (Controller and type(Controller.key_press_update) == "function") then return end
  if Controller._bms_keys then return end
  Controller._bms_keys = true
  local old_key = Controller.key_press_update
  Controller.key_press_update = function(self, key, ...)
    if key == "s" and not self.text_input_hook then
      local ok, done = pcall(_hold_begin, "s")
      if ok and done then return end
    end
    return old_key(self, key, ...)
  end
  if type(Controller.key_release_update) == "function" then
    local old_rel = Controller.key_release_update
    Controller.key_release_update = function(self, key, ...)
      if key == "s" then pcall(_hold_end, "s") end
      return old_rel(self, key, ...)
    end
  end
  if type(Controller.button_press_update) == "function" then
    local old_btn = Controller.button_press_update
    Controller.button_press_update = function(self, button, ...)
      if button == "rightstick" and not self.text_input_hook and not self.locks.frame then
        local ok, done = pcall(_hold_begin, "rightstick")
        if ok and done then return end
      end
      return old_btn(self, button, ...)
    end
  end
  if type(Controller.button_release_update) == "function" then
    local old_brel = Controller.button_release_update
    Controller.button_release_update = function(self, button, ...)
      if button == "rightstick" then pcall(_hold_end, "rightstick") end
      return old_brel(self, button, ...)
    end
  end
end

----------------------------------------------------------------------
-- Controller shoulders in the Mods menu
--   LB / RB : previous / next page of the mod list  (glyphs next to the page selector)
--   LT / RT : previous / next top tab (Mods / Credits / Config)  (glyphs on the tab strip)
-- Same behaviour as Balatro Mod Updater.
----------------------------------------------------------------------
local function _mods_menu_open()
  local om = G and G.OVERLAY_MENU
  if not (om and om.get_UIE_by_ID) then return false end
  local ok, found = pcall(function()
    local label = localize and localize("b_mods") or "Mods"
    return om:get_UIE_by_ID("tab_shoulders") and om:get_UIE_by_ID("tab_but_" .. tostring(label))
  end)
  return ok and found and true or false
end

local function _cycle_top_tab(dir)
  local om = G and G.OVERLAY_MENU
  local strip = om and om:get_UIE_by_ID("tab_shoulders")
  if not strip then return false end
  local ok, done = pcall(function()
    local proto = strip.UIBox:get_group(nil, strip.children[1].children[1].config.group)
    local choices = {}
    for _, v in ipairs(proto) do
      if v.config.choice and v.config.button then choices[#choices + 1] = v end
    end
    for k, v in ipairs(choices) do
      if v.config.chosen then
        local nxt = k + dir
        if nxt < 1 then nxt = #choices elseif nxt > #choices then nxt = 1 end
        choices[nxt]:click()
        G.CONTROLLER:snap_to({ node = choices[nxt] })
        G.CONTROLLER:update_cursor()
        return true
      end
    end
    return false
  end)
  return ok and done and true or false
end

local function _guard_option_selector()
  if not (SMODS and SMODS.GUI and type(SMODS.GUI.createOptionSelector) == "function") then return end
  if SMODS.GUI._bms_selector then return end
  SMODS.GUI._bms_selector = true
  local old = SMODS.GUI.createOptionSelector
  SMODS.GUI.createOptionSelector = function(args, ...)
    -- the mod list's "Page x/y": let LB / RB turn the pages (and show their glyphs)
    if type(args) == "table" and args.opt_callback == "update_mod_list" and args.cycle_shoulders == nil then
      args.cycle_shoulders = true
    end
    return old(args, ...)
  end
end

local function _guard_shoulders()
  if not (Controller and type(Controller.button_press_update) == "function") then return end
  if not Controller._bms_shoulders then
    Controller._bms_shoulders = true
    local old_btn = Controller.button_press_update
    Controller.button_press_update = function(self, button, ...)
      if (button == "triggerleft" or button == "triggerright")
         and not self.locks.frame and not self.text_input_hook and not self.screen_keyboard
         and _mods_menu_open() then
        if _cycle_top_tab(button == "triggerright" and 1 or -1) then
          self.held_button_times[button] = 0
          if self.interrupt then self.interrupt.focus = false end
          return
        end
      end
      -- LB / RB only turn pages; on Credits / Config (no pages) they must not switch tabs
      if (button == "leftshoulder" or button == "rightshoulder")
         and not self.locks.frame and not self.text_input_hook and not self.screen_keyboard
         and _mods_menu_open() then
        local om = G.OVERLAY_MENU
        if not om:get_UIE_by_ID("cycle_shoulders") then
          self.held_button_times[button] = 0
          return
        end
      end
      return old_btn(self, button, ...)
    end
  end
  -- on the Mods tab strip show LT / RT glyphs instead of LB / RB
  if G and G.FUNCS and G.FUNCS.set_button_pip and not G.FUNCS._bms_pip then
    G.FUNCS._bms_pip = true
    local orig_pip = G.FUNCS.set_button_pip
    G.FUNCS.set_button_pip = function(e)
      local fa = e and e.config and e.config.focus_args
      if fa and e.children and not e.children.button_pip
         and (fa.button == "leftshoulder" or fa.button == "rightshoulder")
         and G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller then
        local ok, swap = pcall(function()
          if not _mods_menu_open() then return false end
          local par = e.parent
          if not par or not par.children then return false end
          for _, ch in pairs(par.children) do
            if type(ch) == "table" and ch.config and ch.config.id == "tab_shoulders" then return true end
          end
          return false
        end)
        if ok and swap then
          fa.button = (fa.button == "leftshoulder") and "triggerleft" or "triggerright"
        end
      end
      return orig_pip(e)
    end
  end
end

local function _install_extras()
  _guard_list_recalculate()
  _guard_button_navigation()
  _guard_hotkeys()
  _guard_option_selector()
  _guard_shoulders()
  if not (G and G.FUNCS) then return end
  if G.FUNCS.__bms_extras then return end
  G.FUNCS.__bms_extras = true

  -- Sort button
  G.FUNCS.bms_cycle_sort = function(_e)
    _next_sort_mode()
    _ts_cache = { updated = {}, config = {} }
    _apply_view_change()
    _refocus_button(BTN_SORT_ID)
  end

  -- Show: All Mods / Enabled / Disabled button
  G.FUNCS.bms_cycle_filter = function(_e)
    _next_filter_mode()
    _apply_view_change()
    _refocus_button(BTN_FILTER_ID)
  end

  -- Runs every frame on a node in the search row: re-filter when the text changed.
  G.FUNCS.bms_search_watch = function(_e)
    _heal_list_if_displaced()
    if _hold_tick then pcall(_hold_tick) end
    local _, normalised = _normalise_query(_search.text)
    if normalised ~= _applied_query then
      _applied_query = normalised
      _schedule_view_change()
    end
  end

  -- Clear button: empty the box the same way the game's own "paste seed" does
  -- (move the cursor to the end, then backspace everything).
  G.FUNCS.bms_clear_search = function(_e)
    if _search.text == "" and not (G.CONTROLLER and G.CONTROLLER.text_input_hook) then return end
    _diag("Clear pressed, controller=" .. tostring(G.CONTROLLER and G.CONTROLLER.HID and G.CONTROLLER.HID.controller)
      .. " hook=" .. tostring(G.CONTROLLER and G.CONTROLLER.text_input_hook ~= nil))
    _layout_snapshot("at Clear")
    for _, delay in ipairs({ 0.15, 0.8 }) do
      G.E_MANAGER:add_event(Event({
        trigger = "after", delay = delay, timer = "REAL", blocking = false, blockable = false,
        func = function() _layout_snapshot("Clear+" .. delay .. "s") return true end
      }))
    end
    local cleared = false
    pcall(function()
      local row = G.OVERLAY_MENU and G.OVERLAY_MENU:get_UIE_by_ID("bms_search_row")
      local box = row and G.OVERLAY_MENU:get_UIE_by_ID("text_input", row)
      local field = box and box.children and box.children[1] and box.children[1].children and box.children[1].children[1]
      if field then
        local previous, previous_id = G.CONTROLLER.text_input_hook, G.CONTROLLER.text_input_id
        G.CONTROLLER.text_input_hook = field
        -- the game's text code needs this id; it is nil until a box was selected once
        G.CONTROLLER.text_input_id = box.config.id or "text_input"
        local ok_keys = pcall(function()
          for _ = 1, SEARCH_MAX_LEN do G.FUNCS.text_input_key({ key = "right" }) end
          for _ = 1, SEARCH_MAX_LEN do G.FUNCS.text_input_key({ key = "backspace" }) end
        end)
        -- always put the hook back, even if a key press failed
        G.CONTROLLER.text_input_hook = previous
        G.CONTROLLER.text_input_id = previous_id
        cleared = ok_keys
      end
    end)
    if not cleared then _search.text = "" end
  end

  -- The game turns the key "0" into the letter "o" in every text box; searching
  -- for "2025" / "v1.0" needs the real zero.
  local old_key = G.FUNCS.text_input_key
  if type(old_key) == "function" then
    G.FUNCS.text_input_key = function(args)
      local hook = G.CONTROLLER and G.CONTROLLER.text_input_hook
      if args and args.key == "0" and hook and hook.config and type(hook.config.ref_table) == "table"
         and hook.config.ref_table.ref_table == _search
         and type(TRANSPOSE_TEXT_INPUT) == "function" and type(MODIFY_TEXT_INPUT) == "function" then
        local cfg = hook.config.ref_table
        local text = cfg.text
        if cfg.max_length > string.len(text.ref_table[text.ref_value]) then
          TRANSPOSE_TEXT_INPUT(0)
          MODIFY_TEXT_INPUT{ letter = "0", text_table = text, pos = text.current_position + 1 }
          TRANSPOSE_TEXT_INPUT(1)
        end
        return
      end
      return old_key(args)
    end
  end

  -- Never leave the search box hooked to a menu that is gone.
  for _, name in ipairs({ "overlay_menu", "exit_overlay_menu" }) do
    local old_fn = G.FUNCS[name]
    if type(old_fn) == "function" then
      G.FUNCS[name] = function(...)
        _drop_stale_hook()
        return old_fn(...)
      end
    end
  end

  -- Restart prompt buttons
  G.FUNCS.bms_restart_now = function(_e)
    _prompt_box = nil
    _close_game(true)
  end

  G.FUNCS.bms_restart_later = function(_e)
    _prompt_box = nil
    _close_game(false)
  end

  -- "Go back" / Esc / B: return to the Mods menu (the toggles are still pending).
  G.FUNCS.bms_restart_back = function(_e)
    if not _prompt_box then return end
    _prompt_box = nil
    G.FUNCS.mods_button()
  end

  -- Steamodded restarts the game the moment the Mods menu is left after a mod was
  -- toggled. Ask first instead.
  local old_exit = G.FUNCS.exit_mods
  if type(old_exit) == "function" then
    G.FUNCS.exit_mods = function(e)
      -- The prompt is open and Esc was pressed: act like "Go back" (after this key
      -- press has finished, so the new menu is not closed by the same Esc).
      if _prompt_box and G.OVERLAY_MENU == _prompt_box then
        if not e then
          G.E_MANAGER:add_event(Event({
            blocking = false, blockable = false,
            func = function() G.FUNCS.bms_restart_back() return true end
          }))
        end
        return
      end
      _prompt_box = nil

      if not e and G.CONTROLLER and G.CONTROLLER.text_input_hook then
        -- Esc while typing in the search box only leaves the box (the game does
        -- that itself right after this) - it must not close the Mods menu.
        return
      end

      if _needs_restart() then
        G.CONTROLLER.text_input_hook = nil
        G.ACTIVE_MOD_UI = nil
        pcall(function() SMODS.save_all_config() end)
        _show_restart_prompt()
        return
      end

      _drop_stale_hook()
      return old_exit(e)
    end
  end
end

----------------------------------------------------------------------
-- Main patch
----------------------------------------------------------------------

local function _patch_dynamic()
  if not SMODS or not SMODS.GUI then return false end
  if SMODS.GUI.__bms_patched then return true end
  if type(SMODS.GUI.dynamicModListContent) ~= "function" then return false end

  local old = SMODS.GUI.dynamicModListContent

  local create_box = _find_create_box(old)

  _install_extras()

  -- After every rebuild of the list, pin its top (see _pin_list_top).
  local mgr = SMODS.GUI.DynamicUIManager
  if mgr and type(mgr.updateDynamicAreas) == "function" and not mgr.__bms_wrapped then
    local old_update = mgr.updateDynamicAreas
    mgr.updateDynamicAreas = function(defs, ...)
      local result = old_update(defs, ...)
      if type(defs) == "table" and defs.modsList then pcall(_pin_list_top) end
      return result
    end
    mgr.__bms_wrapped = true
  end

  -- Add the search box to the static part of the Mods menu.
  if type(SMODS.GUI.staticModListContent) == "function" then
    local old_static = SMODS.GUI.staticModListContent
    SMODS.GUI.staticModListContent = function(...)
      local tree = old_static(...)
      _reset_search_state()
      local ok, err = pcall(_inject_search_ui, tree)
      if not ok then
        _pager_args = nil
        print("[BalatroModSort] could not add the search box: " .. tostring(err))
      end
      return tree
    end
  end

  -- Shared header for both list builders: clamps the page, builds the sort row and
  -- the "nothing found" message.
  local function begin_list(page)
    local visible, narrowed, total = _visible_mods()
    page = math.max(1, math.min(tonumber(page) or SMODS.LAST_VIEWED_MODS_PAGE or 1, _page_count(#visible)))
    SMODS.LAST_VIEWED_MODS_PAGE = page
    local _, _, showingList, startIndex, endIndex, modsRowPerPage, modsColPerRow =
      _inline_recalc(page, #visible)
    local modNodes = {}
    -- Sort / Show buttons (and match count while narrowed) at the top of the list.
    table.insert(modNodes, _sort_button_row(narrowed and #visible or nil, total))
    if not showingList then
      table.insert(modNodes, {
        n = G.UIT.R,
        config = { padding = 0.1, align = "cm" },
        nodes = {{ n = G.UIT.T, config = {
          text = narrowed and "No mods match your search" or localize('b_no_mods'),
          shadow = true, scale = MOD_BOX_SCALE, colour = narrowed and G.C.WHITE or G.C.UI.TEXT_DARK
        }}}
      })
    end
    return visible, showingList, startIndex, endIndex, modsRowPerPage, modsColPerRow, modNodes
  end

  if create_box then
    -- Full replacement: single sorted pass, no grouping by can_load / config_tab.
    SMODS.GUI.dynamicModListContent = function(page)
      local visible, showingList, startIndex, endIndex, modsRowPerPage, modsColPerRow, modNodes = begin_list(page)

      if showingList then
        local grid = _build_grid(visible, startIndex, endIndex, modsRowPerPage, modsColPerRow, create_box)
        for _, row in ipairs(grid) do
          table.insert(modNodes, row)
        end
      end

      return { n = G.UIT.C, config = { r = 0.1, align = "cm", padding = 0 }, nodes = modNodes }
    end
  else
    -- Robust fallback: call the original function once per mod (with a temporary
    -- single-element mod list) to extract each mod's pre-rendered UI box, then
    -- assemble them in sorted order with our own pagination.  This avoids
    -- any dependence on debug.getupvalue and still produces a properly sorted list.
    SMODS.GUI.dynamicModListContent = function(page)
      local visible, showingList, startIndex, endIndex, modsRowPerPage, modsColPerRow, modNodes = begin_list(page)

      if showingList then
        local orig_list = SMODS.mod_list

        -- Collect page mods into a flat list of UI boxes.
        local page_boxes = {}
        local id = 0
        for _, modInfo in ipairs(visible) do
          id = id + 1
          if id >= startIndex and id <= endIndex then
            -- Temporarily replace mod_list so the original function renders
            -- only this one mod, letting createClickableModBox run naturally.
            SMODS.mod_list = { modInfo }
            local ok, res = pcall(old, 1)
            SMODS.mod_list = orig_list  -- always restore immediately

            -- Extract the first G.UIT.C node from the returned tree.
            local box = nil
            if ok and type(res) == "table" and res.nodes then
              for _, row in ipairs(res.nodes) do
                if type(row) == "table" and row.nodes then
                  for _, b in ipairs(row.nodes) do
                    if type(b) == "table" and b.n == G.UIT.C then
                      box = b
                      break
                    end
                  end
                end
                if box then break end
              end
            end

            if box then
              table.insert(page_boxes, box)
            end
          end
          if id >= endIndex then break end
        end
        -- The original resets the "last viewed page" to 1 on every call.
        SMODS.LAST_VIEWED_MODS_PAGE = math.max(1, math.min(tonumber(page) or 1, _page_count(#visible)))

        -- Place boxes into a 2-D grid using column-major order.
        local grid = {}
        for r = 1, modsRowPerPage do grid[r] = {} end
        for i, box in ipairs(page_boxes) do
          local col = math.floor((i - 1) / modsRowPerPage) + 1
          local row = ((i - 1) % modsRowPerPage) + 1
          grid[row][col] = box
        end

        for r = 1, modsRowPerPage do
          if grid[r][1] then
            table.insert(modNodes, {
              n = G.UIT.R,
              config = { padding = 0, align = "lc" },
              nodes = grid[r]
            })
          end
        end
      end

      return { n = G.UIT.C, config = { r = 0.1, align = "cm", padding = 0 }, nodes = modNodes }
    end
  end

  SMODS.GUI.__bms_patched = true
  return true
end

-- Try immediately (many setups already have SMODS.GUI by the time mods load)
if not _patch_dynamic() then
  -- Fallback: patch as soon as the Mods menu is opened.
  -- This ensures we don't depend on load ordering across Steamodded versions.
  if G and G.FUNCS and type(G.FUNCS.mods_button) == "function" and not G.FUNCS.__bms_wrapped then
    local old_btn = G.FUNCS.mods_button
    G.FUNCS.mods_button = function(e)
      _patch_dynamic()
      return old_btn(e)
    end
    G.FUNCS.__bms_wrapped = true
  end
end
