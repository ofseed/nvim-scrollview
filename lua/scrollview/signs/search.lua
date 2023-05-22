local api = vim.api
local fn = vim.fn
local scrollview = require('scrollview')
local utils = require('scrollview.utils')
local to_bool = utils.to_bool

local M = {}

function M.init(enable)
  if api.nvim_create_autocmd == nil then
    return
  end

  local registration = scrollview.register_sign_spec({
    group = 'search',
    highlight = 'ScrollViewSearch',
    priority = vim.g.scrollview_search_priority,
    symbol = vim.g.scrollview_search_symbol,
  })
  local name = registration.name
  if enable then
    scrollview.set_sign_group_state('search', enable)
  end

  api.nvim_create_autocmd('User', {
    pattern = 'ScrollViewRefresh',
    callback = scrollview.signs_autocmd_callback(function(args)
      local pattern = fn.getreg('/')
      -- Track visited buffers, to prevent duplicate computation when multiple
      -- windows are showing the same buffer.
      local visited = {}
      for _, winid in ipairs(scrollview.get_ordinary_windows()) do
        local bufnr = api.nvim_win_get_buf(winid)
        if not visited[bufnr] then
          local winnr = api.nvim_win_get_number(winid)
          local bufvars = vim.b[bufnr]
          local lines = {}
          if to_bool(vim.v.hlsearch) then
            local cache_hit = false
            local seq_cur = fn.undotree().seq_cur
            if bufvars.scrollview_search_pattern_cached == pattern then
              local cache_seq_cur = bufvars.scrollview_search_seq_cur_cached
              cache_hit = cache_seq_cur == seq_cur
            end
            if cache_hit then
              lines = bufvars.scrollview_search_cached
            else
              lines = scrollview.with_win_workspace(winid, function()
                local result = {}
                local line_count = api.nvim_buf_line_count(0)
                -- Search signs are not shown when the number of buffer lines
                -- exceeds the limit, to prevent a slowdown.
                -- TODO: use a global setting for this instead of get_variable.
                local line_count_limit = scrollview.get_variable(
                  'scrollview_search_buffer_lines_limit', winnr)
                local within_limit = line_count_limit == -1
                  or line_count <= line_count_limit
                -- Use a pcall since searchcount() and :global throw an
                -- exception (E383, E866) when the pattern is invalid (e.g.,
                -- "\@a").
                pcall(function()
                  -- searchcount() can return {} (e.g., when launching Neovim
                  -- with -i NONE).
                  searchcount_total = fn.searchcount().total or 0
                  if within_limit and searchcount_total > 0 then
                    result = fn.split(fn.execute('global//echo line(".")'))
                  end
                end)
                return result
              end)
              for idx, line in ipairs(lines) do
                lines[idx] = tonumber(line)
              end
              bufvars.scrollview_search_pattern_cached = pattern
              bufvars.scrollview_search_seq_cur_cached = seq_cur
              bufvars.scrollview_search_cached = lines
            end
          end
          bufvars[name] = lines
          bufvars.scrollview_search_pattern = pattern
          visited[bufnr] = true
        end
      end
    end)
  })

  api.nvim_create_autocmd('OptionSet', {
    pattern = 'hlsearch',
    callback = scrollview.signs_autocmd_callback(function(args)
      scrollview.refresh()
    end)
  })

  api.nvim_create_autocmd('CmdlineLeave', {
    callback = scrollview.signs_autocmd_callback(function(args)
      if to_bool(vim.v.event.abort) then
        return
      end
      local afile = fn.expand('<afile>')
      -- Handle the case where a search is executed.
      local refresh = afile == '/' or afile == '?'
      -- Handle the case where :nohls may have been executed (this won't work
      -- for e.g., <cmd>nohls<cr> in a mapping).
      -- WARN: CmdlineLeave is not executed for command mappings (<cmd>).
      if afile == ':' and string.find(fn.getcmdline(), 'nohls') then
        refresh = true
      end
      if refresh then
        scrollview.refresh()
      end
    end)
  })

  -- It's possible that <cmd>nohlsearch<cr> was executed from a mapping, and
  -- wouldn't be handled by the CmdlineLeave callback above. Use a CursorMoved
  -- event to check if search signs are shown when they shouldn't be, and
  -- update accordingly. Also handle the case where 'n', 'N', '*', '#', 'g*',
  -- or 'g#' are pressed (although these won't be properly handled when there
  -- is only one search result and the cursor is already on it, since the
  -- cursor wouldn't move; creating scrollview refresh mappings for those keys
  -- could handle that scenario). NOTE: If there are scenarios where search
  -- signs become out of sync (i.e., shown when they shouldn't be), this same
  -- approach could be used with a timer.
  api.nvim_create_autocmd('CursorMoved', {
    callback = scrollview.signs_autocmd_callback(function(args)
      -- Use defer_fn since vim.v.hlsearch may not have been properly set yet.
      vim.defer_fn(function()
        local refresh = false
        if to_bool(vim.v.hlsearch) then
          -- Refresh bars if (1) v:hlsearch is on, (2) search signs aren't
          -- currently shown, and (3) searchcount().total > 0. Also refresh
          -- bars if v:hlsearch is on and the shown search signs correspond to
          -- a different pattern than the current one.
          -- Track visited buffers, to prevent duplicate computation when
          -- multiple windows are showing the same buffer.
          local pattern = fn.getreg('/')
          local visited = {}
          for _, winid in ipairs(scrollview.get_ordinary_windows()) do
            local bufnr = api.nvim_win_get_buf(winid)
            if not visited[bufnr] then
              visited[bufnr] = true
              refresh = api.nvim_win_call(winid, function()
                if pattern ~= vim.b.scrollview_search_pattern then
                  return true
                end
                local lines = vim.b[name]
                if lines == nil or vim.tbl_isempty(lines) then
                  -- Use a pcall since searchcount() throws an exception (E383,
                  -- E866) when the pattern is invalid (e.g., "\@a").
                  local searchcount_total = 0
                  pcall(function()
                    -- searchcount() can return {} (e.g., when launching Neovim
                    -- with -i NONE).
                    searchcount_total = fn.searchcount().total or 0
                  end)
                  if searchcount_total > 0 then
                    return true
                  end
                end
                return false
              end)
              if refresh then
                break
              end
            end
          end
        else
          -- Refresh bars if v:hlsearch is off and search signs are currently
          -- shown.
          for _, winid in ipairs(scrollview.get_ordinary_windows()) do
            local bufnr = api.nvim_win_get_buf(winid)
            local lines = vim.b[bufnr][name]
            if lines ~= nil and not vim.tbl_isempty(lines) then
              refresh = true
              break
            end
          end
        end
        if refresh then
          scrollview.refresh()
        end
      end, 0)
    end)
  })

  -- The InsertEnter case handles when insert mode is entered at the same time
  -- as v:hlsearch is turned off. The InsertLeave case updates search signs
  -- after leaving insert mode, when newly added text might correspond to new
  -- signs.
  api.nvim_create_autocmd({'InsertEnter', 'InsertLeave'}, {
    callback = scrollview.signs_autocmd_callback(function(args)
      scrollview.refresh()
    end)
  })
end

return M
