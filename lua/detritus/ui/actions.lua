---Buffer-local keymaps and their handlers.
local config = require("detritus.config")
local navigate = require("detritus.ui.navigate")
local panel = require("detritus.ui.panel")

local M = {}

local function state()
  return panel.state
end

---Step under the cursor, if any.
---@return detritus.Step?
local function current_step()
  local s = state()
  if not s.index or not s.plan then
    return nil
  end
  local id = s.index.step_at[vim.api.nvim_win_get_cursor(0)[1]]
  if not id then
    return nil
  end
  for _, step in ipairs(s.plan.steps) do
    if step.id == id then
      return step
    end
  end
end

---@param fn fun()
local function guarded(fn)
  local ok, err = pcall(fn)
  if not ok then
    vim.notify("detritus: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function set_cursor_to_step(id)
  local line = state().index and state().index.first_line[id]
  if line then
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  end
end

local handlers = {}

handlers.toggle = function()
  local step = current_step()
  if not step then
    return
  end
  guarded(function()
    state().store:set_done(state().scope, step.id, not step.done)
    panel.refresh()
  end)
end

handlers.goto_ref = function()
  navigate.goto_ref()
end

handlers.add = function()
  local s = state()
  local after = current_step()
  vim.ui.input({ prompt = "New step: " }, function(text)
    if not text or vim.trim(text) == "" then
      return
    end
    guarded(function()
      local added = s.store:add_steps(s.scope, { { text = text } }, after and after.id or nil)
      panel.refresh()
      if added[1] and vim.bo.filetype == "detritus" then
        set_cursor_to_step(added[1].id)
      end
    end)
  end)
end

handlers.delete = function()
  local step = current_step()
  if not step then
    return
  end
  local label = step.text:sub(1, 60)
  if vim.fn.confirm(("Delete step?\n%s"):format(label), "&Yes\n&No", 2) ~= 1 then
    return
  end
  guarded(function()
    state().store:delete_step(state().scope, step.id)
    panel.refresh()
  end)
end

handlers.fold = function()
  local step = current_step()
  if not step or (#step.details + #step.refs) == 0 then
    return
  end
  local collapsed = state().collapsed
  collapsed[step.id] = not collapsed[step.id] or nil
  panel.refresh()
end

handlers.fold_all = function()
  local s = state()
  for _, step in ipairs(s.plan and s.plan.steps or {}) do
    if #step.details + #step.refs > 0 then
      s.collapsed[step.id] = true
    end
  end
  panel.refresh()
end

handlers.unfold_all = function()
  state().collapsed = {}
  panel.refresh()
end

---@param direction 1|-1
local function jump_open(direction)
  local s = state()
  if not s.index then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local here = s.index.step_at[row]
  local lines = s.index.open_lines
  local target
  if direction == 1 then
    for _, line in ipairs(lines) do
      if line > row and s.index.step_at[line] ~= here then
        target = line
        break
      end
    end
  else
    for i = #lines, 1, -1 do
      local line = lines[i]
      -- Skip back past the step we are inside (including its detail lines).
      if line < row and s.index.step_at[line] ~= here then
        target = line
        break
      end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

handlers.next_open = function()
  jump_open(1)
end

handlers.prev_open = function()
  jump_open(-1)
end

handlers.refresh = function()
  panel.sync_scope()
  panel.refresh()
end

handlers.close = function()
  panel.close()
end

local descriptions = {
  toggle = "Toggle done",
  goto_ref = "Go to referenced file / symbol",
  add = "Add a step after this one",
  delete = "Delete step",
  fold = "Fold / unfold details",
  fold_all = "Fold all details",
  unfold_all = "Unfold all details",
  next_open = "Next unchecked step",
  prev_open = "Previous unchecked step",
  refresh = "Refresh",
  close = "Close panel",
  help = "This help",
}

local order = {
  "toggle",
  "goto_ref",
  "add",
  "delete",
  "fold",
  "fold_all",
  "unfold_all",
  "next_open",
  "prev_open",
  "refresh",
  "close",
  "help",
}

handlers.help = function()
  local keys = config.get().keys
  local lines = { " detritus keys", "" }
  for _, action in ipairs(order) do
    local lhs = keys[action]
    if lhs then
      lines[#lines + 1] = (" %-10s %s"):format(
        table.concat(type(lhs) == "table" and lhs or { lhs }, " "),
        descriptions[action]
      )
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = " press q or <Esc> to close"

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width + 2,
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
  })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
end

---Track mapped keys per buffer so reconfiguring removes stale ones.
local mapped = {}

---@param buf integer
function M.attach(buf)
  for _, lhs in ipairs(mapped[buf] or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  mapped[buf] = {}
  for action, lhs in pairs(config.get().keys) do
    local handler = handlers[action]
    if handler and lhs then
      for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
        vim.keymap.set("n", key, handler, {
          buffer = buf,
          nowait = true,
          silent = true,
          desc = "detritus: " .. (descriptions[action] or action),
        })
        mapped[buf][#mapped[buf] + 1] = key
      end
    end
  end
end

return M
