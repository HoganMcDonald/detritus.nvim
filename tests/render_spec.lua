local h = require("harness")
local t = h.t
local render = require("detritus.ui.render")
local config = require("detritus.config")

local scope = { project = "/r", branch = "feat/x" }
local icons = config.defaults.icons

local function step(id, text, extra)
  return vim.tbl_extend(
    "force",
    { id = id, position = id, text = text, details = {}, refs = {}, done = false, changed = false },
    extra or {}
  )
end

local function build(steps, collapsed)
  return render.build({ id = 1, project = "/r", branch = "feat/x", title = "T", steps = steps }, scope, {
    collapsed = collapsed or {},
    icons = icons,
  })
end

describe("render", function()
  it("shows an empty state with guidance", function()
    local index = render.build(nil, scope, { collapsed = {}, icons = icons })
    t.truthy(table.concat(index.lines, "\n"):find("No steps", 1, true))
    t.eq(index.total, 0)
  end)

  it("renders header, progress and branch", function()
    local index = build({ step(1, "a", { done = true }), step(2, "b") })
    t.eq(index.lines[1], " T  1/2")
    t.truthy(index.lines[2]:find("feat/x", 1, true))
    t.eq({ index.done, index.total }, { 1, 2 })
  end)

  it("prefixes changed, unchecked steps with the warning emoji", function()
    local index = build({ step(1, "a", { changed = true }), step(2, "b") })
    t.truthy(index.lines[4]:find("⚠️ a", 1, true))
    t.falsy(index.lines[5]:find("⚠️", 1, true))
  end)

  it("uses check icons for done and todo", function()
    local index = build({ step(1, "a", { done = true }), step(2, "b") })
    t.truthy(index.lines[4]:find(icons.done, 1, true))
    t.truthy(index.lines[5]:find(icons.todo, 1, true))
  end)

  it("maps detail and ref lines back to their step", function()
    local ref = { path = "src/a.rs", line = 3, symbol = "Foo" }
    local index = build({ step(1, "a", { details = { "d1", "d2" }, refs = { ref } }), step(2, "b") })
    t.eq(index.first_line[1], 4)
    t.eq(index.last_line[1], 7)
    for line = 4, 7 do
      t.eq(index.step_at[line], 1)
    end
    t.eq(index.step_at[8], 2)
    t.eq(index.ref_at[7], ref)
    t.eq(index.ref_at[5], nil)
  end)

  it("hides details and refs when collapsed and shows a count", function()
    local index = build({ step(1, "a", { details = { "d1" }, refs = { { path = "p" } } }) }, { [1] = true })
    t.eq(index.first_line[1], index.last_line[1])
    t.truthy(index.lines[4]:find("+2", 1, true))
  end)

  it("tracks unchecked steps in order", function()
    local index = build({ step(1, "a", { done = true }), step(2, "b"), step(3, "c") })
    t.eq(index.open_lines, { 5, 6 })
  end)

  it("labels refs", function()
    t.eq(render.ref_label({ path = "a.rs", line = 4, symbol = "X" }), "a.rs:4  X")
    t.eq(render.ref_label({ symbol = "X" }), "X")
    t.eq(render.ref_label({ path = "a.rs" }), "a.rs")
  end)

  it("keeps mark columns within their lines", function()
    local index = build({ step(1, "use `Foo` here", { changed = true, details = { "has `bar`" } }) })
    for _, mark in ipairs(index.marks) do
      local line = index.lines[mark.line + 1]
      t.truthy(mark.end_col <= #line, ("mark %s past end of %q"):format(mark.hl, line))
      t.truthy(mark.col <= mark.end_col)
    end
  end)
end)
