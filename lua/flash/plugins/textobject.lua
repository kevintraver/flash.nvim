local Config = require("flash.config")
local Pos = require("flash.search.pos")
local Repeat = require("flash.repeat")
local Util = require("flash.util")

local M = {}

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

---@type table<string, {open: string, close: string}>
M.delimiters = {
  ['"'] = { open = '"', close = '"' },
  ["'"] = { open = "'", close = "'" },
  ["`"] = { open = "`", close = "`" },
  ["("] = { open = "(", close = ")" },
  [")"] = { open = "(", close = ")" },
  ["["] = { open = "[", close = "]" },
  ["]"] = { open = "[", close = "]" },
  ["{"] = { open = "{", close = "}" },
  ["}"] = { open = "{", close = "}" },
  ["<"] = { open = "<", close = ">" },
  [">"] = { open = "<", close = ">" },
}

---@type table<string, string[]>
M.aliases = {
  b = { "(", "[", "{" },
  q = { '"', "'", "`" },
}

---@type table<string, boolean>
M.special = {
  t = true, -- HTML/XML tag
}

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

---@class Flash.Match.TextObject: Flash.Match
---@field empty? boolean True if this is an empty inside match (e.g., () or "")
---@field select_pos? Pos Actual selection start (may differ from pos for multi-line)
---@field select_end_pos? Pos Actual selection end (may differ from end_pos for multi-line)
---@field needs_join? boolean True if lines need to be joined after deletion
---@field close_delim_col? number Column of closing delimiter (for needs_join)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Sort matches by position (row, then column)
---@param matches Flash.Match.TextObject[]
local function sort_matches(matches)
  table.sort(matches, function(a, b)
    if a.pos[1] ~= b.pos[1] then
      return a.pos[1] < b.pos[1]
    end
    return a.pos[2] < b.pos[2]
  end)
end

--- Create a deduplication key from positions
---@param pos Pos
---@param end_pos Pos
---@return string
local function make_key(pos, end_pos)
  return string.format("%d:%d-%d:%d", pos[1], pos[2], end_pos[1], end_pos[2])
end

--- Check if content contains an unescaped delimiter (for symmetric delimiters like quotes)
---@param content string
---@param delim string
---@return boolean has_unescaped
local function has_unescaped_delimiter(content, delim)
  local i = 1
  while i <= #content do
    local c = content:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == delim then
      return true
    else
      i = i + 1
    end
  end
  return false
end

--- Convert 1D offset to 2D position within lines
---@param offset number 1-based offset into concatenated lines
---@param lines string[] Lines with \n appended
---@param start_line number Starting line number (1-indexed)
---@return number row, number col (1-indexed row, 0-indexed col)
local function offset_to_pos(offset, lines, start_line)
  local current_offset = 0
  for i, line in ipairs(lines) do
    local line_len = #line
    if current_offset + line_len >= offset then
      return start_line + i - 1, offset - current_offset - 1
    end
    current_offset = current_offset + line_len
  end
  local last_line = lines[#lines] or ""
  return start_line + #lines - 1, #last_line - 1
end

--------------------------------------------------------------------------------
-- Node validation and range calculation
--------------------------------------------------------------------------------

--- Check if a treesitter node represents a valid delimiter pair
---@param buf number
---@param node TSNode
---@param delim {open: string, close: string}
---@return boolean
local function is_valid_delimiter_node(buf, node, delim)
  local start_row, start_col, end_row, end_col = node:range()

  -- Must be at least 2 characters
  if start_row == end_row and end_col - start_col < 2 then
    return false
  end

  local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row + 1, false)
  if #lines == 0 then
    return false
  end

  -- Check boundary characters match delimiters
  local first_char = lines[1]:sub(start_col + 1, start_col + 1)
  local last_char = #lines == 1 and lines[1]:sub(end_col, end_col) or lines[#lines]:sub(end_col, end_col)

  if first_char ~= delim.open or last_char ~= delim.close then
    return false
  end

  -- For symmetric delimiters (quotes), verify no unescaped delimiter inside
  -- This prevents matching spans like: "key": "value"
  if delim.open == delim.close then
    local content
    if #lines == 1 then
      content = lines[1]:sub(start_col + 2, end_col - 1)
    else
      local parts = { lines[1]:sub(start_col + 2) }
      for i = 2, #lines - 1 do
        parts[#parts + 1] = lines[i]
      end
      parts[#parts + 1] = lines[#lines]:sub(1, end_col - 1)
      content = table.concat(parts, "\n")
    end

    if has_unescaped_delimiter(content, delim.open) then
      return false
    end
  end

  return true
end

--- Get range info for "inside" mode
---@param buf number
---@param start_row number
---@param start_col number
---@param end_row number
---@param end_col number
---@return Pos pos, Pos end_pos, boolean is_empty, Pos? select_pos, Pos? select_end_pos, boolean? needs_join, number? close_delim_col
local function get_inside_range(buf, start_row, start_col, end_row, end_col)
  local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row + 1, false)
  local is_multiline = start_row ~= end_row
  local first_line = lines[1] or ""
  local open_at_eol = start_col + 1 >= #first_line
  local close_col = end_col - 1
  local close_at_bol = close_col == 0

  -- Compute label positions (stay on delimiter line if at boundary)
  local pos = open_at_eol and Pos({ start_row + 1, start_col })
    or Pos(Util.offset_pos(buf, { start_row + 1, start_col }, { 0, 1 }))
  local end_pos = close_at_bol and Pos({ end_row + 1, 0 })
    or Pos(Util.offset_pos(buf, { end_row + 1, end_col - 1 }, { 0, -1 }))

  -- Check for empty content
  if not is_multiline and (end_pos[1] < pos[1] or (end_pos[1] == pos[1] and end_pos[2] < pos[2])) then
    return pos, Pos({ pos[1], pos[2] }), true
  end

  -- Handle multi-line special cases
  if is_multiline and #lines > 0 then
    local select_pos, select_end_pos, needs_join, close_delim_col_val

    if open_at_eol then
      select_pos = Pos({ start_row + 2, 0 })
      needs_join = true
      close_delim_col_val = close_col
    end

    if close_at_bol and #lines > 1 then
      local prev_line = lines[#lines - 1]
      select_end_pos = Pos({ end_row, math.max(0, #prev_line - 1) })
    end

    return pos, end_pos, false, select_pos, select_end_pos, needs_join, close_delim_col_val
  end

  return pos, end_pos, false
end

--- Get the selection range for a treesitter node
---@param buf number
---@param node TSNode
---@param around boolean
---@return Pos pos, Pos end_pos, boolean? is_empty, Pos? select_pos, Pos? select_end_pos, boolean? needs_join, number? close_delim_col
local function get_node_range(buf, node, around)
  local start_row, start_col, end_row, end_col = node:range()
  local pos = Pos({ start_row + 1, start_col })
  local end_pos = Pos({ end_row + 1, end_col - 1 })

  if around then
    return pos, end_pos
  end

  return get_inside_range(buf, start_row, start_col, end_row, end_col)
end

--------------------------------------------------------------------------------
-- Match collection
--------------------------------------------------------------------------------

--- Recursively collect matching nodes from treesitter tree
---@param node TSNode
---@param ctx {buf: number, win: number, delim: table, around: boolean, from_row: number, to_row: number, matches: Flash.Match.TextObject[], seen: table<string, boolean>}
local function collect_nodes(node, ctx)
  local start_row, _, end_row, _ = node:range()

  if end_row < ctx.from_row or start_row > ctx.to_row then
    return
  end

  if is_valid_delimiter_node(ctx.buf, node, ctx.delim) then
    local pos, end_pos, is_empty, select_pos, select_end_pos, needs_join, close_delim_col =
      get_node_range(ctx.buf, node, ctx.around)
    local key = make_key(pos, end_pos)

    if not ctx.seen[key] then
      ctx.seen[key] = true
      table.insert(ctx.matches, {
        win = ctx.win,
        pos = pos,
        end_pos = end_pos,
        empty = is_empty or false,
        select_pos = select_pos,
        select_end_pos = select_end_pos,
        needs_join = needs_join or false,
        close_delim_col = close_delim_col,
      })
    end
  end

  for child in node:iter_children() do
    collect_nodes(child, ctx)
  end
end

--- Find delimiter matches using treesitter
---@param win number
---@param delim {open: string, close: string}
---@param around boolean
---@param opts? {from?: Pos, to?: Pos}
---@return Flash.Match.TextObject[]
local function get_delimiter_matches(win, delim, around, opts)
  local buf = vim.api.nvim_win_get_buf(win)
  local info = vim.fn.getwininfo(win)[1]

  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return {}
  end

  opts = opts or {}
  local ctx = {
    buf = buf,
    win = win,
    delim = delim,
    around = around,
    from_row = opts.from and (opts.from[1] - 1) or (info.topline - 1),
    to_row = opts.to and (opts.to[1] - 1) or info.botline,
    matches = {},
    seen = {},
  }

  parser:parse()
  parser:for_each_tree(function(tstree)
    if not tstree then
      return
    end
    local root = tstree:root()
    if not root then
      return
    end

    for node in root:iter_children() do
      collect_nodes(node, ctx)
    end
  end)

  return ctx.matches
end

--- Find HTML/XML tag matches using pattern matching
---@param win number
---@param around boolean
---@param opts? {from?: Pos, to?: Pos}
---@return Flash.Match.TextObject[]
local function get_tag_matches(win, around, opts)
  local buf = vim.api.nvim_win_get_buf(win)
  local info = vim.fn.getwininfo(win)[1]

  opts = opts or {}
  local from_line = opts.from and opts.from[1] or info.topline
  local to_line = opts.to and opts.to[1] or info.botline

  local lines = vim.api.nvim_buf_get_lines(buf, from_line - 1, to_line, false)
  for i, line in ipairs(lines) do
    lines[i] = line .. "\n"
  end
  local text = table.concat(lines, "")

  local matches = {}
  local seen = {}
  local init = 1

  while init <= #text do
    local open_start, open_end, tagname = text:find("<(%w+)[^>]*>", init)
    if not open_start then
      break
    end

    local close_pattern = "</" .. tagname .. ">"
    local close_start, close_end = text:find(close_pattern, open_end + 1, true)

    if close_start then
      local pos_row, pos_col = offset_to_pos(open_start, lines, from_line)
      local end_row, end_col = offset_to_pos(close_end, lines, from_line)
      local key = make_key(Pos({ pos_row, pos_col }), Pos({ end_row, end_col - 1 }))

      if not seen[key] then
        seen[key] = true

        if around then
          table.insert(matches, {
            win = win,
            pos = Pos({ pos_row, pos_col }),
            end_pos = Pos({ end_row, end_col - 1 }),
          })
        else
          local inner_start = open_end + 1
          local inner_end = close_start - 1

          if inner_end >= inner_start then
            local inner_pos_row, inner_pos_col = offset_to_pos(inner_start, lines, from_line)
            local inner_end_row, inner_end_col = offset_to_pos(inner_end, lines, from_line)
            table.insert(matches, {
              win = win,
              pos = Pos({ inner_pos_row, inner_pos_col }),
              end_pos = Pos({ inner_end_row, inner_end_col }),
            })
          else
            local inner_pos_row, inner_pos_col = offset_to_pos(inner_start, lines, from_line)
            table.insert(matches, {
              win = win,
              pos = Pos({ inner_pos_row, inner_pos_col }),
              end_pos = Pos({ inner_pos_row, inner_pos_col }),
              empty = true,
            })
          end
        end
      end
    end

    init = open_start + 1
  end

  return matches
end

--- Collect all matches without sorting
---@param win number
---@param char string
---@param around boolean
---@param opts? {from?: Pos, to?: Pos}
---@return Flash.Match.TextObject[]
local function collect_matches(win, char, around, opts)
  -- Handle aliases: combine matches from multiple delimiter types
  if M.aliases[char] then
    local all_matches = {}
    local seen = {}
    for _, c in ipairs(M.aliases[char]) do
      for _, match in ipairs(collect_matches(win, c, around, opts)) do
        local key = make_key(match.pos, match.end_pos)
        if not seen[key] then
          seen[key] = true
          table.insert(all_matches, match)
        end
      end
    end
    return all_matches
  end

  -- Handle special text objects
  if M.special[char] then
    if char == "t" then
      return get_tag_matches(win, around, opts)
    end
    return {}
  end

  -- Handle regular delimiters
  local delim = M.delimiters[char]
  if not delim then
    return {}
  end

  return get_delimiter_matches(win, delim, around, opts)
end

--------------------------------------------------------------------------------
-- Operations
--------------------------------------------------------------------------------

--- Perform the actual selection/edit action
---@param match Flash.Match.TextObject
local function perform_selection(match)
  vim.api.nvim_set_current_win(match.win)
  local mode = vim.fn.mode(true)
  local is_visual = mode:match("^[vV\x16]")
  local is_op = mode:sub(1, 2) == "no"
  local op = vim.v.operator

  if match.empty then
    -- Empty match: position cursor between delimiters
    vim.api.nvim_win_set_cursor(match.win, { match.pos[1], match.pos[2] })
    if is_op and op == "c" then
      vim.cmd("startinsert")
    end
  elseif match.needs_join then
    -- Multi-line with delimiter at EOL: requires special handling
    if is_visual then
      vim.api.nvim_win_set_cursor(match.win, { match.pos[1], match.pos[2] + 1 })
      vim.cmd("normal! v")
      vim.api.nvim_win_set_cursor(match.win, { match.end_pos[1], match.close_delim_col - 1 })
    elseif is_op and op == "y" then
      local buf = vim.api.nvim_win_get_buf(match.win)
      local lines = vim.api.nvim_buf_get_text(
        buf,
        match.pos[1] - 1,
        match.pos[2] + 1,
        match.end_pos[1] - 1,
        match.close_delim_col,
        {}
      )
      vim.fn.setreg(vim.v.register, table.concat(lines, "\n"))
    else
      local buf = vim.api.nvim_win_get_buf(match.win)
      vim.api.nvim_buf_set_text(
        buf,
        match.pos[1] - 1,
        match.pos[2] + 1,
        match.end_pos[1] - 1,
        match.close_delim_col,
        {}
      )
      vim.api.nvim_win_set_cursor(match.win, { match.pos[1], match.pos[2] + 1 })
      if is_op and op == "c" then
        vim.cmd("startinsert")
      end
    end
  else
    -- Standard jump: handled by Flash's jump mechanism primarily,
    -- but we shouldn't get here because M.jump handles standard jumps via Jump.jump.
    -- This function is only for custom edit logic (empty/needs_join).
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Check if a character is a supported text object
---@param char string
---@return boolean
function M.is_supported(char)
  return M.delimiters[char] ~= nil or M.aliases[char] ~= nil or M.special[char] ~= nil
end

--- Find all text objects of given type in window
---@param win number
---@param char string
---@param around boolean
---@param opts? {from?: Pos, to?: Pos}
---@return Flash.Match.TextObject[]
function M.get_matches(win, char, around, opts)
  local matches = collect_matches(win, char, around, opts)
  sort_matches(matches)
  return matches
end

--- Jump to a text object with Flash
---@param char string
---@param around boolean
---@param opts? Flash.Config
function M.jump(char, around, opts)
  local label_before = around and { 0, -1 } or { 0, 0 }
  local label_after = around and { 0, 1 } or { 0, 0 }

  opts = Config.get({ mode = "textobject" }, opts, {
    matcher = function(win, _, search_opts)
      return M.get_matches(win, char, around, search_opts)
    end,
    action = function(match, state)
      local Jump = require("flash.jump")

      if match.empty or match.needs_join then
        Util.exit()
        vim.schedule(function()
          perform_selection(match)
        end)
        Jump.on_jump(state)
      else
        -- Normal case: use Flash's built-in jump
        local jump_match = match
        if match.select_pos or match.select_end_pos then
          jump_match = vim.tbl_extend("force", {}, match)
          jump_match.pos = match.select_pos or match.pos
          jump_match.end_pos = match.select_end_pos or match.end_pos
        end
        Jump.jump(jump_match, state)
        Jump.on_jump(state)
      end
    end,
    label = {
      before = label_before,
      after = label_after,
      format = function(format_opts)
        -- Skip "after" label if it would overlap with "before"
        if format_opts.after then
          local m = format_opts.match
          if m.pos[1] == m.end_pos[1] and m.end_pos[2] - m.pos[2] <= 1 then
            return {}
          end
        end
        return { { format_opts.match.label, format_opts.hl_group } }
      end,
    },
    search = { multi_window = true, wrap = true, incremental = false, max_length = 0 },
    jump = { pos = "range" },
  })

  local state = Repeat.get_state("textobject", opts)
  state:loop({
    restore = true,
    abort = function()
      Util.exit()
    end,
  })

  return state
end

--- Remote text object selection entry point
---@param opts? Flash.Config & { around?: boolean }
function M.remote(opts)
  opts = opts or {}
  local around = opts.around or false

  local char = vim.fn.getcharstr()
  if not char or char == Util.ESC then
    Util.exit()
    return
  end

  if not M.is_supported(char) then
    vim.notify("Unsupported text object: " .. char .. " (supported: \" ' ` ( ) [ ] { } < > b q t)", vim.log.levels.WARN)
    Util.exit()
    return
  end

  return M.jump(char, around, opts)
end

return M
