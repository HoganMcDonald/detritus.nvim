---MCP tool definitions and handlers.
local scope = require("detritus.scope")

local M = {}

M.instructions = [[
detritus keeps a short, manual to-do list of implementation steps that the USER will carry out by hand in Neovim. It is the hand-off point after planning: when the user says they want to implement a plan themselves, decompose it into steps and store them here instead of writing the code.

How to write steps:
- One sentence each, small and isolated. A step is something a person can finish and check off in a sitting.
- Say WHAT must exist or hold, never HOW to build it. "Add a `SessionToken` struct with `user_id` and `expires_at`", not a code listing.
- Use `details` (a short list of strings) for properties, invariants or cases a step must cover, e.g. what a constructor must validate or test for. Do not explain how to implement them.
- Attach `refs` for the files and symbols a step touches: {path, line?, symbol?}. The user jumps to them with `gd`. Prefer `symbol` over `line`, since lines drift. Paths are relative to the repository root.
- Order steps so each can be done after the ones above it (types before the code that uses them).
- Wrap code identifiers in backticks in `text` and `details`.

Working with an existing plan:
- Call `get_plan` first; the user may have already checked steps off. Do not wipe their progress with `set_plan` unless they ask for a fresh plan.
- To revise a step, use `update_step`. If its text, details or refs change, the step is flagged with a warning and unchecked so the user knows to revisit it. Do not delete and re-add a step to change it.
- Use `add_steps`, `move_step` and `delete_step` for structural changes, and `clear_plan` only when the user asks to start over.
- You cannot check steps off; only the user does that.

Plans are partitioned per git branch of the project in the server's working directory. Pass `project_dir` or `branch` only to target a different repository or branch.
]]

local scope_properties = {
  project_dir = {
    type = "string",
    description = "Directory of the repository to use. Defaults to the server's working directory.",
  },
  branch = {
    type = "string",
    description = "Branch whose plan to use. Defaults to the branch checked out in project_dir.",
  },
}

local function with_scope(properties)
  return vim.tbl_extend("force", {}, scope_properties, properties or {})
end

local step_input = {
  type = "object",
  properties = {
    text = { type = "string", description = "One sentence describing the step. Say what, not how." },
    details = {
      type = "array",
      items = { type = "string" },
      description = "Short bullets: properties, invariants or cases the step must cover.",
    },
    refs = {
      type = "array",
      description = "Files and symbols the step touches. The user jumps to these with gd.",
      items = {
        type = "object",
        properties = {
          path = { type = "string", description = "Path relative to the repository root." },
          line = { type = "integer", minimum = 1 },
          symbol = { type = "string", description = "e.g. `SessionToken` or `SessionToken::new`." },
        },
      },
    },
  },
  required = { "text" },
}

local step_id = { type = "integer", description = "Step id from get_plan." }

---@class detritus.Tool
---@field name string
---@field description string
---@field inputSchema table
---@field handler fun(store: detritus.Store, scope: detritus.ResolvedScope, args: table): table

---@param plan detritus.Plan?
---@param s detritus.ResolvedScope
local function plan_payload(plan, s)
  local steps, done = {}, 0
  for _, step in ipairs(plan and plan.steps or {}) do
    if step.done then
      done = done + 1
    end
    steps[#steps + 1] = {
      id = step.id,
      position = step.position,
      text = step.text,
      details = step.details,
      refs = step.refs,
      done = step.done,
      changed = step.changed,
    }
  end
  return {
    project = s.project,
    branch = s.branch,
    title = plan and plan.title or nil,
    progress = { done = done, total = #steps },
    steps = steps,
  }
end

---@type detritus.Tool[]
M.tools = {
  {
    name = "get_plan",
    description = "Get the plan for the current branch: title, progress, and every step with its id, done and changed state.",
    inputSchema = { type = "object", properties = with_scope() },
    handler = function(store, s)
      return plan_payload(store:get_plan(s), s)
    end,
  },
  {
    name = "get_step",
    description = "Get a single step by id.",
    inputSchema = { type = "object", properties = with_scope({ id = step_id }), required = { "id" } },
    handler = function(store, s, args)
      local step = store:get_step(s, args.id)
      if not step then
        error(("step %s not found in this plan"):format(tostring(args.id)), 0)
      end
      return step
    end,
  },
  {
    name = "set_plan",
    description = "Replace the entire plan for this branch with a new ordered list of steps. This discards existing steps and the user's progress; prefer add_steps / update_step on an existing plan.",
    inputSchema = {
      type = "object",
      properties = with_scope({
        title = { type = "string", description = "Short title for the plan, e.g. the feature name." },
        steps = { type = "array", items = step_input, description = "Ordered steps." },
      }),
      required = { "steps" },
    },
    handler = function(store, s, args)
      return plan_payload(store:set_plan(s, { title = args.title, steps = args.steps }), s)
    end,
  },
  {
    name = "update_plan",
    description = "Set the plan's title.",
    inputSchema = { type = "object", properties = with_scope({ title = { type = "string" } }), required = { "title" } },
    handler = function(store, s, args)
      return plan_payload(store:set_title(s, args.title), s)
    end,
  },
  {
    name = "add_steps",
    description = "Add one or more steps. Appends by default; pass after_step_id to insert after a step (0 inserts at the start).",
    inputSchema = {
      type = "object",
      properties = with_scope({
        steps = { type = "array", items = step_input, minItems = 1 },
        after_step_id = {
          type = "integer",
          minimum = 0,
          description = "Insert after this step id; 0 for the very start. Omit to append.",
        },
      }),
      required = { "steps" },
    },
    handler = function(store, s, args)
      local added = store:add_steps(s, args.steps, args.after_step_id)
      return { added = added, plan = plan_payload(store:get_plan(s), s) }
    end,
  },
  {
    name = "update_step",
    description = "Change a step's text, details or refs. If anything actually changes, the step is flagged with a warning and unchecked in the user's panel so they know to revisit it. Only the fields you pass are changed.",
    inputSchema = {
      type = "object",
      properties = with_scope({
        id = step_id,
        text = step_input.properties.text,
        details = step_input.properties.details,
        refs = step_input.properties.refs,
      }),
      required = { "id" },
    },
    handler = function(store, s, args)
      local step, modified = store:update_step(s, args.id, {
        text = args.text,
        details = args.details,
        refs = args.refs,
      })
      return {
        step = step,
        modified = modified,
        note = modified and "Step flagged with a warning and unchecked for the user." or "Nothing changed.",
      }
    end,
  },
  {
    name = "move_step",
    description = "Reorder a step so it sits after another step (after_step_id = 0 moves it to the start). Does not flag the step.",
    inputSchema = {
      type = "object",
      properties = with_scope({
        id = step_id,
        after_step_id = { type = "integer", minimum = 0, description = "Place after this step id; 0 for the start." },
      }),
      required = { "id", "after_step_id" },
    },
    handler = function(store, s, args)
      store:move_step(s, args.id, args.after_step_id)
      return plan_payload(store:get_plan(s), s)
    end,
  },
  {
    name = "delete_step",
    description = "Delete a step.",
    inputSchema = { type = "object", properties = with_scope({ id = step_id }), required = { "id" } },
    handler = function(store, s, args)
      store:delete_step(s, args.id)
      return plan_payload(store:get_plan(s), s)
    end,
  },
  {
    name = "clear_plan",
    description = "Delete the whole plan for this branch. Only do this when the user asks to start over.",
    inputSchema = { type = "object", properties = with_scope() },
    handler = function(store, s)
      return { removed_steps = store:clear_plan(s), project = s.project, branch = s.branch }
    end,
  },
  {
    name = "list_plans",
    description = "List every branch in this project that has a plan, with progress.",
    inputSchema = { type = "object", properties = with_scope() },
    handler = function(store, s)
      return { project = s.project, plans = store:list_plans(s.project) }
    end,
  },
}

local by_name = {}
for _, tool in ipairs(M.tools) do
  by_name[tool.name] = tool
end

---Tool descriptors for `tools/list`.
---@return table[]
function M.list()
  return vim.tbl_map(function(tool)
    return { name = tool.name, description = tool.description, inputSchema = tool.inputSchema }
  end, M.tools)
end

---Resolve the plan scope for a call: server cwd by default, overridable per call.
---@param args table
---@return detritus.ResolvedScope
local function resolve_scope(args)
  local dir = args.project_dir
  if dir ~= nil and dir ~= vim.NIL then
    if type(dir) ~= "string" or vim.fn.isdirectory(vim.fn.expand(dir)) == 0 then
      error("project_dir must be an existing directory", 0)
    end
    dir = vim.fn.expand(dir)
  else
    dir = nil
  end
  local resolved = scope.resolve(dir)
  if args.branch ~= nil and args.branch ~= vim.NIL then
    if type(args.branch) ~= "string" or args.branch == "" then
      error("branch must be a non-empty string", 0)
    end
    resolved.branch = args.branch
  end
  return resolved
end

---Run a tool. Always returns an MCP tool result; failures become `isError`.
---@param store detritus.Store
---@param name string
---@param args? table
---@return table result
---@return boolean known
function M.call(store, name, args)
  local tool = by_name[name]
  if not tool then
    return {}, false
  end
  args = type(args) == "table" and args or {}
  local ok, payload = pcall(function()
    return tool.handler(store, resolve_scope(args), args)
  end)
  if not ok then
    return { isError = true, content = { { type = "text", text = tostring(payload) } } }, true
  end
  return { content = { { type = "text", text = vim.json.encode(payload) } } }, true
end

---Guidance exposed as an MCP prompt.
---@param goal? string
---@return string
function M.decompose_prompt(goal)
  local lines = {
    "I want to implement this myself. Decompose the work into small manual implementation steps and store them with the detritus tools (set_plan, or add_steps on an existing plan).",
    "",
    "Follow the detritus guidance: one sentence per step, say what not how, put invariants in `details`, attach `refs` for files and symbols, and order steps so each can be done after the ones above it.",
  }
  if goal and goal ~= "" then
    vim.list_extend(lines, { "", "Goal: " .. goal })
  else
    vim.list_extend(lines, { "", "Use the feature we just planned as the goal." })
  end
  return table.concat(lines, "\n")
end

return M
