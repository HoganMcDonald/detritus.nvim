---Plan storage. One SQLite file holds every project's plans, partitioned by
---`(project, branch)`. Both the Neovim panel and the MCP server use this module.
local sqlite = require("detritus.sqlite")

local M = {}

---@class detritus.Ref
---@field path? string
---@field line? integer
---@field symbol? string

---@class detritus.Step
---@field id integer
---@field position integer
---@field text string
---@field details string[]
---@field refs detritus.Ref[]
---@field done boolean
---@field changed boolean

---@class detritus.Plan
---@field id integer
---@field project string
---@field branch string
---@field title? string
---@field updated_at integer
---@field steps detritus.Step[]

---@class detritus.Scope
---@field project string
---@field branch string
---@field root? string

---@class detritus.StepInput
---@field text string
---@field details? string[]
---@field refs? detritus.Ref[]

---Where the shared database lives. Intentionally independent of NVIM_APPNAME so
---the headless MCP server and every Neovim config agree on one file.
---@return string
function M.default_path()
  local override = vim.env.DETRITUS_DB
  if override and override ~= "" then
    return override
  end
  local base = vim.env.XDG_DATA_HOME
  if not base or base == "" then
    base = vim.fs.joinpath(vim.env.HOME, ".local", "share")
  end
  return vim.fs.joinpath(base, "detritus", "detritus.db")
end

local migrations = {
  function(db)
    db:exec([[
      CREATE TABLE plans (
        id         INTEGER PRIMARY KEY,
        project    TEXT    NOT NULL,
        branch     TEXT    NOT NULL,
        title      TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE (project, branch)
      );
      CREATE TABLE steps (
        id         INTEGER PRIMARY KEY,
        plan_id    INTEGER NOT NULL REFERENCES plans (id) ON DELETE CASCADE,
        position   INTEGER NOT NULL,
        text       TEXT    NOT NULL,
        details    TEXT    NOT NULL DEFAULT '[]',
        refs       TEXT    NOT NULL DEFAULT '[]',
        done       INTEGER NOT NULL DEFAULT 0,
        changed    INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      );
      CREATE INDEX steps_plan_position ON steps (plan_id, position);
    ]])
  end,
}

---@class detritus.Store
---@field db detritus.Database
local Store = {}
Store.__index = Store

---Open the store, applying any pending migrations.
---@param path? string
---@return detritus.Store
function M.open(path)
  local db = sqlite.open(path or M.default_path())
  db:exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
  local version = db:scalar("PRAGMA user_version") or 0
  for v = version + 1, #migrations do
    db:transaction(function()
      migrations[v](db)
      db:exec("PRAGMA user_version = " .. v)
    end)
  end
  return setmetatable({ db = db }, Store)
end

function Store:close()
  self.db:close()
end

---Changes whenever *another* connection commits. Cheap way to detect that the
---MCP server wrote something.
---@return integer
function Store:data_version()
  return self.db:scalar("PRAGMA data_version") or 0
end

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

local function fail(message)
  error(message, 0)
end

local function clean_string(value, what)
  if type(value) ~= "string" then
    fail(what .. " must be a string")
  end
  -- Steps are single sentences: fold any newlines into spaces.
  local text = vim.trim((value:gsub("%s*\n%s*", " ")))
  if text == "" then
    fail(what .. " must not be empty")
  end
  return text
end

---@param details any
---@return string[]
local function normalize_details(details)
  if details == nil or details == vim.NIL then
    return {}
  end
  if type(details) ~= "table" then
    fail("details must be an array of strings")
  end
  local out = {}
  for i, item in ipairs(details) do
    out[i] = clean_string(item, "details[" .. i .. "]")
  end
  return out
end

---@param refs any
---@return detritus.Ref[]
local function normalize_refs(refs)
  if refs == nil or refs == vim.NIL then
    return {}
  end
  if type(refs) ~= "table" then
    fail("refs must be an array of {path?, line?, symbol?} objects")
  end
  local out = {}
  for i, ref in ipairs(refs) do
    if type(ref) ~= "table" then
      fail("refs[" .. i .. "] must be an object")
    end
    local clean = {}
    if ref.path ~= nil and ref.path ~= vim.NIL then
      clean.path = clean_string(ref.path, "refs[" .. i .. "].path")
    end
    if ref.symbol ~= nil and ref.symbol ~= vim.NIL then
      clean.symbol = clean_string(ref.symbol, "refs[" .. i .. "].symbol")
    end
    if ref.line ~= nil and ref.line ~= vim.NIL then
      if type(ref.line) ~= "number" or ref.line < 1 or ref.line ~= math.floor(ref.line) then
        fail("refs[" .. i .. "].line must be a positive integer")
      end
      clean.line = ref.line
    end
    if not clean.path and not clean.symbol then
      fail("refs[" .. i .. "] needs a path or a symbol")
    end
    out[i] = clean
  end
  return out
end

---@param input any
---@return { text: string, details: string[], refs: detritus.Ref[] }
local function normalize_step(input)
  if type(input) ~= "table" then
    fail("each step must be an object with a text field")
  end
  return {
    text = clean_string(input.text, "text"),
    details = normalize_details(input.details),
    refs = normalize_refs(input.refs),
  }
end

local function decode(raw)
  if not raw or raw == "" then
    return {}
  end
  local ok, value = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  return ok and value or {}
end

---@return detritus.Step
local function hydrate(row)
  return {
    id = row.id,
    position = row.position,
    text = row.text,
    details = decode(row.details),
    refs = decode(row.refs),
    done = row.done == 1,
    changed = row.changed == 1,
  }
end

---------------------------------------------------------------------------
-- Plans
---------------------------------------------------------------------------

---@param scope detritus.Scope
---@return table?
function Store:find_plan(scope)
  return self.db:one("SELECT * FROM plans WHERE project = ? AND branch = ?", { scope.project, scope.branch })
end

---@param scope detritus.Scope
---@param title? string
---@return table
function Store:ensure_plan(scope, title)
  local plan = self:find_plan(scope)
  if plan then
    return plan
  end
  local now = os.time()
  self.db:run(
    "INSERT INTO plans (project, branch, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
    { scope.project, scope.branch, title, now, now }
  )
  return assert(self:find_plan(scope))
end

function Store:touch(plan_id)
  self.db:run("UPDATE plans SET updated_at = ? WHERE id = ?", { os.time(), plan_id })
end

---@param plan_id integer
---@return integer[]
function Store:order(plan_id)
  local ids = {}
  for _, row in ipairs(self.db:all("SELECT id FROM steps WHERE plan_id = ? ORDER BY position, id", { plan_id })) do
    ids[#ids + 1] = row.id
  end
  return ids
end

---Rewrite positions so they are dense (1..n) in the given order.
---@param ids integer[]
function Store:renumber(ids)
  for position, id in ipairs(ids) do
    self.db:run("UPDATE steps SET position = ? WHERE id = ?", { position, id })
  end
end

---@param scope detritus.Scope
---@return detritus.Plan?
function Store:get_plan(scope)
  local plan = self:find_plan(scope)
  if not plan then
    return nil
  end
  local steps = {}
  for _, row in ipairs(self.db:all("SELECT * FROM steps WHERE plan_id = ? ORDER BY position, id", { plan.id })) do
    steps[#steps + 1] = hydrate(row)
  end
  return {
    id = plan.id,
    project = plan.project,
    branch = plan.branch,
    title = plan.title,
    updated_at = plan.updated_at,
    steps = steps,
  }
end

---@param scope detritus.Scope
---@param id integer
---@return detritus.Step?
function Store:get_step(scope, id)
  local plan = self:find_plan(scope)
  if not plan then
    return nil
  end
  local row = self.db:one("SELECT * FROM steps WHERE id = ? AND plan_id = ?", { id, plan.id })
  return row and hydrate(row) or nil
end

---@param plan_id integer
---@param normalized { text: string, details: string[], refs: detritus.Ref[] }
---@return integer id
function Store:insert_step(plan_id, normalized)
  local now = os.time()
  self.db:run(
    [[INSERT INTO steps (plan_id, position, text, details, refs, created_at, updated_at)
      VALUES (?, 0, ?, ?, ?, ?, ?)]],
    {
      plan_id,
      normalized.text,
      vim.json.encode(normalized.details),
      vim.json.encode(normalized.refs),
      now,
      now,
    }
  )
  return self.db:last_insert_rowid()
end

---Replace the whole plan for a scope. All steps start unchecked and unflagged.
---@param scope detritus.Scope
---@param input { title?: string, steps: detritus.StepInput[] }
---@return detritus.Plan
function Store:set_plan(scope, input)
  if type(input) ~= "table" or type(input.steps) ~= "table" then
    fail("steps must be an array")
  end
  local normalized = {}
  for i, step in ipairs(input.steps) do
    normalized[i] = normalize_step(step)
  end
  local title = input.title
  if title ~= nil and title ~= vim.NIL then
    title = clean_string(title, "title")
  else
    title = nil
  end
  self.db:transaction(function()
    local existing = self:find_plan(scope)
    if existing then
      self.db:run("DELETE FROM steps WHERE plan_id = ?", { existing.id })
      self.db:run("UPDATE plans SET title = ? WHERE id = ?", { title, existing.id })
    end
    local plan = self:ensure_plan(scope, title)
    local ids = {}
    for i, step in ipairs(normalized) do
      ids[i] = self:insert_step(plan.id, step)
    end
    self:renumber(ids)
    self:touch(plan.id)
  end)
  return assert(self:get_plan(scope))
end

---@param scope detritus.Scope
---@param title string
---@return detritus.Plan
function Store:set_title(scope, title)
  title = clean_string(title, "title")
  self.db:transaction(function()
    local plan = self:ensure_plan(scope, title)
    self.db:run("UPDATE plans SET title = ? WHERE id = ?", { title, plan.id })
    self:touch(plan.id)
  end)
  return assert(self:get_plan(scope))
end

---Add steps, appending by default or inserting after `after_id` (0 = at the start).
---@param scope detritus.Scope
---@param inputs detritus.StepInput[]
---@param after_id? integer
---@return detritus.Step[] added
function Store:add_steps(scope, inputs, after_id)
  if type(inputs) ~= "table" or #inputs == 0 then
    fail("steps must be a non-empty array")
  end
  local normalized = {}
  for i, step in ipairs(inputs) do
    normalized[i] = normalize_step(step)
  end
  local new_ids = {}
  self.db:transaction(function()
    local plan = self:ensure_plan(scope)
    local order = self:order(plan.id)
    local at = #order
    if after_id ~= nil and after_id ~= vim.NIL then
      if after_id == 0 then
        at = 0
      else
        at = nil
        for index, id in ipairs(order) do
          if id == after_id then
            at = index
            break
          end
        end
        if not at then
          fail(("step %s not found in this plan"):format(tostring(after_id)))
        end
      end
    end
    for i, step in ipairs(normalized) do
      new_ids[i] = self:insert_step(plan.id, step)
    end
    local merged = {}
    for i = 1, at do
      merged[#merged + 1] = order[i]
    end
    vim.list_extend(merged, new_ids)
    for i = at + 1, #order do
      merged[#merged + 1] = order[i]
    end
    self:renumber(merged)
    self:touch(plan.id)
  end)
  local added = {}
  for _, id in ipairs(new_ids) do
    added[#added + 1] = assert(self:get_step(scope, id))
  end
  return added
end

---Patch a step. If its text, details or refs actually change, the step is
---flagged `changed` and unchecked so the user knows to revisit it.
---@param scope detritus.Scope
---@param id integer
---@param patch { text?: string, details?: string[], refs?: detritus.Ref[] }
---@return detritus.Step step
---@return boolean modified
function Store:update_step(scope, id, patch)
  if type(patch) ~= "table" or (patch.text == nil and patch.details == nil and patch.refs == nil) then
    fail("provide at least one of text, details or refs to update")
  end
  local modified = false
  self.db:transaction(function()
    local plan = self:find_plan(scope)
    local current = plan and self:get_step(scope, id)
    if not plan or not current then
      fail(("step %s not found in this plan"):format(tostring(id)))
    end
    local text = current.text
    local details = current.details
    local refs = current.refs
    if patch.text ~= nil then
      text = clean_string(patch.text, "text")
    end
    if patch.details ~= nil then
      details = normalize_details(patch.details)
    end
    if patch.refs ~= nil then
      refs = normalize_refs(patch.refs)
    end
    modified = text ~= current.text
      or not vim.deep_equal(details, current.details)
      or not vim.deep_equal(refs, current.refs)
    if modified then
      self.db:run(
        "UPDATE steps SET text = ?, details = ?, refs = ?, done = 0, changed = 1, updated_at = ? WHERE id = ?",
        { text, vim.json.encode(details), vim.json.encode(refs), os.time(), id }
      )
      self:touch(plan.id)
    end
  end)
  return assert(self:get_step(scope, id)), modified
end

---Move a step to sit after `after_id` (0 = to the start). Reordering is not a
---content change, so it never flags the step.
---@param scope detritus.Scope
---@param id integer
---@param after_id integer
function Store:move_step(scope, id, after_id)
  self.db:transaction(function()
    local plan = self:find_plan(scope)
    if not plan or not self:get_step(scope, id) then
      fail(("step %s not found in this plan"):format(tostring(id)))
    end
    if after_id == id then
      fail("a step cannot be moved after itself")
    end
    local without = {}
    for _, existing in ipairs(self:order(plan.id)) do
      if existing ~= id then
        without[#without + 1] = existing
      end
    end
    local at
    if after_id == 0 then
      at = 0
    else
      for index, existing in ipairs(without) do
        if existing == after_id then
          at = index
          break
        end
      end
      if not at then
        fail(("step %s not found in this plan"):format(tostring(after_id)))
      end
    end
    table.insert(without, at + 1, id)
    self:renumber(without)
    self:touch(plan.id)
  end)
end

---@param scope detritus.Scope
---@param id integer
function Store:delete_step(scope, id)
  self.db:transaction(function()
    local plan = self:find_plan(scope)
    if not plan or not self:get_step(scope, id) then
      fail(("step %s not found in this plan"):format(tostring(id)))
    end
    self.db:run("DELETE FROM steps WHERE id = ?", { id })
    self:renumber(self:order(plan.id))
    self:touch(plan.id)
  end)
end

---Mark a step done or not done. Checking a step off acknowledges any ⚠️ flag.
---@param scope detritus.Scope
---@param id integer
---@param done boolean
function Store:set_done(scope, id, done)
  self.db:transaction(function()
    local plan = self:find_plan(scope)
    if not plan or not self:get_step(scope, id) then
      fail(("step %s not found in this plan"):format(tostring(id)))
    end
    if done then
      self.db:run("UPDATE steps SET done = 1, changed = 0, updated_at = ? WHERE id = ?", { os.time(), id })
    else
      self.db:run("UPDATE steps SET done = 0, updated_at = ? WHERE id = ?", { os.time(), id })
    end
    self:touch(plan.id)
  end)
end

---Delete the whole plan for a scope. Returns how many steps were removed.
---@param scope detritus.Scope
---@return integer removed
function Store:clear_plan(scope)
  local removed = 0
  self.db:transaction(function()
    local plan = self:find_plan(scope)
    if not plan then
      return
    end
    removed = self.db:scalar("SELECT COUNT(*) FROM steps WHERE plan_id = ?", { plan.id }) or 0
    self.db:run("DELETE FROM plans WHERE id = ?", { plan.id })
  end)
  return removed
end

---List every branch in a project that has a plan.
---@param project string
---@return { branch: string, title?: string, total: integer, done: integer, updated_at: integer }[]
function Store:list_plans(project)
  return self.db:all(
    [[SELECT p.branch AS branch, p.title AS title, p.updated_at AS updated_at,
             COUNT(s.id) AS total, COALESCE(SUM(s.done), 0) AS done
      FROM plans p LEFT JOIN steps s ON s.plan_id = p.id
      WHERE p.project = ?
      GROUP BY p.id
      ORDER BY p.updated_at DESC]],
    { project }
  )
end

return M
