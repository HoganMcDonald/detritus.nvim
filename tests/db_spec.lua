local h = require("harness")
local t = h.t
local db = require("detritus.db")

local function store()
  return db.open(h.tmpdir() .. "/plans.db")
end

local scope = { project = "/repo", branch = "main" }

local function texts(plan)
  return vim.tbl_map(function(s)
    return s.text
  end, plan.steps)
end

describe("db", function()
  describe("set_plan / get_plan", function()
    it("returns nil when there is no plan", function()
      t.eq(store():get_plan(scope), nil)
    end)

    it("stores ordered steps with details and refs", function()
      local s = store()
      s:set_plan(scope, {
        title = "Sessions",
        steps = {
          {
            text = "Add `SessionToken` struct",
            details = { "has user_id", "has expiry" },
            refs = { { path = "src/a.rs", line = 3 } },
          },
          { text = "Wire it in" },
        },
      })
      local plan = s:get_plan(scope)
      t.eq(plan.title, "Sessions")
      t.eq(texts(plan), { "Add `SessionToken` struct", "Wire it in" })
      t.eq(plan.steps[1].details, { "has user_id", "has expiry" })
      t.eq(plan.steps[1].refs, { { path = "src/a.rs", line = 3 } })
      t.eq(plan.steps[2].details, {})
      t.eq({ plan.steps[1].position, plan.steps[2].position }, { 1, 2 })
      t.falsy(plan.steps[1].done)
      t.falsy(plan.steps[1].changed)
    end)

    it("replaces an existing plan", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" }, { text = "b" } } })
      s:set_plan(scope, { steps = { { text = "c" } } })
      t.eq(texts(s:get_plan(scope)), { "c" })
    end)

    it("folds newlines in step text into spaces", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "one\n  two" } } })
      t.eq(s:get_plan(scope).steps[1].text, "one two")
    end)

    it("validates input and writes nothing on failure", function()
      local s = store()
      t.throws(function()
        s:set_plan(scope, { steps = { { text = "ok" }, { text = "  " } } })
      end, "must not be empty")
      t.eq(s:get_plan(scope), nil)
      t.throws(function()
        s:set_plan(scope, { steps = { { text = "x", refs = { { line = 3 } } } } })
      end, "needs a path or a symbol")
      t.throws(function()
        s:set_plan(scope, { steps = { { text = "x", refs = { { path = "a", line = 0 } } } } })
      end, "positive integer")
      t.throws(function()
        s:set_plan(scope, { steps = { { text = "x", details = "nope" } } })
      end, "array of strings")
    end)
  end)

  describe("branch partitioning", function()
    it("keeps plans for different branches and projects separate", function()
      local s = store()
      s:set_plan({ project = "/repo", branch = "main" }, { steps = { { text = "main step" } } })
      s:set_plan({ project = "/repo", branch = "feat" }, { steps = { { text = "feat step" } } })
      s:set_plan({ project = "/other", branch = "main" }, { steps = { { text = "other step" } } })
      t.eq(texts(s:get_plan({ project = "/repo", branch = "main" })), { "main step" })
      t.eq(texts(s:get_plan({ project = "/repo", branch = "feat" })), { "feat step" })
      t.eq(texts(s:get_plan({ project = "/other", branch = "main" })), { "other step" })
    end)

    it("lists the plans of one project with progress", function()
      local s = store()
      s:set_plan({ project = "/repo", branch = "main" }, { steps = { { text = "a" }, { text = "b" } } })
      s:set_plan({ project = "/repo", branch = "feat" }, { title = "Feat", steps = { { text = "c" } } })
      s:set_plan({ project = "/other", branch = "x" }, { steps = { { text = "d" } } })
      local main = s:get_plan({ project = "/repo", branch = "main" })
      s:set_done({ project = "/repo", branch = "main" }, main.steps[1].id, true)
      local listed = s:list_plans("/repo")
      t.eq(#listed, 2)
      local by_branch = {}
      for _, p in ipairs(listed) do
        by_branch[p.branch] = p
      end
      t.eq({ by_branch.main.total, by_branch.main.done }, { 2, 1 })
      t.eq(by_branch.feat.title, "Feat")
    end)

    it("does not let a scope touch another scope's step", function()
      local s = store()
      s:set_plan({ project = "/repo", branch = "main" }, { steps = { { text = "a" } } })
      local id = s:get_plan({ project = "/repo", branch = "main" }).steps[1].id
      t.throws(function()
        s:update_step({ project = "/repo", branch = "feat" }, id, { text = "hijack" })
      end, "not found")
      t.throws(function()
        s:delete_step({ project = "/repo", branch = "feat" }, id)
      end, "not found")
    end)
  end)

  describe("add_steps", function()
    local function seeded()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" }, { text = "b" }, { text = "c" } } })
      return s, s:get_plan(scope).steps
    end

    it("appends by default and creates the plan if needed", function()
      local s = store()
      s:add_steps(scope, { { text = "a" }, { text = "b" } })
      t.eq(texts(s:get_plan(scope)), { "a", "b" })
    end)

    it("inserts after a given step", function()
      local s, steps = seeded()
      s:add_steps(scope, { { text = "x" }, { text = "y" } }, steps[1].id)
      t.eq(texts(s:get_plan(scope)), { "a", "x", "y", "b", "c" })
    end)

    it("inserts at the start with after_id = 0", function()
      local s = seeded()
      s:add_steps(scope, { { text = "x" } }, 0)
      t.eq(texts(s:get_plan(scope)), { "x", "a", "b", "c" })
    end)

    it("rejects an unknown anchor without writing", function()
      local s = seeded()
      t.throws(function()
        s:add_steps(scope, { { text = "x" } }, 9999)
      end, "not found")
      t.eq(texts(s:get_plan(scope)), { "a", "b", "c" })
    end)

    it("does not flag new steps as changed", function()
      local s, steps = seeded()
      local added = s:add_steps(scope, { { text = "x" } }, steps[1].id)
      t.falsy(added[1].changed)
    end)
  end)

  describe("update_step", function()
    it("flags a modified step as changed and unchecks it", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" } } })
      local id = s:get_plan(scope).steps[1].id
      s:set_done(scope, id, true)
      local step, modified = s:update_step(scope, id, { text = "a, but different" })
      t.truthy(modified)
      t.truthy(step.changed)
      t.falsy(step.done)
      t.eq(step.text, "a, but different")
    end)

    it("flags changes to details and refs too", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" }, { text = "b" } } })
      local steps = s:get_plan(scope).steps
      t.truthy(select(2, s:update_step(scope, steps[1].id, { details = { "must be non-empty" } })))
      t.truthy(select(2, s:update_step(scope, steps[2].id, { refs = { { symbol = "Foo::new" } } })))
    end)

    it("is a no-op when nothing actually changes", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a", details = { "d" }, refs = { { path = "p", line = 1 } } } } })
      local id = s:get_plan(scope).steps[1].id
      s:set_done(scope, id, true)
      local step, modified =
        s:update_step(scope, id, { text = "a", details = { "d" }, refs = { { path = "p", line = 1 } } })
      t.falsy(modified)
      t.falsy(step.changed)
      t.truthy(step.done)
    end)

    it("requires at least one field and an existing step", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" } } })
      local id = s:get_plan(scope).steps[1].id
      t.throws(function()
        s:update_step(scope, id, {})
      end, "at least one")
      t.throws(function()
        s:update_step(scope, 9999, { text = "x" })
      end, "not found")
    end)
  end)

  describe("set_done", function()
    it("checking off clears the changed flag", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" } } })
      local id = s:get_plan(scope).steps[1].id
      s:update_step(scope, id, { text = "a2" })
      t.truthy(s:get_step(scope, id).changed)
      s:set_done(scope, id, true)
      local step = s:get_step(scope, id)
      t.truthy(step.done)
      t.falsy(step.changed)
    end)

    it("unchecking leaves the step unchanged-flag alone", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" } } })
      local id = s:get_plan(scope).steps[1].id
      s:set_done(scope, id, true)
      s:set_done(scope, id, false)
      local step = s:get_step(scope, id)
      t.falsy(step.done)
      t.falsy(step.changed)
    end)
  end)

  describe("move_step", function()
    local function seeded()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" }, { text = "b" }, { text = "c" } } })
      return s, s:get_plan(scope).steps
    end

    it("moves a step after another", function()
      local s, steps = seeded()
      s:move_step(scope, steps[1].id, steps[3].id)
      t.eq(texts(s:get_plan(scope)), { "b", "c", "a" })
    end)

    it("moves a step to the start", function()
      local s, steps = seeded()
      s:move_step(scope, steps[3].id, 0)
      t.eq(texts(s:get_plan(scope)), { "c", "a", "b" })
    end)

    it("does not flag the moved step", function()
      local s, steps = seeded()
      s:set_done(scope, steps[1].id, true)
      s:move_step(scope, steps[1].id, steps[3].id)
      local moved = s:get_step(scope, steps[1].id)
      t.truthy(moved.done)
      t.falsy(moved.changed)
    end)

    it("rejects bad anchors", function()
      local s, steps = seeded()
      t.throws(function()
        s:move_step(scope, steps[1].id, steps[1].id)
      end, "after itself")
      t.throws(function()
        s:move_step(scope, steps[1].id, 9999)
      end, "not found")
    end)
  end)

  describe("delete / clear", function()
    it("deletes a step and keeps positions dense", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" }, { text = "b" }, { text = "c" } } })
      local steps = s:get_plan(scope).steps
      s:delete_step(scope, steps[2].id)
      local plan = s:get_plan(scope)
      t.eq(texts(plan), { "a", "c" })
      t.eq({ plan.steps[1].position, plan.steps[2].position }, { 1, 2 })
    end)

    it("clears a plan, cascading to its steps, without touching other branches", function()
      local s = store()
      s:set_plan(scope, { steps = { { text = "a" }, { text = "b" } } })
      s:set_plan({ project = "/repo", branch = "feat" }, { steps = { { text = "z" } } })
      t.eq(s:clear_plan(scope), 2)
      t.eq(s:get_plan(scope), nil)
      t.eq(s.db:scalar("SELECT COUNT(*) FROM steps"), 1)
      t.eq(texts(s:get_plan({ project = "/repo", branch = "feat" })), { "z" })
    end)

    it("clearing a missing plan is harmless", function()
      t.eq(store():clear_plan(scope), 0)
    end)
  end)

  describe("set_title", function()
    it("sets the title, creating the plan if needed", function()
      local s = store()
      s:set_title(scope, "My plan")
      t.eq(s:get_plan(scope).title, "My plan")
    end)
  end)

  describe("concurrency", function()
    it("a second connection sees writes and data_version moves", function()
      local path = h.tmpdir() .. "/shared.db"
      local a, b = db.open(path), db.open(path)
      local before = a:data_version()
      b:set_plan(scope, { steps = { { text = "from b" } } })
      t.eq(texts(a:get_plan(scope)), { "from b" })
      t.truthy(a:data_version() ~= before)
    end)
  end)
end)
