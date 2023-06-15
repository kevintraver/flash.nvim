--# selene: allow(incorrect_standard_library_use)
local Pos = require("flash.search.pos")

describe("pos", function()
  it("handles new", function()
    assert.same(Pos({ row = 1, col = 2 }), { 1, 2 })
    assert.same(Pos({ 1, 2 }), { 1, 2 })
  end)

  it("handles cmp", function()
    assert(Pos({ 1, 2 }) < Pos({ 2, 2 }))
    assert(Pos({ 1, 2 }) < Pos({ 1, 3 }))
    assert(Pos({ 1, 2 }) <= Pos({ 1, 2 }))
    assert(Pos({ 1, 2 }) <= Pos({ 2, 2 }))
    assert(Pos({ 1, 2 }) <= Pos({ 1, 3 }))
    assert(Pos({ 1, 2 }) == Pos({ 1, 2 }))
    assert(Pos({ 1, 2 }) == Pos({ 1, 2 }))
    assert(Pos({ 1, 2 }) ~= Pos({ 2, 2 }))
    assert(Pos({ 1, 2 }) <= Pos({ 2, 2 }))
    assert(Pos({ 1, 2 }) >= Pos({ 1, 2 }))
    assert(Pos({ 1, 2 }) >= Pos({ 1, 1 }))
  end)

  it("handles add", function()
    assert.same(Pos({ 1, 2 }) + Pos({ 1, 2 }), { 2, 4 })
    assert.same(Pos({ 1, 2 }) + { 1, 2 }, { 2, 4 })
    assert.same(Pos({ 1, 2 }) + { row = 1, col = 2 }, { 2, 4 })
  end)

  it("handles sub", function()
    assert.same(Pos({ 1, 2 }) - Pos({ 1, 2 }), { 0, 0 })
    assert.same(Pos({ 1, 2 }) - { 1, 2 }, { 0, 0 })
    assert.same(Pos({ 1, 2 }) - { row = 1, col = 2 }, { 0, 0 })
  end)

  it("handles tostring", function()
    assert.same(tostring(Pos({ 1, 2 })), "[1, 2]")
  end)

  it("handles id", function()
    assert.same(Pos({ 1, 2 }):id(123), "123:1:2")
  end)
end)