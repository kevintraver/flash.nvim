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
  end)
end)
