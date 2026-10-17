--- STEAMODDED HEADER
--- MOD_NAME: Balatro Mod Sort
--- MOD_ID: BalatroModSort
--- MOD_AUTHOR: [SilvertongueRED, ChatGPT, Claude]
--- MOD_DESCRIPTION: Sort your Mods menu by name, recently updated, or config changes — without changing load order.
--- PRIORITY: 1000000000
--- BADGE_COLOUR: 5A2D82
--- BADGE_TEXT_COLOUR: FFFFFF
--- DISPLAY_NAME: Mod Sort
--- VERSION: 2.1.0
--- PREFIX: bms

-- Balatro Mod Sort (display-only)
-- This mod patches Steamodded's Mods menu builder so the list can be sorted
-- by multiple criteria without changing the underlying load order (priority-based).
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

local function _sorted_copy(mod_list)
  local t = {}
  for i, v in ipairs(mod_list or {}) do t[i] = v end

  if _current_sort == "updated" then
    -- Cache timestamps to avoid repeated filesystem calls during sort.
    local cache = {}
    for _, m in ipairs(t) do cache[m] = _mod_update_time(m) end
    table.sort(t, function(a, b)
      local ta, tb = cache[a] or 0, cache[b] or 0
      if ta ~= tb then return ta > tb end  -- newest first
      local na, nb = _safe_lower(_display_name(a)), _safe_lower(_display_name(b))
      if na ~= nb then return na < nb end
      return tostring(a.id or "") < tostring(b.id or "")
    end)

  elseif _current_sort == "config" then
    local cache = {}
    for _, m in ipairs(t) do cache[m] = _config_change_time(m) end
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

-- Two parts side by side, both the same fixed width so the row is always symmetrical:
--   [ Now: <current sort> ]  (info only, not clickable)
--   [ Next: <next sort>   ]  (the button - click / press A to switch to that sort)
local function _sort_button_row()
  local btn_colour  = HEX and HEX("5A2D82") or {0.35, 0.18, 0.51, 1}
  local pill_colour = HEX and HEX("2B2B35") or {0.17, 0.17, 0.21, 1}
  local dim_text    = HEX and HEX("A9A9B8") or {0.66, 0.66, 0.72, 1}
  local scale = 0.27
  local cur  = SORT_LABELS[_current_sort] or SORT_LABELS.alpha
  local nxt  = SORT_LABELS[_peek_next_sort()] or SORT_LABELS.alpha
  return {
    n = G.UIT.R,
    config = { padding = 0.05, align = "cm" },
    nodes = {
      {
        n = G.UIT.C,
        config = { align = "cm", padding = 0.07, r = 0.1, minw = 2.4, minh = 0.36, colour = pill_colour },
        nodes = {
          { n = G.UIT.T, config = { text = "Now: ", scale = scale, colour = dim_text } },
          { n = G.UIT.T, config = { text = cur, scale = scale, colour = G.C.WHITE, shadow = true } },
        }
      },
      { n = G.UIT.C, config = { minw = 0.12 }, nodes = {} },
      {
        n = G.UIT.C,
        config = {
          align = "cm", padding = 0.07, r = 0.1, minw = 2.4, minh = 0.36,
          colour = btn_colour, hover = true, shadow = true, button = "bms_cycle_sort",
        },
        nodes = {
          { n = G.UIT.T, config = { text = "Next: " .. nxt, scale = scale, colour = G.C.WHITE, shadow = true } },
        }
      },
    }
  }
end

----------------------------------------------------------------------
-- Refresh the mods list UI after a sort-mode change
----------------------------------------------------------------------

local function _refresh_mods_list()
  local page = SMODS.LAST_VIEWED_MODS_PAGE or 1
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

----------------------------------------------------------------------
-- Main patch
----------------------------------------------------------------------

local function _patch_dynamic()
  if not SMODS or not SMODS.GUI then return false end
  if SMODS.GUI.__bms_patched then return true end
  if type(SMODS.GUI.dynamicModListContent) ~= "function" then return false end

  local old = SMODS.GUI.dynamicModListContent

  local create_box = _find_create_box(old)

  -- Register the sort-cycle button handler.
  if G and G.FUNCS then
    G.FUNCS.bms_cycle_sort = function(_e)
      _next_sort_mode()
      _refresh_mods_list()
    end
  end

  if create_box then
    -- Full replacement: single sorted pass, no grouping by can_load / config_tab.
    SMODS.GUI.dynamicModListContent = function(page)
      local sorted  = _sorted_copy(SMODS.mod_list)
      local _, _, showingList, startIndex, endIndex, modsRowPerPage, modsColPerRow =
        _inline_recalc(page, #sorted)
      local modNodes = {}

      -- Sort button at the top of the list.
      table.insert(modNodes, _sort_button_row())

      if not showingList then
        table.insert(modNodes, {
          n = G.UIT.R,
          config = { padding = 0, align = "cm" },
          nodes = {{ n = G.UIT.T, config = {
            text = localize('b_no_mods'), shadow = true,
            scale = MOD_BOX_SCALE, colour = G.C.UI.TEXT_DARK
          }}}
        })
      else
        local grid = _build_grid(sorted, startIndex, endIndex, modsRowPerPage, modsColPerRow, create_box)
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
      local sorted  = _sorted_copy(SMODS.mod_list)
      local total   = #sorted
      local _, _, showingList, startIndex, endIndex, modsRowPerPage, modsColPerRow =
        _inline_recalc(page, total)
      local modNodes = {}

      -- Sort button at the top of the list.
      table.insert(modNodes, _sort_button_row())

      if not showingList then
        local ok, res = pcall(old, page)
        if ok and res then return res end
        table.insert(modNodes, {
          n = G.UIT.R,
          config = { padding = 0, align = "cm" },
          nodes = {{ n = G.UIT.T, config = {
            text = localize('b_no_mods'), shadow = true,
            scale = MOD_BOX_SCALE, colour = G.C.UI.TEXT_DARK
          }}}
        })
      else
        local orig_list = SMODS.mod_list

        -- Collect page mods into a flat list of UI boxes.
        local page_boxes = {}
        local id = 0
        for _, modInfo in ipairs(sorted) do
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
