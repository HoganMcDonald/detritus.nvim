---Owns the panel's state: the store connection, the resolved scope, the buffer,
---and the watchers that keep the view in sync with the database and git.
local config = require("detritus.config")
local db = require("detritus.db")
local render = require("detritus.ui.render")
local scope_mod = require("detritus.scope")
local watch = require("detritus.watch")
local window = require("detritus.ui.window")

local M = {}

---@class detritus.PanelState
---@field store? detritus.Store
---@field scope? detritus.ResolvedScope Scope currently displayed
---@field real_branch? string Branch actually checked out (differs from scope.branch when pinned)
---@field pinned? string Branch chosen with :Detritus branch
---@field plan? detritus.Plan
---@field index? detritus.Index
---@field buf? integer
---@field collapsed table<integer, boolean>
---@field data_version? integer
---@field db_watcher? { stop: fun() }
---@field git_watcher? { stop: fun() }
---@field git_dir? string
---@field head? string Last seen contents of <git_dir>/HEAD
---@field timer? userdata
M.state = { collapsed = {} }
local state = M.state

local augroup

local function notify(message, level)
  vim.notify("detritus: " .. message, level or vim.log.levels.INFO)
end

---@return boolean
local function ensure_store()
  if state.store then
    return true
  end
  local ok, result = pcall(db.open, config.get().db_path)
  if not ok then
    notify(tostring(result), vim.log.levels.ERROR)
    return false
  end
  state.store = result
  state.data_version = result:data_version()
  return true
end

---Raw contents of <git_dir>/HEAD; cheap to read, changes on every checkout.
---@return string?
local function head_contents()
  local dir = state.scope and state.scope.git_dir
  if not dir then
    return nil
  end
  local file = io.open(vim.fs.joinpath(dir, "HEAD"), "r")
  if not file then
    return nil
  end
  local contents = file:read("*a")
  file:close()
  return contents
end

---Resolve the scope for the current cwd. Returns true if what we display changed.
---@return boolean changed
local function reload_scope()
  local resolved = scope_mod.resolve(vim.fn.getcwd())
  if state.real_branch and state.real_branch ~= resolved.branch then
    -- The checkout moved on; a pinned view of another branch is now stale.
    state.pinned = nil
  end
  state.real_branch = resolved.branch
  if state.pinned then
    resolved.branch = state.pinned
  end
  local previous = state.scope
  state.scope = resolved
  state.head = head_contents()
  return not previous or previous.project ~= resolved.project or previous.branch ~= resolved.branch
end

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "detritus://plan")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "detritus"
  state.buf = buf
  require("detritus.ui.actions").attach(buf)
  return buf
end

---Re-render from the database, keeping the cursor on the same step.
function M.refresh()
  if not state.store or not state.scope then
    return
  end
  local buf = ensure_buf()
  local ok, plan = pcall(state.store.get_plan, state.store, state.scope)
  if not ok then
    notify(tostring(plan), vim.log.levels.ERROR)
    return
  end
  state.plan = plan
  local cfg = config.get()
  local old = state.index
  local new = render.build(plan, state.scope, { collapsed = state.collapsed, icons = cfg.icons })
  state.index = new
  render.apply(buf, new)

  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local target = row
    local id = old and old.step_at[row]
    if id and new.first_line[id] then
      local offset = row - old.first_line[id]
      target = math.min(new.first_line[id] + offset, new.last_line[id])
    end
    target = math.max(1, math.min(target, #new.lines))
    pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "DetritusRefresh", modeline = false })
end

local function on_db_change()
  if not state.store then
    return
  end
  local ok, version = pcall(state.store.data_version, state.store)
  if ok and version ~= state.data_version then
    state.data_version = version
    M.refresh()
  end
end

---Fallback for platforms or filesystems where fs events are lossy: only runs
---while the panel is visible, and each tick is a PRAGMA plus a tiny file read.
local function poll()
  if not M.is_open() then
    return
  end
  on_db_change()
  local head = head_contents()
  if head ~= state.head then
    M.sync_scope()
  end
end

local function arm_git_watcher()
  local git_dir = state.scope and state.scope.git_dir
  if git_dir == state.git_dir then
    return
  end
  if state.git_watcher then
    state.git_watcher.stop()
    state.git_watcher = nil
  end
  state.git_dir = git_dir
  if git_dir then
    state.git_watcher = watch.dir(git_dir, function(name)
      return name == "HEAD"
    end, function()
      M.sync_scope()
    end, 100)
  end
end

local function start_watchers()
  if not state.db_watcher and state.store then
    local path = state.store.db.path
    local base = vim.fs.basename(path)
    state.db_watcher = watch.dir(vim.fs.dirname(path), function(name)
      return vim.startswith(name, base)
    end, on_db_change, 50)
  end
  arm_git_watcher()

  local interval = config.get().poll_ms
  if not state.timer and interval > 0 then
    state.timer = vim.uv.new_timer()
    state.timer:start(interval, interval, vim.schedule_wrap(poll))
  end

  if not augroup then
    augroup = vim.api.nvim_create_augroup("Detritus", { clear = true })
    vim.api.nvim_create_autocmd({ "FocusGained", "DirChanged" }, {
      group = augroup,
      callback = function()
        M.sync_scope()
        on_db_change()
      end,
    })
  end
end

---Re-resolve the scope (branch switch, cwd change) and refresh if it moved.
function M.sync_scope()
  if not state.store then
    return
  end
  if reload_scope() then
    arm_git_watcher()
    M.refresh()
  end
end

---@return boolean
function M.is_open()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf) and window.find(state.buf) ~= nil
end

---@param opts? { enter?: boolean }
---@return integer? win
function M.open(opts)
  opts = opts or {}
  local cfg = config.get()
  if not ensure_store() then
    return nil
  end
  reload_scope()
  local buf = ensure_buf()
  M.refresh()
  start_watchers()

  local enter = opts.enter
  if enter == nil then
    enter = cfg.enter
  end
  local existing = window.find(buf)
  if existing then
    if enter then
      vim.api.nvim_set_current_win(existing)
    end
    return existing
  end

  local win = window.open(buf, cfg, enter)
  -- Land on the first unchecked step rather than the header.
  local index = state.index
  if index and index.open_lines[1] and vim.api.nvim_win_get_cursor(win)[1] <= 3 then
    pcall(vim.api.nvim_win_set_cursor, win, { index.open_lines[1], 0 })
  end
  return win
end

function M.close()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    window.close(state.buf)
  end
end

---@param opts? { enter?: boolean }
function M.toggle(opts)
  if M.is_open() then
    M.close()
  else
    M.open(opts)
  end
end

---Pick which branch's plan to view in the current project.
function M.select_branch()
  if not ensure_store() then
    return
  end
  reload_scope()
  local scope = state.scope --[[@as detritus.ResolvedScope]]
  local items, seen = {}, {}
  for _, plan in ipairs(state.store:list_plans(scope.project)) do
    seen[plan.branch] = true
    items[#items + 1] = plan
  end
  if state.real_branch and not seen[state.real_branch] then
    table.insert(items, 1, { branch = state.real_branch, total = 0, done = 0 })
  end
  vim.ui.select(items, {
    prompt = "Plan for branch",
    format_item = function(item)
      local marker = item.branch == state.real_branch and "*" or " "
      local progress = item.total > 0 and ("  %d/%d"):format(item.done, item.total) or "  (no plan)"
      local title = item.title and ("  " .. item.title) or ""
      return ("%s %s%s%s"):format(marker, item.branch, progress, title)
    end,
  }, function(choice)
    if not choice then
      return
    end
    state.pinned = choice.branch ~= state.real_branch and choice.branch or nil
    reload_scope()
    arm_git_watcher()
    M.refresh()
  end)
end

---Delete the displayed plan after confirmation.
function M.clear()
  if not ensure_store() then
    return
  end
  reload_scope()
  local scope = state.scope --[[@as detritus.ResolvedScope]]
  local message = ("Clear the plan for %s?"):format(scope.branch)
  if vim.fn.confirm(message, "&Yes\n&No", 2) ~= 1 then
    return
  end
  local removed = state.store:clear_plan(scope)
  notify(("cleared %d step%s"):format(removed, removed == 1 and "" or "s"))
  M.refresh()
end

---Progress for statuslines, e.g. "2/5". Empty when there is no plan.
---@return string
function M.status()
  local index = state.index
  if not index or index.total == 0 then
    return ""
  end
  return ("%d/%d"):format(index.done, index.total)
end

---Called after setup() so a re-configured plugin picks up new keymaps/layout.
function M.reconfigure()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    require("detritus.ui.actions").attach(state.buf)
    M.refresh()
  end
end

return M
