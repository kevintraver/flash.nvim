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
      assert.same({ open = '`', close = '`' }, TextObject.delimiters["`"])
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
      set([[print("hello")]] , { 1, 0 }, "lua")
      local win = vim.api.nvim_get_current_win()

      local matches = TextObject.get_matches(win, "x", true)
      assert.equals(0, #matches)
    end)

    it("returns empty when no treesitter parser available", function()
      set([[print("hello")]] , { 1, 0 })
      vim.bo.filetype = "nonexistent_filetype_xyz"
      local win = vim.api.nvim_get_current_win()

      local matches = TextObject.get_matches(win, '"', true)
      -- Should return empty since there's no treesitter parser
      assert.equals(0, #matches)
    end)

    it("handles nested tags correctly", function()
      set([[ 
        <div>
          <div id="inner">content</div>
        </div>
      ]], {1, 0}, "html")
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
  end)
end)