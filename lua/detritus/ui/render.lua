---Turns a plan into buffer lines, highlight marks and lookup tables.
local M = {}

M.ns = vim.api.nvim_create_namespace("detritus")

---@class detritus.Mark
---@field line integer 0-based
---@field col integer
---@field end_col integer
---@field hl string

---@class detritus.Index
---@field lines string[]
---@field marks detritus.Mark[]
---@field step_at table<integer, integer> 1-based line -> step id
---@field ref_at table<integer, detritus.Ref> 1-based line -> ref shown on that line
---@field first_line table<integer, integer> step id -> first 1-based line
---@field last_line table<integer, integer> step id -> last 1-based line
---@field open_lines integer[] first lines of unchecked steps, in order
---@field done integer
---@field total integer

local function define_highlights()
  local links = {
    DetritusTitle = "Title",
    DetritusProgress = "Special",
    DetritusBranch = "Comment",
    DetritusTodo = "Normal",
    DetritusDoneIcon = "DiagnosticOk",
    DetritusDone = "Comment",
    DetritusChanged = "DiagnosticWarn",
    DetritusDetail = "Normal",
    DetritusBullet = "Comment",
    DetritusRef = "Directory",
    DetritusCode = "@markup.raw",
    DetritusHint = "Comment",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })

---@param ref detritus.Ref
---@return string
function M.ref_label(ref)
  local label = ref.path or ""
  if ref.line then
    label = label .. ":" .. ref.line
  end
  if ref.symbol then
    label = (label ~= "" and (label .. "  ") or "") .. ref.symbol
  end
  return label
end

---Add DetritusCode marks for each `backticked` span in `text`, offset by `base` bytes.
local function code_marks(marks, line, text, base)
  local init = 1
  while true do
    local s, e = text:find("`[^`]+`", init)
    if not s then
      return
    end
    marks[#marks + 1] = { line = line, col = base + s - 1, end_col = base + e, hl = "DetritusCode" }
    init = e + 1
  end
end

---@param plan detritus.Plan?
---@param scope detritus.Scope
---@param opts { collapsed: table<integer, boolean>, icons: table }
---@return detritus.Index
function M.build(plan, scope, opts)
  local icons = opts.icons
  ---@type detritus.Index
  local index = {
    lines = {},
    marks = {},
    step_at = {},
    ref_at = {},
    first_line = {},
    last_line = {},
    open_lines = {},
    done = 0,
    total = 0,
  }
  local lines, marks = index.lines, index.marks

  local function push(text)
    lines[#lines + 1] = text
    return #lines
  end

  local steps = plan and plan.steps or {}
  index.total = #steps
  for _, step in ipairs(steps) do
    if step.done then
      index.done = index.done + 1
    end
  end

  -- Header
  local title = (plan and plan.title) or "Plan"
  local progress = index.total > 0 and ("  %d/%d"):format(index.done, index.total) or ""
  local l = push(" " .. title .. progress)
  marks[#marks + 1] = { line = l - 1, col = 0, end_col = 1 + #title, hl = "DetritusTitle" }
  if progress ~= "" then
    marks[#marks + 1] = { line = l - 1, col = 1 + #title, end_col = #lines[l], hl = "DetritusProgress" }
  end
  local branch_line = " " .. (icons.branch ~= "" and (icons.branch .. " ") or "") .. scope.branch
  l = push(branch_line)
  marks[#marks + 1] = { line = l - 1, col = 0, end_col = #branch_line, hl = "DetritusBranch" }
  push("")

  if #steps == 0 then
    local hints = {
      " No steps for this branch yet.",
      "",
      " Ask your agent to decompose a task",
      " with the detritus MCP tools,",
      " or press a to add a step.",
    }
    for _, hint in ipairs(hints) do
      l = push(hint)
      marks[#marks + 1] = { line = l - 1, col = 0, end_col = #hint, hl = "DetritusHint" }
    end
    return index
  end

  for _, step in ipairs(steps) do
    local icon = step.done and icons.done or icons.todo
    local warn = (step.changed and not step.done) and (icons.changed .. " ") or ""
    local collapsed = opts.collapsed[step.id]
    local extra = #step.details + #step.refs
    local suffix = (collapsed and extra > 0) and ("  +" .. extra) or ""
    local prefix = " " .. icon .. " " .. warn
    local text_line = prefix .. step.text .. suffix
    local first = push(text_line)
    index.first_line[step.id] = first
    index.step_at[first] = step.id
    if not step.done then
      index.open_lines[#index.open_lines + 1] = first
    end

    marks[#marks + 1] = {
      line = first - 1,
      col = 1,
      end_col = 1 + #icon,
      hl = step.done and "DetritusDoneIcon" or "DetritusTodo",
    }
    if warn ~= "" then
      marks[#marks + 1] = { line = first - 1, col = 1 + #icon + 1, end_col = #prefix, hl = "DetritusChanged" }
    end
    marks[#marks + 1] = {
      line = first - 1,
      col = #prefix,
      end_col = #prefix + #step.text,
      hl = step.done and "DetritusDone" or "DetritusTodo",
    }
    if not step.done then
      code_marks(marks, first - 1, step.text, #prefix)
    end
    if suffix ~= "" then
      marks[#marks + 1] = { line = first - 1, col = #prefix + #step.text, end_col = #text_line, hl = "DetritusHint" }
    end

    local last = first
    if not collapsed then
      for _, detail in ipairs(step.details) do
        local bullet = "     " .. icons.bullet .. " "
        last = push(bullet .. detail)
        index.step_at[last] = step.id
        marks[#marks + 1] = { line = last - 1, col = 0, end_col = #bullet, hl = "DetritusBullet" }
        marks[#marks + 1] = {
          line = last - 1,
          col = #bullet,
          end_col = #lines[last],
          hl = step.done and "DetritusDone" or "DetritusDetail",
        }
        if not step.done then
          code_marks(marks, last - 1, detail, #bullet)
        end
      end
      for _, ref in ipairs(step.refs) do
        local lead = "     " .. icons.ref .. " "
        last = push(lead .. M.ref_label(ref))
        index.step_at[last] = step.id
        index.ref_at[last] = ref
        marks[#marks + 1] = { line = last - 1, col = 0, end_col = #lead, hl = "DetritusBullet" }
        marks[#marks + 1] = { line = last - 1, col = #lead, end_col = #lines[last], hl = "DetritusRef" }
      end
    end
    index.last_line[step.id] = last
  end

  return index
end

---Write a built index into a buffer.
---@param buf integer
---@param index detritus.Index
function M.apply(buf, index)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, index.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, mark in ipairs(index.marks) do
    vim.api.nvim_buf_set_extmark(buf, M.ns, mark.line, mark.col, { end_col = mark.end_col, hl_group = mark.hl })
  end
end

return M
