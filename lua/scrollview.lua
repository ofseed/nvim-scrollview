local api = vim.api
local fn = vim.fn

local utils = require('scrollview.utils')
local binary_search = utils.binary_search
local concat = utils.concat
local copy = utils.copy
local preceding = utils.preceding
local remove_duplicates = utils.remove_duplicates
local round = utils.round
local sorted = utils.sorted
local subsequent = utils.subsequent
local t = utils.t
local tbl_get = utils.tbl_get
local to_bool = utils.to_bool

-- WARN: Sometimes 1-indexing is used (primarily for mutual Vim/Neovim API
-- calls) and sometimes 0-indexing (primarily for Neovim-specific API calls).
-- WARN: Don't move the cursor or change the current window. It can have
-- unwanted side effects (e.g., #18, #23, #43, window sizes changing to satisfy
-- winheight/winwidth, etc.).
-- WARN: Functionality that temporarily moves the cursor and restores it should
-- use a window workspace to prevent unwanted side effects. More details are in
-- the documentation for with_win_workspace.
-- XXX: Some of the functionality is applicable to bars and signs, but is
-- named as if it were only applicable to bars (since it was implemented prior
-- to sign support).

-- *************************************************
-- * Memoization
-- *************************************************

local cache = {}
local memoize = false

local start_memoize = function()
  memoize = true
end

local stop_memoize = function()
  memoize = false
end

local reset_memoize = function()
  cache = {}
end

-- *************************************************
-- * Globals
-- *************************************************

-- Internal flag for tracking scrollview state.
local scrollview_enabled = false

-- Since there is no text displayed in the buffers, the same buffers are used
-- for multiple windows. This also prevents the buffer list from getting high
-- from usage of the plugin.

-- bar_bufnr has the bufnr of the buffer created for a position bar.
local bar_bufnr = -1

-- sign_bufnr has the bufnr of the buffer created for signs.
local sign_bufnr = -1

-- Keep count of pending async refreshes.
local pending_async_refresh_count = 0

-- A window variable is set on each scrollview window, as a way to check for
-- scrollview windows, in addition to matching the scrollview buffer number
-- saved in bar_bufnr. This was preferable versus maintaining a list of window
-- IDs.
local win_var = 'scrollview_key'
local win_val = 'scrollview_val'

-- For win workspaces, a window variable is used to store the base window ID.
local win_workspace_base_winid_var = 'scrollview_win_workspace_base_winid'

-- A type field is used to indicate the type of scrollview windows.
local bar_type = 0
local sign_type = 1

-- A key for saving scrollbar properties using a window variable.
local props_var = 'scrollview_props'

-- Stores registered sign specifications.
-- WARN: There is an assumption in the code that signs specs cannot be
-- unregistered. For example, the ID is currently the position in this array.
local sign_specs = {}

-- Maps sign groups to state (enabled or disabled).
local sign_group_state = {}

local mousemove = t('<mousemove>')

-- Track whether there has been a <mousemove> occurrence. Hover highlights are
-- only used if this has been set to true. Without this, the bar would be
-- highlighted when being dragged even if the client doesn't support
-- <mousemove> (e.g., nvim-qt), and may retain the wrong highlight after
-- dragging completes if the mouse is still over the bar.
-- WARN: It's possible that Neovim is opened, with the mouse exactly where it
-- needs to be for a user to start dragging without first moving the mouse. In
-- that case, hover highlights should be used, but won't be. This scenario is
-- unlikely.
local mousemove_received = false

-- *************************************************
-- * Core
-- *************************************************

local is_mouse_over_scrollview_win = function(winid)
  -- WARN: This doesn't consider that there could be other floating windows
  -- with higher z-index than that of 'winid' in the same position as the
  -- mouse. This function would consider the mouse to be hovering both windows.
  -- WARN: We use the positioning from the scrollview props. This is so that
  -- clicking when hovering retains the hover highlight for scrollview windows
  -- when their parent winnr > 1. Otherwise, it appeared getwininfo,
  -- nvim_win_get_posiiton, and win_screenpos were not returning accurate info
  -- (may relate to Neovim #24078). Perhaps it's because the windows were just
  -- created and not yet in the necessary state. #100
  local mousepos = fn.getmousepos()
  local props = api.nvim_win_get_var(winid, props_var)
  local parent_pos = fn.win_screenpos(props.parent_winid)
  local winrow = props.row + parent_pos[1] - 1
  local wincol = props.col + parent_pos[2] - 1
  return mousepos.screenrow >= winrow
    and mousepos.screenrow < winrow + props.height
    and mousepos.screencol >= wincol
    and mousepos.screencol < wincol + props.width
end

-- Return window height, subtracting 1 if there is a winbar.
local get_window_height = function(winid)
  if winid == 0 then
    winid = api.nvim_get_current_win()
  end
  local height = api.nvim_win_get_height(winid)
  if to_bool(tbl_get(fn.getwininfo(winid)[1], 'winbar', 0)) then
    height = height - 1
  end
  return height
end

-- Set window option.
local set_window_option = function(winid, key, value)
  -- Convert to Vim format (e.g., 1 instead of Lua true).
  if value == true then
    value = 1
  elseif value == false then
    value = 0
  end
  -- setwinvar(..., '&...', ...) is used in place of nvim_win_set_option
  -- to avoid Neovim Issues #15529 and #15531, where the global window option
  -- is set in addition to the window-local option, when using Neovim's API or
  -- Lua interface.
  fn.setwinvar(winid, '&' .. key, value)
end

-- Return the base window ID for the specified window. Assumes that windows
-- have been properly marked with win_workspace_base_winid_var.
local get_base_winid = function(winid)
  local base_winid = winid
  pcall(function()
    -- Loop until reaching a window with no base winid specified.
    while true do
      base_winid = api.nvim_win_get_var(
        base_winid, win_workspace_base_winid_var)
    end
  end)
  return base_winid
end

-- Creates a temporary floating window that can be used for computations
-- ---corresponding to the specified window---that require temporary cursor
-- movements (e.g., counting virtual lines, where all lines in a closed fold
-- are counted as a single line). This can be used instead of working in the
-- actual window, to prevent unintended side-effects that arise from moving the
-- cursor in the actual window, even when autocmd's are disabled with
-- eventignore=all and the cursor is restored (e.g., Issue #18: window
-- flickering when resizing with the mouse, Issue #19: cursorbind/scrollbind
-- out-of-sync).
local with_win_workspace = function(winid, fun)
  -- Make the target window active, so that its folds are inherited by the
  -- created floating window (this is necessary when there are multiple windows
  -- that have the same buffer, each window having different folds).
  local workspace_winid = api.nvim_win_call(winid, function()
    local bufnr = api.nvim_win_get_buf(winid)
    return api.nvim_open_win(bufnr, false, {
      relative = 'editor',
      focusable = false,
      width = math.max(1, api.nvim_win_get_width(winid)),
      -- The floating window doesn't inherit a winbar. Use the winbar-omitted
      -- height where applicable.
      height = math.max(1, get_window_height(winid)),
      row = 0,
      col = 0
    })
  end)
  -- Disable scrollbind and cursorbind on the workspace window so that diff
  -- mode and other functionality that utilizes binding (e.g., :Gdiff, :Gblame)
  -- can function properly.
  set_window_option(workspace_winid, 'scrollbind', false)
  set_window_option(workspace_winid, 'cursorbind', false)
  api.nvim_win_set_var(workspace_winid, win_workspace_base_winid_var, winid)
  -- As a precautionary measure, make sure the floating window has no winbar,
  -- which is assumed above.
  if to_bool(fn.exists('+winbar')) then
    set_window_option(workspace_winid, 'winbar', '')
  end
  -- Don't include the workspace window in a diff session. If included, closing
  -- it could end the diff session (e.g., when there is one other window in the
  -- session). Issue #57.
  set_window_option(workspace_winid, 'diff', false)
  local success, result = pcall(function()
    return api.nvim_win_call(workspace_winid, fun)
  end)
  api.nvim_win_close(workspace_winid, true)
  if not success then error(result) end
  return result
end

local is_visual_mode = function(mode)
  return vim.tbl_contains({'v', 'V', t'<c-v>'}, mode)
end

local is_select_mode = function(mode)
  return vim.tbl_contains({'s', 'S', t'<c-s>'}, mode)
end

-- Returns true for ordinary windows (not floating and not external), and false
-- otherwise.
local is_ordinary_window = function(winid)
  local config = api.nvim_win_get_config(winid)
  local not_external = not tbl_get(config, 'external', false)
  local not_floating = tbl_get(config, 'relative', '') == ''
  return not_external and not_floating
end

-- Returns a list of window IDs for the ordinary windows.
local get_ordinary_windows = function()
  local winids = {}
  for winnr = 1, fn.winnr('$') do
    local winid = fn.win_getid(winnr)
    if is_ordinary_window(winid) then
      table.insert(winids, winid)
    end
  end
  return winids
end

local in_command_line_window = function()
  if fn.win_gettype() == 'command' then return true end
  if fn.mode() == 'c' then return true end
  local bufnr = api.nvim_get_current_buf()
  local buftype = api.nvim_buf_get_option(bufnr, 'buftype')
  local bufname = fn.bufname(bufnr)
  return buftype == 'nofile' and bufname == '[Command Line]'
end

-- Returns the window column where the buffer's text begins. This may be
-- negative due to horizontal scrolling. This may be greater than one due to
-- the sign column and 'number' column.
local buf_text_begins_col = function()
  -- The calculation assumes lines don't wrap, so 'nowrap' is temporarily set.
  local wrap = api.nvim_win_get_option(0, 'wrap')
  set_window_option(0, 'wrap', false)
  local result = fn.wincol() - fn.virtcol('.') + 1
  set_window_option(0, 'wrap', wrap)
  return result
end

-- Returns the window column where the view of the buffer begins. This can be
-- greater than one due to the sign column and 'number' column.
local buf_view_begins_col = function()
  -- The calculation assumes lines don't wrap, so 'nowrap' is temporarily set.
  local wrap = api.nvim_win_get_option(0, 'wrap')
  set_window_option(0, 'wrap', false)
  local result = fn.wincol() - fn.virtcol('.') + fn.winsaveview().leftcol + 1
  set_window_option(0, 'wrap', wrap)
  return result
end

-- Returns the specified variable. There are two optional arguments, for
-- specifying precedence and a default value. Without specifying precedence,
-- highest precedence is given to window variables, then tab page variables,
-- then buffer variables, then global variables. Without specifying a default
-- value, 0 will be used.
local get_variable = function(name, winnr, precedence, default)
  if precedence == nil then precedence = 'wtbg' end
  if default == nil then default = 0 end
  local winid = fn.win_getid(winnr)
  -- WARN: This function was originally using getbufvar(., ''),
  -- getwinvar(., ''), and gettabvar(., ''). For example:
  --   local bufvars = fn.getbufvar(bufnr, '')
  --   if bufvars[name] ~= nil then return bufvars[name] end
  -- However, this was slow when the dictionaries were large (e.g., many items
  -- in the b: dictionary for some NERDTree buffers), which you noticed after
  -- adding signs for marks (in such a case, getbufvar(., '') was called many
  -- times, for each mark sign registration). Switching to nvim_buf_get_var
  -- resolves the issue.
  -- WARN: vim.w, vim.b, and vim.t are avoided to support Neovim 0.5, where
  -- those can only be used for the current window, buffer, and tab (i.e.,
  -- can't index with another ID).
  for idx = 1, #precedence do
    local c = precedence:sub(idx, idx)
    if c == 'w' then
      local success, result = pcall(function()
        return api.nvim_win_get_var(winid, name)
      end)
      if success then return result end
    elseif c == 't' then
      -- The tab number can differ from the tab id (similar to winnr and
      -- winid). For example, if you open Neovim, and create a new tab, it will
      -- have number 2 and ID 2. If you then create another, it will have
      -- number 3 and ID 3. But if you delete tab 2, there will then be a tab
      -- with number 2 and ID 3.
      local tabid = api.nvim_win_call(winid, api.nvim_get_current_tabpage)
      local success, result = pcall(function()
        return api.nvim_tabpage_get_var(tabid, name)
      end)
      if success then return result end
    elseif c == 'b' then
      local bufnr = fn.winbufnr(winnr)
      local success, result = pcall(function()
        return api.nvim_buf_get_var(bufnr, name)
      end)
      if success then return result end
    elseif c == 'g' then
      if vim.g[name] ~= nil then return vim.g[name] end
    else
      error('Unknown variable type ' .. c)
    end
  end
  return default
end

-- Returns a boolean indicating whether a restricted state should be used.
-- The function signature matches s:GetVariable, without the 'name' argument.
local is_restricted = function(winnr, precedence, default)
  local winid = fn.win_getid(winnr)
  local bufnr = api.nvim_win_get_buf(winid)
  local line_count = api.nvim_buf_line_count(bufnr)
  local line_limit
    = get_variable('scrollview_line_limit', winnr, precedence, default)
  if line_limit ~= -1 and line_count > line_limit then
    return true
  end
  local byte_count = api.nvim_win_call(winid, function()
    return fn.line2byte(fn.line('$') + 1) - 1
  end)
  local byte_limit
    = get_variable('scrollview_byte_limit', winnr, precedence, default)
  if byte_limit ~= -1 and byte_count > byte_limit then
    return true
  end
  return false
end

-- Returns the scrollview mode. The function signature matches s:GetVariable,
-- without the 'name' argument.
local scrollview_mode = function(winnr, precedence, default)
  if is_restricted(winnr, precedence, default) then
    return 'simple'
  end
  return get_variable('scrollview_mode', winnr, precedence, default)
end

-- Return top line and bottom line in window. For folds, the top line
-- represents the start of the fold and the bottom line represents the end of
-- the fold.
local line_range = function(winid)
  -- WARN: getwininfo(winid)[1].botline is not properly updated for some
  -- movements (Neovim Issue #13510), so this is implemented as a workaround.
  -- This was originally handled by using an asynchronous context, but this was
  -- not possible for refreshing bars during mouse drags.
  -- Using scrolloff=0 combined with H and L breaks diff mode. Scrolling is not
  -- possible and/or the window scrolls when it shouldn't. Temporarily turning
  -- off scrollbind and cursorbind accommodates, but the following is simpler.
  return unpack(api.nvim_win_call(winid, function()
    local topline = fn.line('w0')
    local botline = fn.line('w$')
    -- line('w$') returns 0 in silent Ex mode, but line('w0') is always greater
    -- than or equal to 1.
    botline = math.max(botline, topline)
    return {topline, botline}
  end))
end

-- Advance the current window cursor to the start of the next virtual span,
-- returning the range of lines jumped over, and a boolean indicating whether
-- that range was in a closed fold. A virtual span is a contiguous range of
-- lines that are either 1) not in a closed fold or 2) in a closed fold. If
-- there is no next virtual span, the cursor is returned to the first line.
local advance_virtual_span = function()
  local start = fn.line('.')
  local foldclosedend = fn.foldclosedend(start)
  if foldclosedend ~= -1 then
    -- The cursor started on a closed fold.
    if foldclosedend == fn.line('$') then
      vim.cmd('keepjumps normal! gg')
    else
      vim.cmd('keepjumps normal! j')
    end
    return start, foldclosedend, true
  end
  local lnum = start
  while true do
    vim.cmd('keepjumps normal! zj')
    if lnum == fn.line('.') then
      -- There are no more folds after the cursor. This is the last span.
      vim.cmd('keepjumps normal! gg')
      return start, fn.line('$'), false
    end
    lnum = fn.line('.')
    local foldclosed = fn.foldclosed(lnum)
    if foldclosed ~= -1 then
      -- The cursor moved to a closed fold. The preceding line ends the prior
      -- virtual span.
      return start, lnum - 1, false
    end
  end
end

-- Returns a boolean indicating whether the count of folds (closed folds count
-- as a single fold) between the specified start and end lines exceeds 'n', in
-- the current window. The cursor may be moved.
local fold_count_exceeds = function(start, end_, n)
  vim.cmd('keepjumps normal! ' .. start .. 'G')
  if fn.foldclosed(start) ~= -1 then
    n = n - 1
  end
  if n < 0 then
    return true
  end
  -- Navigate down n folds.
  if n > 0 then
    vim.cmd('keepjumps normal! ' .. n .. 'zj')
  end
  local line1 = fn.line('.')
  -- The fold count exceeds n if there is another fold to navigate to on a line
  -- less than end_.
  vim.cmd('keepjumps normal! zj')
  local line2 = fn.line('.')
  return line2 > line1 and line2 <= end_
end

-- Returns the count of virtual lines between the specified start and end lines
-- (both inclusive), in the current window. A closed fold counts as one virtual
-- line. The computation loops over virtual spans. The cursor may be moved.
local virtual_line_count_spanwise = function(start, end_)
  start = math.max(1, start)
  end_ = math.min(fn.line('$'), end_)
  local count = 0
  if end_ >= start then
    vim.cmd('keepjumps normal! ' .. start .. 'G')
    while true do
      local range_start, range_end, fold = advance_virtual_span()
      range_end = math.min(range_end, end_)
      local delta = 1
      if not fold then
        delta = range_end - range_start + 1
      end
      count = count + delta
      if range_end == end_ or fn.line('.') == 1 then
        break
      end
    end
  end
  return count
end

-- Returns the count of virtual lines between the specified start and end lines
-- (both inclusive), in the current window. A closed fold counts as one virtual
-- line. The computation loops over lines. The cursor is not moved.
local virtual_line_count_linewise = function(start, end_)
  local count = 0
  local line = start
  while line <= end_ do
    count = count + 1
    local foldclosedend = fn.foldclosedend(line)
    if foldclosedend ~= -1 then
      line = foldclosedend
    end
    line = line + 1
  end
  return count
end

-- Returns the count of virtual lines between the specified start and end lines
-- (both inclusive), in the specified window. A closed fold counts as one
-- virtual line. The computation loops over either lines or virtual spans, so
-- the cursor may be moved.
local virtual_line_count = function(winid, start, end_)
  local last_line = api.nvim_buf_line_count(api.nvim_win_get_buf(winid))
  if type(end_) == 'string' and end_ == '$' then
    end_ = last_line
  end
  local base_winid = get_base_winid(winid)
  local memoize_key =
    table.concat({'virtual_line_count', base_winid, start, end_}, ':')
  if memoize and cache[memoize_key] then return cache[memoize_key] end
  local count = with_win_workspace(winid, function()
    -- On an AMD Ryzen 7 2700X, linewise computation takes about 3e-7 seconds
    -- per line (this is an overestimate, as it assumes all folds are open, but
    -- the time is reduced when there are closed folds, as lines would be
    -- skipped). Spanwise computation takes about 5e-5 seconds per fold (closed
    -- folds count as a single fold). Therefore the linewise computation is
    -- worthwhile when the number of folds is greater than (3e-7 / 5e-5) * L =
    -- .006L, where L is the number of lines.
    if fold_count_exceeds(start, end_, math.floor(last_line * .006)) then
      return virtual_line_count_linewise(start, end_)
    else
      return virtual_line_count_spanwise(start, end_)
    end
  end)
  if memoize then cache[memoize_key] = count end
  return count
end

local calculate_scrollbar_height = function(winnr)
  local winid = fn.win_getid(winnr)
  local bufnr = api.nvim_win_get_buf(winid)
  local winheight = get_window_height(winid)
  local line_count = api.nvim_buf_line_count(bufnr)
  local effective_line_count = line_count
  local mode = scrollview_mode(winnr)
  if mode ~= 'simple' then
    -- For virtual mode or an unknown mode, update effective_line_count to
    -- correspond to virtual lines, which account for closed folds.
    effective_line_count = virtual_line_count(winid, 1, '$')
  end
  if to_bool(vim.g.scrollview_include_end_region) then
    effective_line_count = effective_line_count + winheight - 1
  end
  local height = winheight / effective_line_count
  height = math.ceil(height * winheight)
  height = math.max(1, height)
  return height
end

-- Returns an array that maps window rows to the topline that corresponds to a
-- scrollbar at that row under virtual scrollview mode, in the current window.
-- The computation loops over virtual spans. The cursor may be moved.
local virtual_topline_lookup_spanwise = function()
  local winnr = fn.winnr()
  local target_topline_count = get_window_height(0)
  if to_bool(vim.g.scrollview_include_end_region) then
    local scrollbar_height = calculate_scrollbar_height(winnr)
    target_topline_count = target_topline_count - scrollbar_height + 1
  end
  local result = {}  -- A list of line numbers
  local winid = api.nvim_get_current_win()
  local total_vlines = virtual_line_count(winid, 1, '$')
  if total_vlines > 1 and target_topline_count > 1 then
    local line = 0
    local virtual_line = 0
    local prop = 0.0
    local row = 1
    local proportion = (row - 1) / (target_topline_count - 1)
    vim.cmd('keepjumps normal! gg')
    while #result < target_topline_count do
      local range_start, range_end, fold = advance_virtual_span()
      local line_delta = range_end - range_start + 1
      local virtual_line_delta = 1
      if not fold then
        virtual_line_delta = line_delta
      end
      local prop_delta = virtual_line_delta / (total_vlines - 1)
      while prop + prop_delta >= proportion and #result < target_topline_count do
        local ratio = (proportion - prop) / prop_delta
        local topline = line + 1
        if fold then
          -- If ratio >= 0.5, add all lines in the fold, otherwise don't add
          -- the fold.
          if ratio >= 0.5 then
            topline = topline + line_delta
          end
        else
          topline = topline + round(ratio * line_delta)
        end
        table.insert(result, topline)
        row = row + 1
        proportion = (row - 1) / (target_topline_count - 1)
      end
      -- A line number of 1 indicates that advance_virtual_span looped back to
      -- the beginning of the document.
      local looped = fn.line('.') == 1
      if looped or #result >= target_topline_count then
        break
      end
      line = line + line_delta
      virtual_line = virtual_line + virtual_line_delta
      prop = virtual_line / (total_vlines - 1)
    end
  end
  while #result < target_topline_count do
    table.insert(result, fn.line('$'))
  end
  for idx, line in ipairs(result) do
    line = math.max(1, line)
    line = math.min(fn.line('$'), line)
    local foldclosed = fn.foldclosed(line)
    if foldclosed ~= -1 then
      line = foldclosed
    end
    result[idx] = line
  end
  return result
end

-- Returns an array that maps window rows to the topline that corresponds to a
-- scrollbar at that row under virtual scrollview mode, in the current window.
-- The computation primarily loops over lines, but may loop over virtual spans
-- as part of calling 'virtual_line_count', so the cursor may be moved.
local virtual_topline_lookup_linewise = function()
  local winnr = fn.winnr()
  local target_topline_count = get_window_height(0)
  if to_bool(vim.g.scrollview_include_end_region) then
    local scrollbar_height = calculate_scrollbar_height(winnr)
    target_topline_count = target_topline_count - scrollbar_height + 1
  end
  local last_line = fn.line('$')
  local result = {}  -- A list of line numbers
  local winid = api.nvim_get_current_win()
  local total_vlines = virtual_line_count(winid, 1, '$')
  if total_vlines > 1 and target_topline_count > 1 then
    local count = 1  -- The count of virtual lines
    local line = 1
    local best = line
    local best_distance = math.huge
    local best_count = count
    for row = 1, target_topline_count do
      local proportion = (row - 1) / (target_topline_count - 1)
      while line <= last_line do
        local current = (count - 1) / (total_vlines - 1)
        local distance = math.abs(current - proportion)
        if distance <= best_distance then
          best = line
          best_distance = distance
          best_count = count
        elseif distance > best_distance then
          -- Prepare variables so that the next row starts iterating at the
          -- current line and count, using an infinite best distance.
          line = best
          best_distance = math.huge
          count = best_count
          break
        end
        local foldclosedend = fn.foldclosedend(line)
        if foldclosedend ~= -1 then
          line = foldclosedend
        end
        line = line + 1
        count = count + 1
      end
      local value = best
      local foldclosed = fn.foldclosed(value)
      if foldclosed ~= -1 then
        value = foldclosed
      end
      table.insert(result, value)
    end
  end
  while #result < target_topline_count do
    table.insert(result, fn.line('$'))
  end
  return result
end

-- Returns an array that maps window rows to the topline that corresponds to a
-- scrollbar at that row under virtual scrollview mode. The computation loops
-- over either lines or virtual spans, so the cursor may be moved.
local virtual_topline_lookup = function(winid)
  local result = with_win_workspace(winid, function()
    local last_line = api.nvim_buf_line_count(api.nvim_win_get_buf(winid))
    -- On an AMD Ryzen 7 2700X, linewise computation takes about 1.6e-6 seconds
    -- per line (this is an overestimate, as it assumes all folds are open, but
    -- the time is reduced when there are closed folds, as lines would be
    -- skipped). Spanwise computation takes about 6.5e-5 seconds per fold
    -- (closed folds count as a single fold). Therefore the linewise
    -- computation is worthwhile when the number of folds is greater than
    -- (1.6e-6 / 6.5e-5) * L = .0246L, where L is the number of lines.
    if fold_count_exceeds(1, last_line, math.floor(last_line * .0246)) then
      return virtual_topline_lookup_linewise()
    else
      return virtual_topline_lookup_spanwise()
    end
  end)
  return result
end

local simple_topline_lookup = function(winid)
  local winnr = fn.winnr()
  local bufnr = api.nvim_win_get_buf(winid)
  local line_count = api.nvim_buf_line_count(bufnr)
  local target_topline_count = get_window_height(winid)
  if to_bool(vim.g.scrollview_include_end_region) then
    local scrollbar_height = calculate_scrollbar_height(winnr)
    target_topline_count = target_topline_count - scrollbar_height + 1
  end
  local topline_lookup = {}
  for row = 1, target_topline_count do
    local proportion = (row - 1) / (target_topline_count - 1)
    local topline = round(proportion * (line_count - 1)) + 1
    table.insert(topline_lookup, topline)
  end
  return topline_lookup
end

-- Returns an array that maps window rows to the topline that corresponds to a
-- scrollbar at that row.
local topline_lookup = function(winid)
  local winnr = api.nvim_win_get_number(winid)
  local mode = scrollview_mode(winnr)
  local base_winid = get_base_winid(winid)
  local memoize_key =
    table.concat({'topline_lookup', base_winid, mode}, ':')
  if memoize and cache[memoize_key] then return cache[memoize_key] end
  local topline_lookup
  if mode ~= 'simple' then
    -- Handling for virtual mode or an unknown mode.
    topline_lookup = virtual_topline_lookup(winid)
  else
    topline_lookup = simple_topline_lookup(winid)
  end
  if memoize then cache[memoize_key] = topline_lookup end
  return topline_lookup
end

local calculate_scrollbar_column = function(winnr)
  local winid = fn.win_getid(winnr)
  local winwidth = fn.winwidth(winnr)
  -- left is the position for the left of the scrollbar, relative to the
  -- window, and 0-indexed.
  local left = 0
  local column = get_variable('scrollview_column', winnr)
  local base = get_variable('scrollview_base', winnr)
  if base == 'left' then
    left = left + column - 1
  elseif base == 'right' then
    left = left + winwidth - column
  elseif base == 'buffer' then
    local btbc = api.nvim_win_call(winid, buf_text_begins_col)
    left = left + column - 1 + btbc - 1
  else
    -- For an unknown base, use the default position (right edge of window).
    left = left + winwidth - 1
  end
  return left + 1
end

-- Calculates the bar position for the specified window. Returns a dictionary
-- with a height, row, and col. Uses 1-indexing.
local calculate_position = function(winnr)
  local winid = fn.win_getid(winnr)
  local bufnr = api.nvim_win_get_buf(winid)
  local topline, _ = line_range(winid)
  local the_topline_lookup = topline_lookup(winid)
  -- top is the position for the top of the scrollbar, relative to the window.
  local top = binary_search(the_topline_lookup, topline)
  top = math.min(top, #the_topline_lookup)
  if top > 1 and the_topline_lookup[top] > topline then
    top = top - 1  -- use the preceding line from topline lookup.
  end
  local winheight = get_window_height(winid)
  local height = calculate_scrollbar_height(winnr)
  if not to_bool(vim.g.scrollview_include_end_region) then
    -- Make sure bar properly reflects bottom of document.
    local _, botline = line_range(winid)
    local line_count = api.nvim_buf_line_count(bufnr)
    if botline == line_count then
      top = math.max(top, winheight - height + 1)
    end
  end
  local result = {
    height = height,
    row = top,
    col = calculate_scrollbar_column(winnr)
  }
  return result
end

local is_scrollview_window = function(winid)
  if is_ordinary_window(winid) then return false end
  local has_attr = false
  pcall(function()
    has_attr = api.nvim_win_get_var(winid, win_var) == win_val
  end)
  if not has_attr then return false end
  local bufnr = api.nvim_win_get_buf(winid)
  return bufnr == bar_bufnr or bufnr == sign_bufnr
end

-- Returns the position of window edges, with borders considered part of the
-- window.
local get_window_edges = function(winid)
  local top, left = unpack(fn.win_screenpos(winid))
  local bottom = top + get_window_height(winid) - 1
  local right = left + fn.winwidth(winid) - 1
  -- Only edges have to be checked to determine if a border is present (i.e.,
  -- corners don't have to be checked). Borders don't impact the top and left
  -- positions calculated above; only the bottom and right positions.
  local border = api.nvim_win_get_config(winid).border
  if border ~= nil and vim.tbl_islist(border) and #border == 8 then
    if border[2] ~= '' then
      -- There is a top border.
      bottom = bottom + 1
    end
    if border[4] ~= '' then
      -- There is a right border.
      right = right + 1
    end
    if border[6] ~= '' then
      -- There is a bottom border.
      bottom = bottom + 1
    end
    if border[8] ~= '' then
      -- There is a left border.
      right = right + 1
    end
  end
  return top, bottom, left, right
end

-- Return the floating windows that overlap the region corresponding to the
-- specified edges.
local get_float_overlaps = function(top, bottom, left, right)
  local result = {}
  for winnr = 1, fn.winnr('$') do
    local winid = fn.win_getid(winnr)
    local config = api.nvim_win_get_config(winid)
    local floating = tbl_get(config, 'relative', '') ~= ''
    if floating and not is_scrollview_window(winid) then
      local top2, bottom2, left2, right2 = get_window_edges(winid)
      if top <= bottom2
          and bottom >= top2
          and left <= right2
          and right >= left2 then
        table.insert(result, winid)
      end
    end
  end
  return result
end

-- Whether scrollbar and signs should be shown. This is the first check; it
-- only checks for conditions that apply to both the position bar and signs.
local should_show = function(winid)
  local winnr = api.nvim_win_get_number(winid)
  local bufnr = api.nvim_win_get_buf(winid)
  local buf_filetype = api.nvim_buf_get_option(bufnr, 'filetype')
  local winheight = get_window_height(winid)
  local winwidth = fn.winwidth(winnr)
  local wininfo = fn.getwininfo(winid)[1]
  -- Skip if the filetype is on the list of exclusions.
  local excluded_filetypes = get_variable('scrollview_excluded_filetypes', winnr)
  if vim.tbl_contains(excluded_filetypes, buf_filetype) then
    return false
  end
  -- Don't show in terminal mode, since the bar won't be properly updated for
  -- insertions.
  if to_bool(wininfo.terminal) then
    return false
  end
  if winheight == 0 or winwidth == 0 then
    return false
  end
  local always_show = to_bool(get_variable('scrollview_always_show', winnr))
  if not always_show then
    -- Don't show when all lines are on screen.
    local topline, botline = line_range(winid)
    local line_count = api.nvim_buf_line_count(bufnr)
    if botline - topline + 1 == line_count then
      return false
    end
  end
  return true
end

-- Indicates whether the column is valid for showing a scrollbar or signs.
local is_valid_column = function(winid, col, width)
  local winnr = api.nvim_win_get_number(winid)
  local winwidth = fn.winwidth(winnr)
  local min_valid_col = 1
  local max_valid_col = winwidth - width + 1
  local base = get_variable('scrollview_base', winnr)
  if base == 'buffer' then
    min_valid_col = api.nvim_win_call(winid, buf_view_begins_col)
  end
  if col < min_valid_col then
    return false
  end
  if col > max_valid_col then
    return false
  end
  return true
end

-- Returns true if 'cterm' has a 'reverse' attribute for the specified
-- highlight group, or false otherwise. Checks 'gui' instead of 'cterm' if a
-- GUI is running.
local is_hl_reversed = function(group)
  local items
  while true do
    local highlight = fn.execute('highlight ' .. group)
    items = fn.split(highlight)
    table.remove(items, 1)  -- Remove the group name
    table.remove(items, 1)  -- Remove "xxx"
    if items[1] == 'links' and items[2] == 'to' then
      group = items[3]
    else
      break
    end
  end
  if items[1] ~= 'cleared' then
    for _, item in ipairs(items) do
      local key, val = unpack(vim.split(item, '='))
      local gui = fn.has('gui_running')
      if (not gui and key == 'cterm')
          or (gui and key == 'gui') then
        local attrs = vim.split(val, ',')
        for _, attr in ipairs(attrs) do
          if attr == 'reverse' or attr == 'inverse' then
            return true
          end
        end
      end
    end
  end
  return false
end

-- Show a scrollbar for the specified 'winid' window ID, using the specified
-- 'bar_winid' floating window ID (a new floating window will be created if
-- this is -1). Returns -1 if the bar is not shown, and the floating window ID
-- otherwise.
local show_scrollbar = function(winid, bar_winid)
  local winnr = api.nvim_win_get_number(winid)
  local wininfo = fn.getwininfo(winid)[1]
  local bar_position = calculate_position(winnr)
  if not to_bool(get_variable('scrollview_out_of_bounds', winnr)) then
    local winwidth = fn.winwidth(winnr)
    bar_position.col = math.max(1, math.min(winwidth, bar_position.col))
  end
  local bar_width = 1
  if not is_valid_column(winid, bar_position.col, bar_width) then
    return -1
  end
  -- Height has to be positive for the call to nvim_open_win. When opening a
  -- terminal, the topline and botline can be set such that height is negative
  -- when you're using scrollview document mode.
  if bar_position.height <= 0 then
    return -1
  end
  if to_bool(get_variable('scrollview_hide_on_intersect', winnr)) then
    local winrow0 = wininfo.winrow - 1
    local wincol0 = wininfo.wincol - 1
    local float_overlaps = get_float_overlaps(
      winrow0 + bar_position.row,
      winrow0 + bar_position.row + bar_position.height - 1,
      wincol0 + bar_position.col,
      wincol0 + bar_position.col
    )
    if not vim.tbl_isempty(float_overlaps) then
      return -1
    end
  end
  if bar_bufnr == -1 or not to_bool(fn.bufexists(bar_bufnr)) then
    bar_bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_option(bar_bufnr, 'modifiable', false)
    api.nvim_buf_set_option(bar_bufnr, 'filetype', 'scrollview')
    api.nvim_buf_set_option(bar_bufnr, 'buftype', 'nofile')
    api.nvim_buf_set_option(bar_bufnr, 'swapfile', false)
    api.nvim_buf_set_option(bar_bufnr, 'bufhidden', 'hide')
    api.nvim_buf_set_option(bar_bufnr, 'buflisted', false)
  end
  -- Make sure that a custom character is up-to-date and is repeated enough to
  -- cover the full height of the scrollbar.
  local bar_line_count = api.nvim_buf_line_count(bar_bufnr)
  if api.nvim_buf_get_lines(bar_bufnr, 0, 1, false)[1] ~= vim.g.scrollview_character
      or bar_position.height > bar_line_count then
    api.nvim_buf_set_option(bar_bufnr, 'modifiable', true)
    api.nvim_buf_set_lines(
      bar_bufnr, 0, bar_line_count, false,
      fn['repeat']({vim.g.scrollview_character}, bar_position.height))
    api.nvim_buf_set_option(bar_bufnr, 'modifiable', false)
  end
  local zindex = get_variable('scrollview_zindex', winnr)
  -- When there is a winbar, nvim_open_win with relative=win considers row 0 to
  -- be the line below the winbar.
  local max_height = get_window_height(winid) - bar_position.row + 1
  local height = math.min(bar_position.height, max_height)
  local config = {
    win = winid,
    relative = 'win',
    focusable = false,
    style = 'minimal',
    height = height,
    width = bar_width,
    row = bar_position.row - 1,
    col = bar_position.col - 1,
    zindex = zindex
  }
  if bar_winid == -1 then
    bar_winid = api.nvim_open_win(bar_bufnr, false, config)
  else
    api.nvim_win_set_config(bar_winid, config)
  end
  -- Scroll to top so that the custom character spans full scrollbar height.
  vim.cmd('keepjumps call nvim_win_set_cursor(' .. bar_winid .. ', [1, 0])')
  local highlight_fn = function(hover)
    hover = hover and get_variable('scrollview_hover', winnr)
    local group
    if hover then
      group = 'ScrollViewHover'
    else
      group = 'ScrollView'
      if is_restricted(api.nvim_win_get_number(winid)) then
        group = group .. 'Restricted'
      end
    end
    -- It's not sufficient to just specify Normal highlighting. With just that, a
    -- color scheme's specification of EndOfBuffer would be used to color the
    -- bottom of the scrollbar.
    local winhighlight = string.format('Normal:%s,EndOfBuffer:%s', group, group)
    set_window_option(bar_winid, 'winhighlight', winhighlight)
    -- Add a workaround for Neovim #24159.
    if is_hl_reversed(group) then
      set_window_option(bar_winid, 'winblend', '0')
    end
  end
  local winblend = get_variable('scrollview_winblend', winnr)
  set_window_option(bar_winid, 'winblend', winblend)
  set_window_option(bar_winid, 'foldcolumn', '0')  -- foldcolumn takes a string
  set_window_option(bar_winid, 'foldenable', false)
  set_window_option(bar_winid, 'wrap', false)
  api.nvim_win_set_var(bar_winid, win_var, win_val)
  local props = {
    col = bar_position.col,
    -- Save bar_position.height in addition to the actual height, since the
    -- latter may be reduced for the bar to fit in the window.
    full_height = bar_position.height,
    height = height,
    parent_winid = winid,
    row = bar_position.row,
    scrollview_winid = bar_winid,
    type = bar_type,
    width = bar_width,
    zindex = zindex,
  }
  if to_bool(fn.has('nvim-0.7')) then
    -- Neovim 0.7 required to later avoid "Cannot convert given lua type".
    props.highlight_fn = highlight_fn
  end
  api.nvim_win_set_var(bar_winid, props_var, props)
  local hover = mousemove_received
    and to_bool(fn.exists('&mousemoveevent'))
    and vim.o.mousemoveevent
    and is_mouse_over_scrollview_win(bar_winid)
  highlight_fn(hover)
  return bar_winid
end

-- Show signs for the specified 'winid' window ID. A list of existing sign
-- winids, 'sign_winids', is specified for possible reuse. Reused windows are
-- removed from the list.
local show_signs = function(winid, sign_winids)
  -- Neovim 0.8 has an issue with matchaddpos highlighting (similar type of
  -- issue reported in Neovim #22906).
  if not to_bool(fn.has('nvim-0.9')) then return end
  local cur_winid = api.nvim_get_current_win()
  local winnr = api.nvim_win_get_number(winid)
  local wininfo = fn.getwininfo(winid)[1]
  if is_restricted(winnr) then return end
  local bufnr = api.nvim_win_get_buf(winid)
  local line_count = api.nvim_buf_line_count(bufnr)
  local the_topline_lookup = nil  -- only set when needed
  local base_col = calculate_scrollbar_column(winnr)
  base_col = base_col + get_variable('scrollview_signs_column', winnr)
  -- lookup maps rows to a mapping of names to sign specifications (with lines).
  local lookup = {}
  for _, sign_spec in ipairs(sign_specs) do
    local name = sign_spec.name
    local lines = {}
    local lines_as_given = {}
    pcall(function()
      if sign_spec.type == 'b' then
        lines_as_given = api.nvim_buf_get_var(bufnr, name)
      elseif sign_spec.type == 'w' then
        lines_as_given = api.nvim_win_get_var(winid, name)
      end
    end)
    local satisfied_current_only = true
    if sign_spec.current_only then
      satisfied_current_only = winid == cur_winid
    end
    local show = sign_group_state[sign_spec.group] and satisfied_current_only
    if show then
      local lines_to_show = sorted(lines_as_given)
      local show_in_folds
        = to_bool(get_variable('scrollview_signs_show_in_folds', winnr))
      if sign_spec.show_in_folds ~= nil then
        show_in_folds = sign_spec.show_in_folds
      end
      if not show_in_folds then
        lines_to_show = api.nvim_win_call(winid, function()
          local result = {}
          for _, line in ipairs(lines_to_show) do
            if fn.foldclosed(line) == -1 then
              table.insert(result, line)
            end
          end
          return result
        end)
      end
      for _, line in ipairs(lines_to_show) do
        if vim.tbl_isempty(lines) or lines[#lines] ~= line then
          table.insert(lines, line)
        end
      end
    end
    if not vim.tbl_isempty(lines) and the_topline_lookup == nil then
      the_topline_lookup = topline_lookup(winid)
    end
    for _, line in ipairs(lines) do
      if line >= 1 and line <= line_count then
        local row = binary_search(the_topline_lookup, line)
        row = math.min(row, #the_topline_lookup)
        if row > 1 and the_topline_lookup[row] > line then
          row = row - 1  -- use the preceding line from topline lookup.
        end
        if lookup[row] == nil then
          lookup[row] = {}
        end
        if lookup[row][name] == nil then
          local properties = {
            symbol = sign_spec.symbol,
            highlight = sign_spec.highlight,
            priority = sign_spec.priority,
            sign_spec_id = sign_spec.id,
          }
          properties.name = name
          properties.lines = {line}
          lookup[row][name] = properties
        else
          table.insert(lookup[row][name].lines, line)
        end
      end
    end
  end
  for row, props_lookup in pairs(lookup) do
    local props_list = {}
    for _, properties in pairs(props_lookup) do
      for _, field in ipairs({'priority', 'symbol', 'highlight'}) do
        if #properties.lines > #properties[field] then
          properties[field] = properties[field][#properties[field]]
        else
          properties[field] = properties[field][#properties.lines]
        end
      end
      table.insert(props_list, properties)
    end
    -- Sort descending by priority.
    table.sort(props_list, function(a, b)
      return a.priority > b.priority
    end)
    local max_signs_per_row = get_variable('scrollview_signs_max_per_row', winnr)
    if max_signs_per_row >= 0 then
      props_list = vim.list_slice(props_list, 1, max_signs_per_row)
    end
    -- A set of 'row,col' pairs to prevent creating multiple signs in the same
    -- location.
    local shown = {}
    local total_width = 0  -- running sum of sign widths
    for _, properties in ipairs(props_list) do
      local symbol = properties.symbol
      symbol = symbol:gsub('\n', '')
      symbol = symbol:gsub('\r', '')
      if #symbol < 1 then symbol = ' ' end
      local sign_width = fn.strdisplaywidth(symbol)
      local col = base_col
      if get_variable('scrollview_signs_overflow', winnr) == 'left' then
        col = col - total_width
        col = col - sign_width + 1
      else
        col = col + total_width
      end
      total_width = total_width + sign_width
      if to_bool(get_variable('scrollview_out_of_bounds_adjust', winnr)) then
        local winwidth = fn.winwidth(winnr)
        col = math.max(1, math.min(winwidth - sign_width + 1, col))
      end
      local show = is_valid_column(winid, col, sign_width)
        and not shown[row .. ',' .. col]
      if to_bool(get_variable('scrollview_hide_on_intersect', winnr))
          and show then
        local winrow0 = wininfo.winrow - 1
        local wincol0 = wininfo.wincol - 1
        local float_overlaps = get_float_overlaps(
          winrow0 + row,
          winrow0 + row,
          wincol0 + col,
          wincol0 + col + sign_width - 1
        )
        show = vim.tbl_isempty(float_overlaps)
      end
      if show then
        shown[row .. ',' .. col] = true
        if sign_bufnr == -1 or not to_bool(fn.bufexists(sign_bufnr)) then
          sign_bufnr = api.nvim_create_buf(false, true)
          api.nvim_buf_set_option(sign_bufnr, 'modifiable', false)
          api.nvim_buf_set_option(sign_bufnr, 'filetype', 'scrollview_sign')
          api.nvim_buf_set_option(sign_bufnr, 'buftype', 'nofile')
          api.nvim_buf_set_option(sign_bufnr, 'swapfile', false)
          api.nvim_buf_set_option(sign_bufnr, 'bufhidden', 'hide')
          api.nvim_buf_set_option(sign_bufnr, 'buflisted', false)
        end
        local sign_line_count = api.nvim_buf_line_count(sign_bufnr)
        api.nvim_buf_set_option(sign_bufnr, 'modifiable', true)
        api.nvim_buf_set_lines(
          sign_bufnr,
          sign_line_count - 1,
          sign_line_count - 1,
          false,
          {symbol}
        )
        api.nvim_buf_set_option(sign_bufnr, 'modifiable', false)
        local sign_winid
        local zindex = get_variable('scrollview_signs_zindex', winnr)
        local config = {
          win = winid,
          relative = 'win',
          focusable = false,
          style = 'minimal',
          height = 1,
          width = sign_width,
          row = row - 1,
          col = col - 1,
          zindex = zindex,
        }
        if vim.tbl_isempty(sign_winids) then
          sign_winid = api.nvim_open_win(sign_bufnr, false, config)
        else
          sign_winid = table.remove(sign_winids)
          api.nvim_win_set_config(sign_winid, config)
        end
        local highlight_fn = function(hover)
          hover = hover and get_variable('scrollview_hover', winnr)
          local highlight
          if hover then
            highlight = 'ScrollViewHover'
          else
            highlight = properties.highlight
          end
          if highlight ~= nil then
            api.nvim_win_call(sign_winid, function()
              fn.matchaddpos(highlight, {sign_line_count})
            end)
            -- Add a workaround for Neovim #24159.
            if is_hl_reversed(highlight) then
              set_window_option(sign_winid, 'winblend', '0')
            end
          end
        end
        -- Scroll to the inserted line.
        local args = sign_winid .. ', [' .. sign_line_count .. ', 0]'
        vim.cmd('keepjumps call nvim_win_set_cursor(' .. args .. ')')
        local winhighlight = 'Normal:Normal'
        set_window_option(sign_winid, 'winhighlight', winhighlight)
        local winblend = get_variable('scrollview_winblend', winnr)
        set_window_option(sign_winid, 'winblend', winblend)
        -- foldcolumn takes a string
        set_window_option(sign_winid, 'foldcolumn', '0')
        set_window_option(sign_winid, 'foldenable', false)
        set_window_option(sign_winid, 'wrap', false)
        api.nvim_win_set_var(sign_winid, win_var, win_val)
        local props = {
          col = col,
          height = 1,
          lines = properties.lines,
          parent_winid = winid,
          row = row,
          scrollview_winid = sign_winid,
          sign_spec_id = properties.sign_spec_id,
          type = sign_type,
          width = sign_width,
          zindex = zindex,
        }
        if to_bool(fn.has('nvim-0.7')) then
          -- Neovim 0.7 required to later avoid "Cannot convert given lua type".
          props.highlight_fn = highlight_fn
        end
        api.nvim_win_set_var(sign_winid, props_var, props)
        local hover = mousemove_received
          and to_bool(fn.exists('&mousemoveevent'))
          and vim.o.mousemoveevent
          and is_mouse_over_scrollview_win(sign_winid)
        highlight_fn(hover)
      end
    end
  end
end

-- Given a scrollbar properties dictionary and a target window row, the
-- corresponding scrollbar is moved to that row.
-- Where applicable, the height is adjusted if it would extend past the screen.
-- The row is adjusted (up in
-- value, down in visual position) such that the full height of the scrollbar
-- remains on screen. Returns the updated scrollbar properties.
local move_scrollbar = function(props, row)
  props = copy(props)
  local max_height = get_window_height(props.parent_winid) - row + 1
  local height = math.min(props.full_height, max_height)
  local options = {
    win = props.parent_winid,
    relative = 'win',
    row = row - 1,
    col = props.col - 1,
    height = height,
  }
  api.nvim_win_set_config(props.scrollview_winid, options)
  props.row = row
  props.height = height
  api.nvim_win_set_var(props.scrollview_winid, props_var, props)
  return props
end

local get_scrollview_windows = function()
  local result = {}
  for winnr = 1, fn.winnr('$') do
    local winid = fn.win_getid(winnr)
    if is_scrollview_window(winid) then
      table.insert(result, winid)
    end
  end
  return result
end

local close_scrollview_window = function(winid)
  -- The floating window may have been closed (e.g., :only/<ctrl-w>o, or
  -- intentionally deleted prior to the removal callback in order to reduce
  -- motion blur).
  if not api.nvim_win_is_valid(winid) then
    return
  end
  if not is_scrollview_window(winid) then
    return
  end
  vim.cmd('silent! noautocmd call nvim_win_close(' .. winid .. ', 1)')
end

-- Sets global state that is assumed by the core functionality and returns a
-- state that can be used for restoration.
local init = function()
  local eventignore = api.nvim_get_option('eventignore')
  api.nvim_set_option('eventignore', 'all')
  local state = {
    initial_winid = fn.win_getid(fn.winnr()),
    belloff = api.nvim_get_option('belloff'),
    eventignore = eventignore,
    mode = fn.mode(),
  }
  -- Disable the bell (e.g., for invalid cursor movements, trying to navigate
  -- to a next fold, when no fold exists).
  api.nvim_set_option('belloff', 'all')
  if is_select_mode(state.mode) then
    -- Temporarily switch from select-mode to visual-mode, so that 'normal!'
    -- commands can be executed properly.
    vim.cmd('normal! ' .. t'<c-g>')
  end
  return state
end

local restore = function(state)
  local current_winid = fn.win_getid(fn.winnr())
  -- Switch back to select mode where applicable.
  if current_winid == state.initial_winid then
    if is_select_mode(state.mode) then
      if is_visual_mode(fn.mode()) then
        vim.cmd('normal! ' .. t'<c-g>')
      else  -- luacheck: ignore 542 (an empty if branch)
        -- WARN: this scenario should not arise, and is not handled.
      end
    end
  end
  -- 'set title' when 'title' is on, so it's properly set. #84
  if api.nvim_get_option('title') then
    api.nvim_set_option('title', true)
  end
  api.nvim_set_option('eventignore', state.eventignore)
  api.nvim_set_option('belloff', state.belloff)
end

-- Get input characters---including mouse clicks and drags---from the input
-- stream. Characters are read until the input stream is empty. Returns a
-- 2-tuple with a string representation of the characters, along with a list of
-- dictionaries that include the following fields:
--   1) char
--   2) str_idx
--   3) charmod
--   4) mouse_winid
--   5) mouse_row
--   6) mouse_col
-- The mouse values are 0 when there was no mouse event or getmousepos is not
-- available. The mouse_winid is set to -1 when a mouse event was on the
-- command line. The mouse_winid is set to -2 when a mouse event was on the
-- tabline.
local read_input_stream = function()
  local chars = {}
  local chars_props = {}
  local str_idx = 1  -- in bytes, 1-indexed
  while true do
    local char
    if not pcall(function()
      char = fn.getchar()
    end) then
      -- E.g., <c-c>
      char = t'<esc>'
    end
    -- For Vim on Cygwin, pressing <c-c> during getchar() does not raise
    -- "Vim:Interrupt". Handling for such a scenario is added here as a
    -- precaution, by converting to <esc>.
    if char == t'<c-c>' then
      char = t'<esc>'
    end
    local charmod = fn.getcharmod()
    if type(char) == 'number' then
      char = tostring(char)
    end
    table.insert(chars, char)
    local mouse_winid = 0
    local mouse_row = 0
    local mouse_col = 0
    -- Check v:mouse_winid to see if there was a mouse event. Even for clicks
    -- on the command line, where getmousepos().winid could be zero,
    -- v:mousewinid is non-zero.
    if vim.v.mouse_winid ~= 0 and to_bool(fn.exists('*getmousepos')) then
      mouse_winid = vim.v.mouse_winid
      local mousepos = fn.getmousepos()
      mouse_row = mousepos.winrow
      mouse_col = mousepos.wincol
      -- Handle a mouse event on the command line.
      if mousepos.screenrow > vim.go.lines - vim.go.cmdheight then
        mouse_winid = -1
        mouse_row = mousepos.screenrow - vim.go.lines + vim.go.cmdheight
        mouse_col = mousepos.screencol
      end
      -- Handle a mouse event on the tabline. When the click is on a floating
      -- window covering the tabline, mousepos.winid will be set to that
      -- floating window's winid. Otherwise, mousepos.winid would correspond to
      -- an ordinary window ID (seemingly for the window below the tabline).
      if fn.win_screenpos(1) == {2, 1}  -- Checks for presence of a tabline.
          and mousepos.screenrow == 1
          and is_ordinary_window(mousepos.winid) then
        mouse_winid = -2
        mouse_row = mousepos.screenrow
        mouse_col = mousepos.screencol
      end
      -- Handle mouse events when there is a winbar.
      if mouse_winid > 0
          and to_bool(tbl_get(fn.getwininfo(mouse_winid)[1], 'winbar', 0)) then
        mouse_row = mouse_row - 1
      end
    end
    local char_props = {
      char = char,
      str_idx = str_idx,
      charmod = charmod,
      mouse_winid = mouse_winid,
      mouse_row = mouse_row,
      mouse_col = mouse_col
    }
    str_idx = str_idx + string.len(char)
    table.insert(chars_props, char_props)
    -- Break if there are no more items on the input stream.
    if fn.getchar(1) == 0 then
      break
    end
  end
  local string = table.concat(chars, '')
  local result = {string, chars_props}
  return unpack(result)
end

-- Scrolls the window so that the specified line number is at the top.
local set_topline = function(winid, linenr)
  -- WARN: Unlike other functions that move the cursor (e.g., VirtualLineCount,
  -- VirtualProportionLine), a window workspace should not be used, as the
  -- cursor and viewport changes here are intended to persist.
  api.nvim_win_call(winid, function()
    local init_line = fn.line('.')
    vim.cmd('keepjumps normal! ' .. linenr .. 'G')
    local topline, _ = line_range(winid)
    -- Use virtual lines to figure out how much to scroll up. winline() doesn't
    -- accommodate wrapped lines.
    local virtual_line = virtual_line_count(winid, topline, fn.line('.'))
    if virtual_line > 1 then
      vim.cmd('keepjumps normal! ' .. (virtual_line - 1) .. t'<c-e>')
    end
    -- Make sure 'topline' is not incorrect, as a precaution.
    topline = nil  -- luacheck: no unused
    -- Position the cursor as if all scrolling was conducted with <ctrl-e>
    -- and/or <ctrl-y>. H and L are used to get topline and botline instead of
    -- getwininfo, to prevent jumping to a line that could result in a scroll if
    -- scrolloff>0.
    vim.cmd('keepjumps normal! H')
    local effective_top = fn.line('.')
    vim.cmd('keepjumps normal! L')
    local effective_bottom = fn.line('.')
    if init_line < effective_top then
      -- User scrolled down.
      vim.cmd('keepjumps normal! H')
    elseif init_line > effective_bottom then
      -- User scrolled up.
      vim.cmd('keepjumps normal! L')
    else
      -- The initial line is still on-screen.
      vim.cmd('keepjumps normal! ' .. init_line .. 'G')
    end
  end)
end

-- Returns scrollview bar properties for the specified window. An empty
-- dictionary is returned if there is no corresponding scrollbar.
local get_scrollview_bar_props = function(winid)
  for _, scrollview_winid in ipairs(get_scrollview_windows()) do
    local props = api.nvim_win_get_var(scrollview_winid, props_var)
    if props.type == bar_type and props.parent_winid == winid then
      return props
    end
  end
  return {}
end

-- Returns a list of scrollview sign properties for the specified scrollbar
-- window. An empty list is returned if there are no signs.
local get_scrollview_sign_props = function(winid)
  local result = {}
  for _, scrollview_winid in ipairs(get_scrollview_windows()) do
    local props = api.nvim_win_get_var(scrollview_winid, props_var)
    if props.type == sign_type and props.parent_winid == winid then
      table.insert(result, props)
    end
  end
  return result
end

-- With no argument, remove all bars. Otherwise, remove the specified list of
-- bars. Global state is initialized and restored.
local remove_bars = function(target_wins)
  if target_wins == nil then target_wins = get_scrollview_windows() end
  if bar_bufnr == -1 and sign_bufnr == -1 then return end
  local state = init()
  pcall(function()
    for _, winid in ipairs(target_wins) do
      close_scrollview_window(winid)
    end
  end)
  restore(state)
end

-- Remove scrollbars if InCommandLineWindow is true. This fails when called
-- from the CmdwinEnter event (some functionality, like nvim_win_close, cannot
-- be used from the command line window), but works during the transition to
-- the command line window (from the WinEnter event).
local remove_if_command_line_window = function()
  if in_command_line_window() then
    pcall(remove_bars)
  end
end

-- Refreshes scrollbars. There is an optional argument that specifies whether
-- removing existing scrollbars is asynchronous (defaults to true). Global
-- state is initialized and restored.
local refresh_bars = function()
  vim.g.scrollview_refreshing = true
  local state = init()
  local resume_memoize = memoize
  start_memoize()
  -- Use a pcall block, so that unanticipated errors don't interfere. The
  -- worst case scenario is that bars won't be shown properly, which was
  -- deemed preferable to an obscure error message that can be interrupting.
  pcall(function()
    if in_command_line_window() then return end
    -- Don't refresh when the current window shows a scrollview buffer. This
    -- could cause a loop where TextChanged keeps firing.
    for _, scrollview_bufnr in ipairs({sign_bufnr, bar_bufnr}) do
      if scrollview_bufnr ~= -1 and to_bool(fn.bufexists(scrollview_bufnr)) then
        local windows = fn.getbufinfo(scrollview_bufnr)[1].windows
        if vim.tbl_contains(windows, fn.win_getid(fn.winnr())) then
          return
        end
      end
    end
    -- Existing windows are determined before adding new windows, but removed
    -- later (they have to be removed after adding to prevent flickering from
    -- the delay between removal and adding).
    local existing_barids = {}
    local existing_signids = {}
    for _, winid in ipairs(get_scrollview_windows()) do
      local props = api.nvim_win_get_var(winid, props_var)
      if props.type == bar_type then
        table.insert(existing_barids, winid)
      elseif props.type == sign_type then
        table.insert(existing_signids, winid)
      end
    end
    local target_wins = {}
    if to_bool(get_variable('scrollview_current_only', fn.winnr(), 'tg')) then
      table.insert(target_wins, api.nvim_get_current_win())
    else
      for _, winid in ipairs(get_ordinary_windows()) do
        table.insert(target_wins, winid)
      end
    end
    local eventignore = api.nvim_get_option('eventignore')
    api.nvim_set_option('eventignore', state.eventignore)
    vim.cmd('doautocmd <nomodeline> User ScrollViewRefresh')
    api.nvim_set_option('eventignore', eventignore)
    -- Delete all signs and highlights in the sign buffer.
    if sign_bufnr ~= -1 and to_bool(fn.bufexists(sign_bufnr)) then
      api.nvim_buf_set_option(sign_bufnr, 'modifiable', true)
      -- Don't use fn.deletebufline to avoid the "--No lines in buffer--"
      -- message that shows when the buffer is empty.
      api.nvim_buf_set_lines(
        sign_bufnr, 0, api.nvim_buf_line_count(sign_bufnr), true, {})
      api.nvim_buf_set_option(sign_bufnr, 'modifiable', false)
    end
    for _, winid in ipairs(target_wins) do
      if should_show(winid) then
        local existing_winid = -1
        if not vim.tbl_isempty(existing_barids) then
          -- Reuse an existing scrollbar floating window when available. This
          -- prevents flickering when there are folds. This keeps the window IDs
          -- smaller than they would be otherwise. The benefits of small window
          -- IDs seems relatively less beneficial than small buffer numbers,
          -- since they would ordinarily be used less as inputs to commands
          -- (where smaller numbers are preferable for their fewer digits to
          -- type).
          existing_winid = existing_barids[#existing_barids]
        end
        local bar_winid = show_scrollbar(winid, existing_winid)
        -- If an existing window was successfully reused, remove it from the
        -- existing window list.
        if bar_winid ~= -1 and existing_winid ~= -1 then
          table.remove(existing_barids)
        end
        -- Repeat a similar process for signs.
        show_signs(winid, existing_signids)
      end
    end
    local existing_wins = concat(existing_barids, existing_signids)
    if vim.tbl_isempty(existing_wins) then  -- luacheck: ignore 542 (empty if)
      -- Do nothing. The following clauses are only applicable when there are
      -- existing windows. Skipping prevents the creation of an unnecessary
      -- timer.
    else
      for _, winid in ipairs(existing_wins) do
        close_scrollview_window(winid)
      end
    end
  end)
  if not resume_memoize then
    stop_memoize()
    reset_memoize()
  end
  restore(state)
  vim.g.scrollview_refreshing = false
end

-- This function refreshes the bars asynchronously. This works better than
-- updating synchronously in various scenarios where updating occurs in an
-- intermediate state of the editor (e.g., when closing a command-line window),
-- which can result in bars being placed where they shouldn't be.
-- WARN: For debugging, it's helpful to use synchronous refreshing, so that
-- e.g., echom works as expected.
local refresh_bars_async = function()
  pending_async_refresh_count = pending_async_refresh_count + 1
  -- Use defer_fn twice so that refreshing happens after other processing. #59.
  vim.defer_fn(function()
    vim.defer_fn(function()
      pending_async_refresh_count = math.max(0, pending_async_refresh_count - 1)
      if pending_async_refresh_count > 0 then
        -- If there are asynchronous refreshes that will occur subsequently,
        -- don't execute this one.
        return
      end
      -- ScrollView may have already been disabled by time this callback
      -- executes asynchronously.
      if scrollview_enabled then
        refresh_bars()
      end
    end, 0)
  end, 0)
end

if vim.on_key ~= nil
    and to_bool(fn.exists('&mousemoveevent')) then
  vim.on_key(function(str)
    if vim.o.mousemoveevent and string.find(str, mousemove) then
      mousemove_received = true
      for _, winid in ipairs(get_scrollview_windows()) do
        local props = api.nvim_win_get_var(winid, props_var)
        if not vim.tbl_isempty(props) and props.highlight_fn ~= nil then
          props.highlight_fn(is_mouse_over_scrollview_win(winid))
        end
      end
    end
  end)
end

-- *************************************************
-- * Main (entry points)
-- *************************************************

-- INFO: Asynchronous refreshing was originally used to work around issues
-- (e.g., getwininfo(winid)[1].botline not updated yet in a synchronous
-- context). However, it's now primarily utilized because it makes the UI more
-- responsive and it permits redundant refreshes to be dropped (e.g., for mouse
-- wheel scrolling).

local enable = function()
  scrollview_enabled = true
  vim.cmd([[
    augroup scrollview
      autocmd!
      " === Scrollbar Removal ===

      " For the duration of command-line window usage, there should be no bars.
      " Without this, bars can possibly overlap the command line window. This
      " can be problematic particularly when there is a vertical split with the
      " left window's bar on the bottom of the screen, where it would overlap
      " with the center of the command line window. It was not possible to use
      " CmdwinEnter, since the removal has to occur prior to that event. Rather,
      " this is triggered by the WinEnter event, just prior to the relevant
      " funcionality becoming unavailable.
      autocmd WinEnter * :lua require('scrollview').remove_if_command_line_window()

      " The following error can arise when the last window in a tab is going to
      " be closed, but there are still open floating windows, and at least one
      " other tab.
      "   > "E5601: Cannot close window, only floating window would remain"
      " Neovim Issue #11440 is open to address this. As of 2020/12/12, this
      " issue is a 0.6 milestone.
      " The autocmd below removes bars subsequent to :quit, :wq, or :qall (and
      " also ZZ and ZQ), to avoid the error. However, the error will still arise
      " when <ctrl-w>c or :close are used. To avoid the error in those cases,
      " <ctrl-w>o can be used to first close the floating windows, or
      " alternatively :tabclose can be used (or one of the alternatives handled
      " with the autocmd, like ZQ).
      autocmd QuitPre * :lua require('scrollview').remove_bars()

      " === Scrollbar Refreshing ===

      " The following handles bar refreshing when changing the current window.
      autocmd WinEnter,TermEnter * :lua require('scrollview').refresh_bars_async()

      " The following restores bars after leaving the command-line window.
      " Refreshing must be asynchronous, since the command line window is still
      " in an intermediate state when the CmdwinLeave event is triggered.
      autocmd CmdwinLeave * :lua require('scrollview').refresh_bars_async()

      " The following handles scrolling events, which could arise from various
      " actions, including resizing windows, movements (e.g., j, k), or
      " scrolling (e.g., <ctrl-e>, zz).
      autocmd WinScrolled * :lua require('scrollview').refresh_bars_async()

      " The following handles window resizes that don't trigger WinScrolled
      " (e.g., leaving the command line window). This was added in Neovim 0.9,
      " so its presence needs to be tested.
      if exists('##WinResized')
        autocmd WinResized * :lua require('scrollview').refresh_bars_async()
      endif

      " The following handles the case where text is pasted. TextChangedI is not
      " necessary since WinScrolled will be triggered if there is corresponding
      " scrolling.
      autocmd TextChanged * :lua require('scrollview').refresh_bars_async()

      " The following handles when :e is used to load a file. The asynchronous
      " version handles a case where :e is used to reload an existing file, that
      " is already scrolled. This avoids a scenario where the scrollbar is
      " refreshed while the window is an intermediate state, resulting in the
      " scrollbar moving to the top of the window.
      autocmd BufWinEnter * :lua require('scrollview').refresh_bars_async()

      " The following is used so that bars are shown when cycling through tabs.
      autocmd TabEnter * :lua require('scrollview').refresh_bars_async()

      autocmd VimResized * :lua require('scrollview').refresh_bars_async()

      " Scrollbar positions can become stale after adding or removing winbars.
      autocmd OptionSet winbar :lua require('scrollview').refresh_bars_async()
    augroup END
  ]])
  -- The initial refresh is asynchronous, since :ScrollViewEnable can be used
  -- in a context where Neovim is in an intermediate state. For example, for
  -- ':bdelete | ScrollViewEnable', with synchronous processing, the 'topline'
  -- and 'botline' in getwininfo's results correspond to the existing buffer
  -- that :bdelete was called on.
  refresh_bars_async()
end

local disable = function()
  local winid = api.nvim_get_current_win()
  local state = init()
  pcall(function()
    if in_command_line_window() then
      vim.cmd([[
        echohl ErrorMsg
        echo 'nvim-scrollview: Cannot disable from command-line window'
        echohl None
      ]])
      return
    end
    scrollview_enabled = false
    vim.cmd([[
      augroup scrollview
        autocmd!
      augroup END
    ]])
    -- Remove scrollbars from all tabs.
    for _, tabnr in ipairs(api.nvim_list_tabpages()) do
      api.nvim_set_current_tabpage(tabnr)
      pcall(remove_bars)
    end
  end)
  api.nvim_set_current_win(winid)
  restore(state)
end

-- With no argument, toggles the current state. Otherwise, true enables and
-- false disables.
-- WARN: 'state' is enable/disable state. This differs from how "state" is used
-- in other parts of the code (for saving and restoring environment).
local set_state = function(state)
  if state == vim.NIL then
    state = nil
  end
  if state == nil then
    state = not scrollview_enabled
  end
  if state then
    enable()
  else
    disable()
  end
end

local refresh = function()
  if scrollview_enabled then
    -- This refresh is asynchronous to keep interactions responsive (e.g.,
    -- mouse wheel scrolling, as redundant async refreshes are dropped). If
    -- scenarios necessitate synchronous refreshes, the interface would have to
    -- be updated (e.g., :ScrollViewRefresh --sync) to accommodate (as there is
    -- currently only a single refresh command and a single refresh <plug>
    -- mapping, both utilizing whatever is implemented here).
    refresh_bars_async()
  end
end

-- Move the cursor to the specified line with a sign. Can take (1) an integer
-- value, (2) '$' for the last line, (3) 'next' for the next line, or (4)
-- 'prev' for the previous line. 'groups' specifies the sign groups that are
-- considered; use nil for all. 'args' is a dictionary with optional arguments.
local move_to_sign_line = function(location, groups, args)
  if groups ~= nil then
    groups = utils.sorted(groups)
  end
  if args == nil then
    args = {}
  end
  local lines = {}
  local winid = api.nvim_get_current_win()
  for _, sign_props in ipairs(get_scrollview_sign_props(winid)) do
    local eligible = groups == nil
    if not eligible then
      local group = sign_specs[sign_props.sign_spec_id].group
      local idx = utils.binary_search(groups, group)
      eligible = idx <= #groups and groups[idx] == group
    end
    if eligible then
      for _, line in ipairs(sign_props.lines) do
        table.insert(lines, line)
      end
    end
  end
  if vim.tbl_isempty(lines) then
    return
  end
  table.sort(lines)
  lines = remove_duplicates(lines)
  local current = fn.line('.')
  local target = nil
  if location == 'next' then
    local count = args.count or 1
    target = subsequent(lines, current, count, vim.o.wrapscan)
  elseif location == 'prev' then
    local count = args.count or 1
    target = preceding(lines, current, count, vim.o.wrapscan)
  elseif location == '$' then
    target = lines[#lines]
  elseif type(location) == 'number' then
    target = lines[location]
  end
  if target ~= nil then
    vim.cmd('normal!' .. target .. 'G')
  end
end

-- Move the cursor to the next line that has a sign.
local next = function(groups, count)  -- luacheck: ignore 431 (shadowing upvalue next)
  move_to_sign_line('next', groups, {count = count})
end

-- Move the cursor to the previous line that has a sign.
local prev = function(groups, count)
  move_to_sign_line('prev', groups, {count = count})
end

-- Move the cursor to the first line with a sign.
local first = function(groups)
  move_to_sign_line(1, groups)
end

-- Move the cursor to the last line with a sign.
local last = function(groups)
  move_to_sign_line('$', groups)
end

-- 'button' can be 'left', 'middle', 'right', 'x1', or 'x2'.
local handle_mouse = function(button)
  if not vim.tbl_contains({'left', 'middle', 'right', 'x1', 'x2'}, button) then
    error('Unsupported button: ' .. button)
  end
  local mousedown = t('<' .. button .. 'mouse>')
  local mouseup = t('<' .. button .. 'release>')
  if not scrollview_enabled then
    -- nvim-scrollview is disabled. Process the click as it would ordinarily be
    -- processed, by re-sending the click and returning.
    fn.feedkeys(mousedown, 'ni')
    return
  end
  local state = init()
  local resume_memoize = memoize
  start_memoize()
  pcall(function()
    -- Re-send the click, so its position can be obtained through
    -- read_input_stream().
    fn.feedkeys(mousedown, 'ni')
    -- Mouse handling is not relevant in the command line window since
    -- scrollbars are not shown. Additionally, the overlay cannot be closed
    -- from that mode.
    if in_command_line_window() then
      return
    end
    local count = 0
    local winid  -- The target window ID for a mouse scroll.
    local scrollbar_offset
    local previous_row
    local idx = 1
    local string, chars_props = '', {}
    local str_idx, char, mouse_winid, mouse_row, mouse_col
    local props
    -- Computing this prior to the first mouse event could distort the location
    -- since this could be an expensive operation (and the mouse could move).
    local the_topline_lookup = nil
    while true do
      while true do
        idx = idx + 1
        if idx > #chars_props then
          idx = 1
          string, chars_props = read_input_stream()
        end
        local char_props = chars_props[idx]
        str_idx = char_props.str_idx
        char = char_props.char
        mouse_winid = char_props.mouse_winid
        mouse_row = char_props.mouse_row
        mouse_col = char_props.mouse_col
        -- Break unless it's a mouse drag followed by another mouse drag, so
        -- that the first drag is skipped.
        if mouse_winid == 0
            or vim.tbl_contains({mousedown, mouseup}, char) then
          break
        end
        if idx >= #char_props then break end
        local next_char_props = chars_props[idx + 1]
        if next_char_props.mouse_winid == 0
            or vim.tbl_contains({mousedown, mouseup}, next_char_props.char) then
          break
        end
      end
      if char == t'<esc>' then
        fn.feedkeys(string.sub(string, str_idx + #char), 'ni')
        return
      end
      -- In select-mode, mouse usage results in the mode intermediately
      -- switching to visual mode, accompanied by a call to this function.
      -- After the initial mouse event, the next getchar() character is
      -- <80><f5>X. This is "Used for switching Select mode back on after a
      -- mapping or menu" (https://github.com/vim/vim/blob/
      -- c54f347d63bcca97ead673d01ac6b59914bb04e5/src/keymap.h#L84-L88,
      -- https://github.com/vim/vim/blob/
      -- c54f347d63bcca97ead673d01ac6b59914bb04e5/src/getchar.c#L2660-L2672)
      -- Ignore this character after scrolling has started.
      -- NOTE: "\x80\xf5X" (hex) ==# "\200\365X" (octal)
      if char ~= '\x80\xf5X' or count == 0 then
        if mouse_winid == 0 then
          -- There was no mouse event.
          fn.feedkeys(string.sub(string, str_idx), 'ni')
          return
        end
        if char == mouseup then
          if count == 0 then
            -- No initial mousedown was captured.
            fn.feedkeys(string.sub(string, str_idx), 'ni')
          elseif count == 1 then
            -- A scrollbar was clicked, but there was no corresponding drag.
            -- Allow the interaction to be processed as it would be with no
            -- scrollbar.
            fn.feedkeys(mousedown .. string.sub(string, str_idx), 'ni')
          else
            -- A scrollbar was clicked and there was a corresponding drag.
            -- 'feedkeys' is not called, since the full mouse interaction has
            -- already been processed. The current window (from prior to
            -- scrolling) is not changed.
            -- Refresh scrollbars to handle the scenario where
            -- scrollview_hide_on_intersect is enabled and dragging resulted in
            -- a scrollbar overlapping a floating window.
            refresh_bars()
          end
          return
        end
        if count == 0 then
          if mouse_winid < 0 then
            -- The mouse event was on the tabline or command line.
            fn.feedkeys(string.sub(string, str_idx), 'ni')
            return
          end
          props = get_scrollview_bar_props(mouse_winid)
          local clicked_bar = false
          if not vim.tbl_isempty(props) then
            clicked_bar = mouse_row >= props.row
              and mouse_row < props.row + props.height
              and mouse_col >= props.col
              and mouse_col <= props.col
          end
          -- First check for a click on a sign and handle accordingly.
          for _, sign_props in ipairs(get_scrollview_sign_props(mouse_winid)) do
            if mouse_row == sign_props.row
              and mouse_col >= sign_props.col
              and mouse_col <= sign_props.col + sign_props.width - 1
              and (not clicked_bar or sign_props.zindex > props.zindex) then
              api.nvim_win_call(mouse_winid, function()
                -- Go to the next sign_props line after the cursor.
                local current = fn.line('.')
                local target = subsequent(sign_props.lines, current, 1, true)
                vim.cmd('normal!' .. target .. 'G')
              end)
              refresh_bars()
              return
            end
          end
          if not clicked_bar then
            -- There was either no scrollbar in the window where a click
            -- occurred or the click was not on a scrollbar.
            fn.feedkeys(string.sub(string, str_idx), 'ni')
            return
          end
          -- The click was on a scrollbar.
          -- It's possible that the clicked scrollbar is out-of-sync. Refresh
          -- the scrollbars and check if the mouse is still over a scrollbar. If
          -- not, ignore all mouse events until a mouseup. This approach was
          -- deemed preferable to refreshing scrollbars initially, as that could
          -- result in unintended clicking/dragging where there is no scrollbar.
          refresh_bars()
          vim.cmd('redraw')
          props = get_scrollview_bar_props(mouse_winid)
          if vim.tbl_isempty(props)
              or props.type ~= bar_type
              or mouse_row < props.row
              or mouse_row >= props.row + props.height then
            while fn.getchar() ~= mouseup do end
            return
          end
          -- By this point, the click on a scrollbar was successful.
          if is_visual_mode(fn.mode()) then
            -- Exit visual mode.
            vim.cmd('normal! ' .. t'<esc>')
          end
          winid = mouse_winid
          scrollbar_offset = props.row - mouse_row
          previous_row = props.row
        end
        -- Only consider a scrollbar update for mouse events on windows (i.e.,
        -- not on the tabline or command line).
        if mouse_winid > 0 then
          local winheight = get_window_height(winid)
          local mouse_winrow = fn.getwininfo(mouse_winid)[1].winrow
          local winrow = fn.getwininfo(winid)[1].winrow
          local window_offset = mouse_winrow - winrow
          local row = mouse_row + window_offset + scrollbar_offset
          row = math.min(row, winheight)
          row = math.max(1, row)
          if vim.g.scrollview_include_end_region then
            -- Don't allow scrollbar to overflow.
            row = math.min(row, winheight - props.height + 1)
          end
          -- Only update scrollbar if the row changed.
          if previous_row ~= row then
            if the_topline_lookup == nil then
              the_topline_lookup = topline_lookup(winid)
            end
            local topline = the_topline_lookup[row]
            topline = math.max(1, topline)
            if row == 1 then
              -- If the scrollbar was dragged to the top of the window, always
              -- show the first line.
              topline = 1
            end
            set_topline(winid, topline)
            if api.nvim_win_get_option(winid, 'scrollbind')
                or api.nvim_win_get_option(winid, 'cursorbind') then
              refresh_bars()
              props = get_scrollview_bar_props(winid)
            end
            props = move_scrollbar(props, row)
            vim.cmd('redraw')
            previous_row = row
          end
        end
        count = count + 1
      end  -- end if
    end  -- end while
  end)  -- end pcall
  if not resume_memoize then
    stop_memoize()
    reset_memoize()
  end
  restore(state)
end

-- A convenience function for setting global options with
-- require('scrollview').setup().
local setup = function(opts)
  opts = opts or {}
  for key, val in pairs(opts) do
    api.nvim_set_var('scrollview_' .. key, val)
  end
end

local register_sign_spec = function(specification)
  local id = #sign_specs + 1
  specification = copy(specification)
  specification.id = id
  local defaults = {
    current_only = false,
    group = 'other',
    highlight = 'Pmenu',
    priority = 50,
    show_in_folds = nil,  -- when set, overrides 'scrollview_signs_show_in_folds'
    symbol = '',  -- effectively ' '
    type = 'b',
  }
  for key, val in pairs(defaults) do
    if specification[key] == nil then
      specification[key] = val
    end
  end
  for _, group in ipairs({'all', 'defaults'}) do
    if specification.group == group then
      error('Invalid group: ' .. group)
    end
  end
  -- Group names can be made up of letters, digits, and underscores, but cannot
  -- start with a digit. This matches the rules for internal variables (:help
  -- internal-variables), but is more restrictive than what is possible with
  -- e.g., nvim_buf_set_var.
  if string.match(specification.group, '^[a-zA-Z_][a-zA-Z0-9_]*$') == nil then
    error('Invalid group: ' .. specification.group)
  end
  local name = 'scrollview_signs_' .. id .. '_' .. specification.group
  specification.name = name
  -- priority, symbol, and highlight can be arrays
  for _, key in ipairs({'priority', 'highlight', 'symbol',}) do
    if type(specification[key]) ~= 'table' then
      specification[key] = {specification[key]}
    else
      specification[key] = copy(specification[key])
    end
  end
  table.insert(sign_specs, specification)
  if sign_group_state[specification.group] == nil then
    sign_group_state[specification.group] = false
  end
  local registration = {
    id = id,
    name = name,
  }
  return registration
end

-- state can be true, false, or nil to toggle.
-- WARN: 'state' is enable/disable state. This differs from how "state" is used
-- in other parts of the code (for saving and restoring environment).
local set_sign_group_state = function(group, state)
  if sign_group_state[group] == nil then
    error('Unknown group: ' .. group)
  end
  if state == vim.NIL then
    state = nil
  end
  local prior_state = sign_group_state[group]
  if state == nil then
    sign_group_state[group] = not sign_group_state[group]
  else
    sign_group_state[group] = state
  end
  if prior_state ~= sign_group_state[group] then
    refresh_bars_async()
  end
end

local get_sign_group_state = function(group)
  local result = sign_group_state[group]
  if result == nil then
    error('Unknown group: ' .. group)
  end
  return result
end

-- Indicates whether scrollview is enabled and the specified sign group is
-- enabled. Using this is more convenient than having to call (1) a
-- (hypothetical) get_state function to check if scrollview is enabled and (2)
-- a get_sign_group_state function to check if the group is enabled.
local is_sign_group_active = function(group)
  return scrollview_enabled and get_sign_group_state(group)
end

local get_sign_groups = function()
  local groups = {}
  for group, _ in pairs(sign_group_state) do
    table.insert(groups, group)
  end
  return groups
end

-- Returns a list of window IDs that could potentially have signs.
local get_sign_eligible_windows = function()
  local winids = {}
  for _, winid in ipairs(get_ordinary_windows()) do
    if should_show(winid) then
      local winnr = api.nvim_win_get_number(winid)
      if not is_restricted(winnr) then
        table.insert(winids, winid)
      end
    end
  end
  return winids
end

-- *************************************************
-- * API
-- *************************************************

return {
  -- Functions called internally (by autocmds).
  refresh_bars_async = refresh_bars_async,
  remove_bars = remove_bars,
  remove_if_command_line_window = remove_if_command_line_window,

  -- Functions called by commands and mappings defined in
  -- plugin/scrollview.vim, and sign handlers.
  first = first,
  fold_count_exceeds = fold_count_exceeds,
  get_sign_eligible_windows = get_sign_eligible_windows,
  handle_mouse = handle_mouse,
  last = last,
  next = next,
  prev = prev,
  refresh = refresh,
  set_state = set_state,
  with_win_workspace = with_win_workspace,

  -- Sign registration/configuration
  get_sign_groups = get_sign_groups,
  is_sign_group_active = is_sign_group_active,
  register_sign_spec = register_sign_spec,
  set_sign_group_state = set_sign_group_state,

  -- Functions called by tests.
  virtual_line_count_spanwise = virtual_line_count_spanwise,
  virtual_line_count_linewise = virtual_line_count_linewise,
  virtual_topline_lookup_spanwise = virtual_topline_lookup_spanwise,
  virtual_topline_lookup_linewise = virtual_topline_lookup_linewise,
  simple_topline_lookup = simple_topline_lookup,

  -- require('scrollview').setup()
  setup = setup,
}
