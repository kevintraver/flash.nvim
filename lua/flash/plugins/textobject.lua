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

--- Word text objects: search prefix and full word, as Vim regexes
---@type table<string, {prefix: string, word: string}>
M.word_objects = {
  w = { prefix = "\\<", word = "\\k\\+" },
  W = { prefix = "\\%(^\\|\\s\\)\\zs", word = "\\S\\+" },
}

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--- `pos` and `end_pos` span the delimiters (where labels are shown),
--- `select_pos` and `select_end_pos` span the text to operate on.
---@class Flash.Match.TextObject: Flash.Match
---@field empty? boolean True if this is an empty inside match (e.g., () or "")
---@field select_pos? Pos Selection start, defaults to `pos`
---@field select_end_pos? Pos Selection end, defaults to `end_pos`
---@field visual_end_pos? Pos Charwise selection end in Visual mode, when it differs
---@field outer_pos? Pos Start of the whole text object, when the delimiters are inside it
---@field outer_end_pos? Pos End of the whole text object, when the delimiters are inside it

---@class Flash.Match.TextObject.Range
---@field select_pos Pos
---@field select_end_pos Pos
---@field empty? boolean
---@field linewise? boolean
---@field visual_end_pos? Pos
---@field outer_pos? Pos
---@field outer_end_pos? Pos

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

---@param buf number
---@param row number (0-indexed)
---@return string
local function get_line(buf, row)
  return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

--- Extend a range with its trailing whitespace, or else its leading whitespace, like `aw` and `a"`
---@param buf number
---@param pos Pos first character
---@param end_pos Pos last character
---@return Pos pos, Pos end_pos
local function with_whitespace(buf, pos, end_pos)
  local trailing = get_line(buf, end_pos[1] - 1):sub(end_pos[2] + 2):match("^[ \t]+")
  if trailing then
    return pos, Pos({ end_pos[1], end_pos[2] + #trailing })
  end
  local leading = get_line(buf, pos[1] - 1):sub(1, pos[2]):match("[ \t]*$")
  return Pos({ pos[1], pos[2] - #leading }), end_pos
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

  -- Strategy 2: Check boundary characters
  local first_line = get_line(buf, start_row)
  local last_line = get_line(buf, end_row)

  local first_char = first_line:sub(start_col + 1, start_col + 1)
  local last_char = last_line:sub(end_col, end_col)

  if first_char == delim.open and last_char == delim.close then
    return { open_row = start_row, open_col = start_col, close_row = end_row, close_col = end_col - 1 }
  end

  -- Strategy 3: Scan within node text for delimiters (for prefixed strings like f"...")
  -- Only for symmetric delimiters (quotes)
  if delim.open == delim.close then
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
      local close_col_found = nil
      local scan_end = start_row == end_row and open_col_found + 1 or 0

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

--- The exact text between two delimiters, line breaks included, like `i"` and `it`
---@param buf number
---@param start_row number (0-indexed) row of the first content character
---@param start_col number (0-indexed) column of the first content character
---@param end_row number (0-indexed) row of the closing delimiter
---@param end_col number (0-indexed) column of the closing delimiter
---@return Flash.Match.TextObject.Range
local function get_exact_range(buf, start_row, start_col, end_row, end_col)
  local select_pos = Pos({ start_row + 1, start_col })
  local select_end_pos = end_col > 0 and Pos({ end_row + 1, end_col - 1 })
    or Pos({ end_row, #get_line(buf, end_row - 1) })
  if select_end_pos < select_pos then
    return { select_pos = select_pos, select_end_pos = select_pos, empty = true }
  end
  return { select_pos = select_pos, select_end_pos = select_end_pos }
end

--- The text inside a bracket block, following the rules of `i{`:
--- * after an opening bracket at the end of a line, it starts on the next line
--- * before a closing bracket with only whitespace in front of it, it ends on
---   the last line that isn't just whitespace, and is linewise when it starts
---   at or before the first non-blank of its line. In Visual mode, it instead
---   ends on the line break of that line.
---@param buf number
---@param open_row number (0-indexed)
---@param open_col number (0-indexed)
---@param close_row number (0-indexed)
---@param close_col number (0-indexed)
---@return Flash.Match.TextObject.Range
local function get_block_range(buf, open_row, open_col, close_row, close_col)
  local start_row, start_col = open_row, open_col + 1
  if start_col >= #get_line(buf, open_row) then
    start_row, start_col = open_row + 1, 0
  end

  if not get_line(buf, close_row):sub(1, close_col):match("^%s*$") then
    return get_exact_range(buf, start_row, start_col, close_row, close_col)
  end

  local last_row = close_row - 1
  while last_row > open_row and get_line(buf, last_row):match("^%s+$") do
    last_row = last_row - 1
  end

  local select_pos = Pos({ start_row + 1, start_col })
  if last_row < start_row then
    return { select_pos = select_pos, select_end_pos = select_pos, empty = true }
  end

  local last_line = get_line(buf, last_row)
  local ret = { select_pos = select_pos, visual_end_pos = Pos({ last_row + 1, #last_line }) }
  if #get_line(buf, start_row):match("^%s*") >= start_col then
    ret.select_end_pos, ret.linewise = Pos({ last_row + 1, 0 }), true
  elseif last_line == "" then
    -- An empty last line contributes only the line break before it
    ret.select_end_pos = Pos({ last_row, #get_line(buf, last_row - 1) })
  else
    ret.select_end_pos = Pos({ last_row + 1, #last_line - 1 })
  end
  return ret
end

--- Get the label and selection ranges for a node (tag or delimiter)
---@param buf number
---@param node TSNode
---@param ctx {around: boolean, char: string, delim?: {open: string, close: string}}
---@param delim_positions? {open_row: number, open_col: number, close_row: number, close_col: number}
---@return Pos pos, Pos end_pos, Flash.Match.TextObject.Range? inside
local function get_match_range(buf, node, ctx, delim_positions)
  -- Handle tags (t)
  if ctx.char == "t" then
    local start_node = node:named_child(0)
    local end_node = node:named_child(node:named_child_count() - 1)

    local sr1, sc1, er1, ec1 = start_node:range()
    local sr2, sc2, er2, ec2 = end_node:range()

    local pos, end_pos = Pos({ sr1 + 1, sc1 }), Pos({ er2 + 1, ec2 - 1 })
    if ctx.around then
      return pos, end_pos
    end

    -- Self-closing, empty content
    if start_node == end_node then
      return pos, end_pos, { select_pos = pos, select_end_pos = pos, empty = true }
    end

    -- Content is between end of start_node and start of end_node,
    -- so the delimiters are the `>` of the start tag and the `<` of the end tag
    local range = get_exact_range(buf, er1, ec1, sr2, sc2)
    range.outer_pos, range.outer_end_pos = pos, end_pos
    return Pos({ er1 + 1, ec1 - 1 }), Pos({ sr2 + 1, sc2 }), range
  end

  ---@cast delim_positions -nil
  local open_row, open_col = delim_positions.open_row, delim_positions.open_col
  local close_row, close_col = delim_positions.close_row, delim_positions.close_col
  local pos, end_pos = Pos({ open_row + 1, open_col }), Pos({ close_row + 1, close_col })
  local quote = ctx.delim.open == ctx.delim.close
  if ctx.around and quote then
    local select_pos, select_end_pos = with_whitespace(buf, pos, end_pos)
    return pos, end_pos, { select_pos = select_pos, select_end_pos = select_end_pos }
  elseif ctx.around then
    return pos, end_pos
  elseif quote then
    return pos, end_pos, get_exact_range(buf, open_row, open_col + 1, close_row, close_col)
  end
  return pos, end_pos, get_block_range(buf, open_row, open_col, close_row, close_col)
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
    local pos, end_pos, inside = get_match_range(ctx.buf, node, ctx, delim_positions)
    local key = make_key(pos, end_pos)

    if not ctx.seen[key] then
      ctx.seen[key] = true
      table.insert(ctx.matches, vim.tbl_extend("force", { win = ctx.win, pos = pos, end_pos = end_pos }, inside or {}))
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

--- Expand a search match at the start of a word to the whole word,
--- plus trailing (or else leading) whitespace for "around", like `aw`
---@param match Flash.Match
---@param char string
---@param around boolean
---@return Flash.Match
local function get_word_match(match, char, around)
  local buf = vim.api.nvim_win_get_buf(match.win)
  local line = get_line(buf, match.pos[1] - 1)
  -- `\k` depends on the buffer's 'iskeyword'
  local _, s, e = unpack(vim.api.nvim_buf_call(buf, function()
    return vim.fn.matchstrpos(line, "^" .. M.word_objects[char].word, match.pos[2])
  end))
  if s == -1 then
    return match
  end

  local pos, end_pos = Pos({ match.pos[1], s }), Pos({ match.pos[1], e - 1 })
  if around then
    pos, end_pos = with_whitespace(buf, pos, end_pos)
  end
  return vim.tbl_extend("force", {}, match, { pos = pos, end_pos = end_pos })
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

--- Handle empty match selection (e.g., "" or ()) when not changing or deleting it
---@param match Flash.Match.TextObject
---@param op_state {mode: string, operator: string, register: string}
local function perform_empty_selection(match, op_state)
  vim.api.nvim_set_current_win(match.win)

  -- Position cursor between delimiters
  vim.api.nvim_win_set_cursor(match.win, match.select_pos)

  if op_state.mode:sub(1, 2) == "no" and op_state.operator == "y" then
    -- Yank empty string
    vim.fn.setreg(op_state.register, "")
  end
end

--- Whether `d` on this charwise range deletes whole lines, like it does for
--- motions spanning lines with only whitespace before the start and after the end
---@param buf number
---@param match Flash.Match
---@return boolean
local function deletes_whole_lines(buf, match)
  local pos, end_pos = match.pos, match.end_pos
  return pos[1] < end_pos[1]
    and #get_line(buf, pos[1] - 1):match("^%s*") >= pos[2]
    and get_line(buf, end_pos[1] - 1):sub(end_pos[2] + 2):match("^%s*$") ~= nil
end

--- The innermost text object around the cursor, or else the next one after it
---@param state Flash.State
---@param cursor Pos
---@return Flash.Match?
local function get_repeat_match(state, cursor)
  local around, after ---@type Flash.Match?, Flash.Match?
  for _, m in ipairs(state.results) do
    ---@cast m Flash.Match.TextObject
    if m.win == state.win and (m.outer_end_pos or m.end_pos) >= cursor then
      if (m.outer_pos or m.pos) <= cursor then
        around = (not around or m.pos > around.pos) and m or around
      else
        after = (not after or m.pos < after.pos) and m or after
      end
    end
  end
  return around or after
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Check if a character is a supported text object
---@param char string
---@return boolean
function M.is_supported(char)
  return M.delimiters[char] ~= nil or M.aliases[char] ~= nil or M.word_objects[char] ~= nil or char == "t"
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
  local word = M.word_objects[char]

  local mode_opts ---@type Flash.Config?
  if word then
    -- Words are too numerous to label up front, so type the start of one first,
    -- labeled like `jump()`
    mode_opts = {
      search = {
        mode = function(str)
          return word.prefix .. "\\V" .. str:gsub("\\", "\\\\")
        end,
        incremental = true,
        max_length = false,
      },
      label = { before = false, after = true, style = "overlay" },
      prompt = { enabled = true },
    }
  elseif not around then
    -- Label just inside the delimiters instead of around them
    mode_opts = { label = { before = { 0, 0 }, after = { 0, 0 } } }
  end

  opts = Config.get({ mode = "textobject" }, mode_opts, opts, {
    matcher = not word and function(win, _, search_opts)
      return M.get_matches(win, char, around, search_opts)
    end or nil,
    action = function(match, state)
      local Jump = require("flash.jump")
      ---@cast match Flash.Match.TextObject

      if word then
        match = get_word_match(match, char, around)
      end

      local buf = vim.api.nvim_win_get_buf(match.win)
      local op = vim.fn.mode(true):sub(1, 2) == "no" and vim.v.operator or nil
      local selection = vim.tbl_extend("force", {}, match, {
        pos = match.select_pos or match.pos,
        end_pos = match.select_end_pos or match.end_pos,
      })

      if match.empty and (op == "c" or op == "d") then
        -- There is no empty selection, so insert a space and operate on that.
        -- `c` then starts Insert mode between the delimiters (idea from targets.vim)
        local row, col = selection.pos[1] - 1, selection.pos[2]
        vim.api.nvim_buf_set_text(buf, row, col, row, col, { " " })
        selection.end_pos = selection.pos

        -- Keep the space out of the registers
        local registers = {}
        for _, name in ipairs({ '"', "-", vim.v.register }) do
          registers[name] = vim.fn.getreginfo(name)
        end
        vim.api.nvim_create_autocmd("TextYankPost", {
          once = true,
          callback = function()
            for name, info in pairs(registers) do
              vim.fn.setreg(name, info)
            end
          end,
        })
      elseif match.empty then
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
        return
      elseif op == "d" and not selection.linewise then
        selection.linewise = deletes_whole_lines(buf, selection)
      elseif not op and match.visual_end_pos then
        selection.end_pos, selection.linewise = match.visual_end_pos, false
      end

      Jump.jump(selection, state)
      Jump.on_jump(state)
    end,
  })

  -- before incremental search moves the cursor to the first match
  local cursor = Pos()
  local state = Repeat.get_state("textobject", opts)

  local match ---@type Flash.Match?
  if Repeat.is_repeat then
    -- Dot-repeat can't wait for a label, since the redo buffer would feed it
    -- the text inserted by `c`. Use the text object at or after the cursor.
    match = get_repeat_match(state, cursor)
  elseif word then
    state:loop({ restore = true, abort = Util.exit })
    return state
  else
    -- A label picks a text object and <CR> the nearest one.
    -- Any other key aborts, like an invalid built-in text object.
    local key = state:get_char()
    match = key == Util.CR and state.target or key and state:find({ label = key })
  end

  if match then
    state:jump(match)
  else
    state:restore()
    Util.exit()
  end
  state:hide()

  return state
end

--- Remote text object selection entry point
---@param opts? Flash.Config & { around?: boolean }
function M.remote(opts)
  opts = opts or {}
  local around = opts.around or false

  -- Dot-repeat reuses the text object type
  local char = Repeat.is_repeat and M.last_char or vim.fn.getcharstr()
  if char == Util.ESC then
    Util.exit()
    return
  end

  if not M.is_supported(char) then
    vim.notify(
      "Unsupported text object: " .. char .. " (supported: \" ' ` ( ) [ ] { } < > b q t w W)",
      vim.log.levels.WARN
    )
    Util.exit()
    return
  end

  M.last_char = char
  return M.jump(char, around, opts)
end

return M
