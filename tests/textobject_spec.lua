local TextObject = require("flash.plugins.textobject")
local assert = require("luassert")
require("flash").setup()

describe("textobject", function()
  local function set(text, pos, ft)
    local lines = vim.split(vim.trim(text), "\n")
    lines = vim.tbl_map(function(line)
      return vim.trim(line)
    end, lines)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, pos or { 1, 0 })
    if ft then
      vim.bo.filetype = ft
    end
  end

  ---@param from Pos
  ---@param to Pos
  local function get_text(from, to)
    return table.concat(vim.api.nvim_buf_get_text(0, from[1] - 1, from[2], to[1] - 1, to[2] + 1, {}), "\n")
  end

  before_each(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
  end)

  describe("delimiters", function()
    it("supports both opening and closing delimiters for brackets", function()
      -- ( and ) should both map to parentheses
      assert.is_not_nil(TextObject.delimiters["("])
      assert.is_not_nil(TextObject.delimiters[")"])
      assert.same(TextObject.delimiters["("], TextObject.delimiters[")"])

      -- [ and ] should both map to brackets
      assert.is_not_nil(TextObject.delimiters["["])
      assert.is_not_nil(TextObject.delimiters["]"])
      assert.same(TextObject.delimiters["["], TextObject.delimiters["]"])

      -- { and } should both map to braces
      assert.is_not_nil(TextObject.delimiters["{"])
      assert.is_not_nil(TextObject.delimiters["}"])
      assert.same(TextObject.delimiters["{"], TextObject.delimiters["}"])

      -- < and > should both map to angle brackets
      assert.is_not_nil(TextObject.delimiters["<"])
      assert.is_not_nil(TextObject.delimiters[">"])
      assert.same(TextObject.delimiters["<"], TextObject.delimiters[">"])
    end)

    it("supports all quote types", function()
      assert.is_not_nil(TextObject.delimiters['"'])
      assert.is_not_nil(TextObject.delimiters["'"])
      assert.is_not_nil(TextObject.delimiters["`"])
    end)

    it("has correct delimiter pairs", function()
      assert.same({ open = '"', close = '"' }, TextObject.delimiters['"'])
      assert.same({ open = "'", close = "'" }, TextObject.delimiters["'"])
      assert.same({ open = "`", close = "`" }, TextObject.delimiters["`"])
      assert.same({ open = "(", close = ")" }, TextObject.delimiters["("])
      assert.same({ open = "(", close = ")" }, TextObject.delimiters[")"])
      assert.same({ open = "[", close = "]" }, TextObject.delimiters["["])
      assert.same({ open = "[", close = "]" }, TextObject.delimiters["]"])
      assert.same({ open = "{", close = "}" }, TextObject.delimiters["{"])
      assert.same({ open = "{", close = "}" }, TextObject.delimiters["}"])
      assert.same({ open = "<", close = ">" }, TextObject.delimiters["<"])
      assert.same({ open = "<", close = ">" }, TextObject.delimiters[">"])
    end)
  end)

  describe("get_matches", function()
    it("returns empty for unsupported char", function()
      set([[print("hello")]], { 1, 0 }, "lua")
      local win = vim.api.nvim_get_current_win()

      local matches = TextObject.get_matches(win, "x", true)
      assert.equals(0, #matches)
    end)

    it("returns empty when no treesitter parser available", function()
      set([[print("hello")]], { 1, 0 })
      vim.bo.filetype = "nonexistent_filetype_xyz"
      local win = vim.api.nvim_get_current_win()

      local matches = TextObject.get_matches(win, '"', true)
      -- Should return empty since there's no treesitter parser
      assert.equals(0, #matches)
    end)

    it("handles nested tags correctly", function()
      set(
        [[
        <div>
          <div id="inner">content</div>
        </div>
      ]],
        { 1, 0 },
        "html"
      )
      local win = vim.api.nvim_get_current_win()

      local matches = TextObject.get_matches(win, "t", false)

      if #matches == 0 then
        local buf = vim.api.nvim_win_get_buf(win)
        local ok, parser = pcall(vim.treesitter.get_parser, buf)
        if not ok or not parser then
          print("Skipping tag test: no html parser")
          return
        end
      end

      assert.equals(2, #matches)

      -- Outer div (Match 1)
      local outer = matches[1]
      -- Inner div (Match 2)
      local inner = matches[2]

      assert.equals(1, outer.pos[1])
      assert.equals(2, inner.pos[1])
    end)

    it("finds square brackets when delimiter is child node", function()
      -- In Lua, t["key"] parses as bracket_index_expression where [ and ] are children
      set([=[local x = t["key"]]=], { 1, 0 }, "lua")
      local win = vim.api.nvim_get_current_win()

      local buf = vim.api.nvim_win_get_buf(win)
      local ok, parser = pcall(vim.treesitter.get_parser, buf)
      if not ok or not parser then
        print("Skipping bracket test: no lua parser")
        return
      end

      local inside = TextObject.get_matches(win, "[", false)
      assert.equals(1, #inside)

      -- Inside should select the content: "key"
      local m = inside[1]
      assert.equals('"key"', get_text(m.select_pos, m.select_end_pos))

      -- Around should include brackets: ["key"]
      local around = TextObject.get_matches(win, "[", true)
      assert.equals(1, #around)
      local ma = around[1]
      assert.equals('["key"]', get_text(ma.pos, ma.end_pos))
    end)

    it("finds prefixed strings like f-strings", function()
      set([[msg = f"hello"]], { 1, 0 }, "python")
      local win = vim.api.nvim_get_current_win()

      local buf = vim.api.nvim_win_get_buf(win)
      local ok, parser = pcall(vim.treesitter.get_parser, buf)
      if not ok or not parser then
        print("Skipping f-string test: no python parser")
        return
      end

      local inside = TextObject.get_matches(win, '"', false)
      assert.equals(1, #inside)

      -- Inside should select content without quotes: hello
      local m = inside[1]
      assert.equals("hello", get_text(m.select_pos, m.select_end_pos))

      -- Around should include quotes but not prefix: "hello"
      local around = TextObject.get_matches(win, '"', true)
      assert.equals(1, #around)
      local ma = around[1]
      assert.equals('"hello"', get_text(ma.pos, ma.end_pos))
    end)

    it("labels the delimiters and selects the content inside", function()
      set([[local a = "hello"]], { 1, 0 }, "lua")
      local win = vim.api.nvim_get_current_win()

      local m = TextObject.get_matches(win, '"', false)[1]
      assert.same({ 1, 10 }, { m.pos[1], m.pos[2] })
      assert.same({ 1, 16 }, { m.end_pos[1], m.end_pos[2] })
      assert.equals("hello", get_text(m.select_pos, m.select_end_pos))
    end)

    it("labels and selects around quotes with trailing or else leading whitespace", function()
      set([[local a = f("x", "y")]], { 1, 0 }, "lua")
      local win = vim.api.nvim_get_current_win()

      local x, y = unpack(TextObject.get_matches(win, '"', true))
      assert.equals('"x"', get_text(x.pos, x.end_pos))
      assert.equals(' "y"', get_text(y.pos, y.end_pos))

      set([[local a = "x"  .. b]], { 1, 0 }, "lua")
      local m = TextObject.get_matches(win, '"', true)[1]
      assert.equals('"x"  ', get_text(m.pos, m.end_pos))
    end)

    it("marks empty pairs with the cursor position between the delimiters", function()
      set([[local a = f("")]], { 1, 0 }, "lua")
      local win = vim.api.nvim_get_current_win()

      local quote = TextObject.get_matches(win, '"', false)[1]
      assert.is_true(quote.empty)
      assert.same({ 1, 13 }, { quote.select_pos[1], quote.select_pos[2] })

      local paren = TextObject.get_matches(win, "(", false)[1]
      assert.is_falsy(paren.empty)
      assert.equals('""', get_text(paren.select_pos, paren.select_end_pos))
    end)

    it("selects whole lines inside a multi-line block", function()
      set(
        [[
        local t = {
          a = 1,
          b = 2,
        }
      ]],
        { 1, 0 },
        "lua"
      )
      local win = vim.api.nvim_get_current_win()

      local m = TextObject.get_matches(win, "{", false)[1]
      assert.same({ 1, 10 }, { m.pos[1], m.pos[2] })
      assert.same({ 4, 0 }, { m.end_pos[1], m.end_pos[2] })
      assert.is_true(m.linewise)
      assert.same({ 2, 3 }, { m.select_pos[1], m.select_end_pos[1] })
    end)

    it("selects up to the line end when a block starts mid-line", function()
      set(
        [[
        f({ a,
        b,
        })
      ]],
        { 1, 0 },
        "lua"
      )
      local win = vim.api.nvim_get_current_win()

      local m = TextObject.get_matches(win, "{", false)[1]
      assert.is_nil(m.linewise)
      assert.equals(" a,\nb,", get_text(m.select_pos, m.select_end_pos))
    end)

    it("selects the exact content of a multi-line tag", function()
      set(
        [[
        <div>
        <p>x</p>
        </div>
      ]],
        { 1, 0 },
        "html"
      )
      local win = vim.api.nvim_get_current_win()

      local m = TextObject.get_matches(win, "t", false)[1]
      if not m then
        print("Skipping multi-line tag test: no html parser")
        return
      end
      -- the whole element, labeled on the `>` of <div> and the `<` of </div>
      assert.same({ 1, 0 }, { m.pos[1], m.pos[2] })
      assert.same({ 3, 5 }, { m.end_pos[1], m.end_pos[2] })
      assert.same({ 1, 4 }, { m.label_pos[1], m.label_pos[2] })
      assert.same({ 3, 0 }, { m.label_end_pos[1], m.label_end_pos[2] })
      -- starts on the line break after <div> and ends on the one before </div>
      assert.same({ 1, 5 }, { m.select_pos[1], m.select_pos[2] })
      assert.same({ 2, 8 }, { m.select_end_pos[1], m.select_end_pos[2] })
    end)
  end)
end)
