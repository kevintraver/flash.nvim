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
  ["`"] = { open = '`', close = '`' },
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
  q = { '"', "'", '`' },
}

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

---@class Flash.Match.TextObject: Flash.Match
---@field empty? boolean True if this is an empty inside match (e.g., () or "")
---@field select_pos? Pos Actual selection start (may differ from pos for multi-line)
---@field select_end_pos? Pos Actual selection end (may differ from end_pos for multi-line)

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
    if c == string.char(92) then
      i = i + 2
    elseif c == delim then
      return true
    else
      i = i + 1
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Node validation and range calculation
--------------------------------------------------------------------------------

--- Check if a node is a valid tag element (e.g. <div>...</div>)
---@param buf number
---@param node TSNode
---@return boolean
local function is_tag_node(buf, node)
  if node:named_child_count() < 1 then
    return false
  end
  local first = node:named_child(0)
  local last = node:named_child(node:named_child_count() - 1)

  -- Check start tag
  local sr, sc, er, ec = first:range()
  local start_lines = vim.api.nvim_buf_get_text(buf, sr, sc, er, ec, {})
  local start_text = table.concat(start_lines, "")
  if not start_text:match("^<[^/]") then
    return false
  end

  -- Check self-closing or end tag
  if first == last then
    return start_text:match("/>$") ~= nil
  end

  local lsr, lsc, ler, lec = last:range()
  local end_lines = vim.api.nvim_buf_get_text(buf, lsr, lsc, ler, lec, {})
  local end_text = table.concat(end_lines, "")

  return end_text:match("^</") and end_text:match(">$")
end

--- Find delimiter positions within a node
--- Handles: child nodes as delimiters, boundary chars, or scanning within text
---@param buf number
---@param node TSNode
---@param delim {open: string, close: string}
---@return {open_row: number, open_col: number, close_row: number, close_col: number}|nil
local function find_delimiter_positions(buf, node, delim)
  local start_row, start_col, end_row, end_col = node:range()

  -- Must be at least 2 characters
  if start_row == end_row and end_col - start_col < 2 then
    return nil
  end

  -- Strategy 1: Look for child nodes that ARE the delimiters
  -- (e.g., in Lua: bracket_index_expression has [ and ] as children)
  local open_node, close_node
  for child in node:iter_children() do
    local child_type = child:type()
    if child_type == delim.open and not open_node then
      open_node = child
    elseif child_type == delim.close then
      close_node = child
    end
  end

  if open_node and close_node then
    local osr, osc, oer, oec = open_node:range()
    local csr, csc, cer, cec = close_node:range()
    return { open_row = osr, open_col = osc, close_row = cer, close_col = cec - 1 }
  end

  -- Strategy 2: Check boundary characters (original approach)
  local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row + 1, false)
  if #lines == 0 then
    return nil
  end

  local first_char = lines[1]:sub(start_col + 1, start_col + 1)
  local last_char = #lines == 1 and lines[1]:sub(end_col, end_col) or lines[#lines]:sub(end_col, end_col)

  if first_char == delim.open and last_char == delim.close then
    return { open_row = start_row, open_col = start_col, close_row = end_row, close_col = end_col - 1 }
  end

  -- Strategy 3: Scan within node text for delimiters (for prefixed strings like f"...")
  -- Only for symmetric delimiters (quotes)
  if delim.open == delim.close then
    local first_line = lines[1]
    local open_col_found = nil

    -- Scan forward for opening delimiter
    for i = start_col + 1, #first_line do
      if first_line:sub(i, i) == delim.open then
        open_col_found = i - 1 -- convert to 0-indexed
        break
      end
    end

    if open_col_found then
      -- Scan backward for closing delimiter
      local last_line = lines[#lines]
      local close_col_found = nil
      local scan_end = #lines == 1 and open_col_found + 1 or 0

      for i = end_col, scan_end + 1, -1 do
        if last_line:sub(i, i) == delim.close then
          close_col_found = i - 1 -- convert to 0-indexed
          break
        end
      end

      if close_col_found and (start_row ~= end_row or close_col_found > open_col_found) then
        return { open_row = start_row, open_col = open_col_found, close_row = end_row, close_col = close_col_found }
      end
    end
  end

  return nil
end

--- Check if a treesitter node represents a valid delimiter pair
---@param buf number
---@param node TSNode
---@param delim {open: string, close: string}
---@return boolean, {open_row: number, open_col: number, close_row: number, close_col: number}|nil
local function is_valid_delimiter_node(buf, node, delim)
  local positions = find_delimiter_positions(buf, node, delim)
  if not positions then
    return false, nil
  end

  -- For symmetric delimiters (quotes), verify no unescaped delimiter inside
  if delim.open == delim.close then
    local lines = vim.api.nvim_buf_get_lines(buf, positions.open_row, positions.close_row + 1, false)
    local content
    if #lines == 1 then
      content = lines[1]:sub(positions.open_col + 2, positions.close_col)
    else
      local parts = { lines[1]:sub(positions.open_col + 2) }
      for i = 2, #lines - 1 do
        parts[#parts + 1] = lines[i]
      end
      parts[#parts + 1] = lines[#lines]:sub(1, positions.close_col)
      content = table.concat(parts, "\n")
    end

    if has_unescaped_delimiter(content, delim.open) then
      return false, nil
    end
  end

  return true, positions
end

--- Check if node matches the requested text object type
---@param buf number
---@param node TSNode
---@param ctx {char: string, delim?: table}
---@return boolean, {open_row: number, open_col: number, close_row: number, close_col: number}|nil
local function is_match_node(buf, node, ctx)
  if ctx.char == "t" then
    return is_tag_node(buf, node), nil
  end
  return is_valid_delimiter_node(buf, node, ctx.delim)
end

--- Calculate range for inside text object (handles multi-line selection logic)
---@param buf number
---@param start_row number (0-indexed)
---@param start_col number (0-indexed)
---@param end_row number (0-indexed)
---@param end_col number (0-indexed, exclusive in TS, but we treat it as bound)
---@return Pos pos, Pos end_pos, boolean is_empty, Pos? select_pos, Pos? select_end_pos
local function get_content_range(buf, start_row, start_col, end_row, end_col)
  local pos = Pos({ start_row + 1, start_col })
  local end_pos
  if end_col == 0 then
    end_pos = Pos({ end_row + 1, 0 })
  else
    end_pos = Pos({ end_row + 1, end_col - 1 })
  end

  local is_multiline = start_row ~= end_row

  -- Check for empty content
  if not is_multiline and (end_pos[1] < pos[1] or (end_pos[1] == pos[1] and end_pos[2] < pos[2])) then
    return pos, Pos({ pos[1], pos[2] }), true
  end

  -- Handle multi-line special cases
  local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row + 1, false)
  if is_multiline and #lines > 0 then
    local select_pos, select_end_pos

    local first_line = lines[1] or ""
    local open_at_eol = start_col >= #first_line

    if open_at_eol then
      -- Content starts on the next line
      select_pos = Pos({ start_row + 2, 0 })
    end

    if end_col == 0 and #lines > 1 then
      -- Closing delimiter is at BOL, content ends on previous line
      local prev_line = lines[#lines - 1]
      select_end_pos = Pos({ end_row, math.max(0, #prev_line - 1) })
    end

    return pos, end_pos, false, select_pos, select_end_pos
  end

  return pos, end_pos, false
end

--- Get range info for "inside" mode (1-char delimiters)
---@param buf number
---@param start_row number
---@param start_col number
---@param end_row number
---@param end_col number
---@return Pos pos, Pos end_pos, boolean is_empty, Pos? select_pos, Pos? select_end_pos
local function get_inside_range(buf, start_row, start_col, end_row, end_col)
  -- For 1-char delimiters, content starts at start_col + 1 and ends at end_col
  -- (end_col is index of closing char)
  local lines = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)
  local open_at_eol = false
  if #lines > 0 then
    open_at_eol = (start_col + 1) >= #lines[1]
  end

  -- We pass start_col + 1 as content start.
  -- If open_at_eol, content start is effectively start of next line, but get_content_range handles EOL check.
  -- get_content_range expects start_col to be the column of content start.
  -- If open_at_eol, start_col+1 is out of bounds of line 1, which get_content_range detects.
  return get_content_range(buf, start_row, start_col + 1, end_row, end_col)
end

--- Get the selection range for a node (tag or delimiter)
---@param buf number
---@param node TSNode
---@param ctx {around: boolean, char: string}
---@param delim_positions? {open_row: number, open_col: number, close_row: number, close_col: number}
---@return Pos pos, Pos end_pos, boolean? is_empty, Pos? select_pos, Pos? select_end_pos
local function get_match_range(buf, node, ctx, delim_positions)
  -- Handle tags (t)
  if ctx.char == "t" then
    local start_node = node:named_child(0)
    local end_node = node:named_child(node:named_child_count() - 1)

    local sr1, sc1, er1, ec1 = start_node:range()
    local sr2, sc2, er2, ec2 = end_node:range()

    if ctx.around then
      -- Around: start of open tag to end of close tag
      return Pos({ sr1 + 1, sc1 }), Pos({ er2 + 1, ec2 - 1 })
    end

    -- Inside
    if start_node == end_node then
      -- Self-closing, empty content
      local pos = Pos({ sr1 + 1, sc1 })
      return pos, pos, true
    end

    -- Content is between end of start_node and start of end_node
    return get_content_range(buf, er1, ec1, sr2, sc2)
  end

  -- Handle standard delimiters - use found positions if available
  local start_row, start_col, end_row, end_col
  if delim_positions then
    start_row = delim_positions.open_row
    start_col = delim_positions.open_col
    end_row = delim_positions.close_row
    end_col = delim_positions.close_col
  else
    -- Fallback to node range
    local nr_start_row, nr_start_col, nr_end_row, nr_end_col = node:range()
    start_row = nr_start_row
    start_col = nr_start_col
    end_row = nr_end_row
    end_col = nr_end_col - 1 -- TS end_col is exclusive
  end

  local pos = Pos({ start_row + 1, start_col })
  local end_pos = Pos({ end_row + 1, end_col })

  if ctx.around then
    return pos, end_pos
  end

  -- For inside: get_inside_range expects end_col to be the column OF the closing delimiter
  return get_inside_range(buf, start_row, start_col, end_row, end_col)
end

--------------------------------------------------------------------------------
-- Match collection
--------------------------------------------------------------------------------

--- Recursively collect matching nodes from treesitter tree
---@param node TSNode
---@param ctx {buf: number, win: number, delim?: table, char: string, around: boolean, from_row: number, to_row: number, matches: Flash.Match.TextObject[], seen: table<string, boolean>}
local function collect_nodes(node, ctx)
  local start_row, _, end_row, _ = node:range()

  if end_row < ctx.from_row or start_row > ctx.to_row then
    return
  end

  local is_valid, delim_positions = is_match_node(ctx.buf, node, ctx)
  if is_valid then
    local pos, end_pos, is_empty, select_pos, select_end_pos =
      get_match_range(ctx.buf, node, ctx, delim_positions)
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
      })
    end
  end

  for child in node:iter_children() do
    collect_nodes(child, ctx)
  end
end

--- Find matches using treesitter
---@param win number
---@param delim? {open: string, close: string}
---@param around boolean
---@param opts? {from?: Pos, to?: Pos}
---@param char string
---@return Flash.Match.TextObject[]
local function get_delimiter_matches(win, delim, around, opts, char)
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
    char = char,
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

  local delim = M.delimiters[char]
  if not delim and char ~= "t" then
    return {}
  end

  return get_delimiter_matches(win, delim, around, opts, char)
end

--------------------------------------------------------------------------------
-- Operations
--------------------------------------------------------------------------------

--- Handle empty match selection (e.g., "" or ())
--- Called only for empty matches where there's no range to select
---@param match Flash.Match.TextObject
---@param op_state {mode: string, operator: string, register: string}
local function perform_empty_selection(match, op_state)
  vim.api.nvim_set_current_win(match.win)
  local is_op = op_state.mode:sub(1, 2) == "no"
  local op = op_state.operator

  -- Position cursor between delimiters
  vim.api.nvim_win_set_cursor(match.win, { match.pos[1], match.pos[2] })

  if is_op and op == "c" then
    vim.cmd("startinsert")
  elseif is_op and op == "y" then
    -- Yank empty string
    vim.fn.setreg(op_state.register, "")
  end
  -- For delete (d) on empty: no-op (nothing to delete)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Check if a character is a supported text object
---@param char string
---@return boolean
function M.is_supported(char)
  return M.delimiters[char] ~= nil or M.aliases[char] ~= nil or char == "t"
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

      if match.empty then
        -- Empty match (e.g., "" or ()): no range to select
        -- Capture operator state BEFORE exiting (mode will change after exit)
        local op_state = {
          mode = vim.fn.mode(true),
          operator = vim.v.operator,
          register = vim.v.register,
        }
        Util.exit()
        vim.schedule(function()
          perform_empty_selection(match, op_state)
        end)
        Jump.on_jump(state)
      else
        -- Use Flash's built-in jump with adjusted positions
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
