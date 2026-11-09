---Window placement for the panel. The buffer is created once and reused, so the
---panel is persistent: closing the window only hides it.
local M = {}

---@param buf integer
---@return integer? win Window showing `buf` in the current tab
function M.find(buf)
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_tabpage(win) == tab then
      return win
    end
  end
end

local window_options = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  foldenable = false,
  wrap = true,
  linebreak = true,
  breakindent = true,
  breakindentopt = "shift:2",
  cursorline = true,
  list = false,
  spell = false,
  statuscolumn = "",
}

---@param win integer
local function style(win)
  for name, value in pairs(window_options) do
    vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
end

---@param value number
---@param total integer
---@return integer
local function size(value, total)
  if value <= 1 then
    return math.max(1, math.floor(total * value))
  end
  return math.min(total, math.floor(value))
end

local function has_edgy()
  return package.loaded["edgy"] ~= nil or pcall(require, "edgy")
end

---@param buf integer
---@param cfg detritus.Config
---@param enter boolean
---@return integer win
local function open_float(buf, cfg, enter)
  local width = size(cfg.float.width, vim.o.columns)
  local height = size(cfg.float.height, vim.o.lines - vim.o.cmdheight - 2)
  local win = vim.api.nvim_open_win(buf, enter, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = cfg.float.border,
    title = " detritus ",
    title_pos = "center",
  })
  style(win)
  return win
end

---@param buf integer
---@param cfg detritus.Config
---@param enter boolean
---@return integer win
local function open_split(buf, cfg, enter)
  local previous = vim.api.nvim_get_current_win()
  -- `win = -1` splits the whole screen, so this is always the far right edge.
  local win = vim.api.nvim_open_win(buf, true, { split = "right", win = -1, width = cfg.width })
  style(win)
  if cfg.layout == "sidebar" then
    vim.api.nvim_set_option_value("winfixwidth", true, { win = win, scope = "local" })
  end
  if not enter and vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  return win
end

---Open a window for `buf` according to the configured layout.
---@param buf integer
---@param cfg detritus.Config
---@param enter boolean
---@return integer win
function M.open(buf, cfg, enter)
  if cfg.layout == "float" then
    return open_float(buf, cfg, enter)
  end
  -- Edgy adopts any window whose filetype matches one of its views, so the
  -- edgy layout is a plain right split plus a matching edgy view entry.
  -- Without edgy installed it degrades to a regular sidebar.
  if cfg.layout == "edgy" and not has_edgy() then
    cfg = vim.tbl_extend("force", cfg, { layout = "sidebar" })
  end
  return open_split(buf, cfg, enter)
end

---Close every window showing `buf` in the current tab.
---@param buf integer
function M.close(buf)
  local win = M.find(buf)
  while win do
    local edgy_win
    if package.loaded["edgy"] then
      local ok, found = pcall(function()
        return require("edgy").get_win(win)
      end)
      edgy_win = ok and found or nil
    end
    if edgy_win then
      edgy_win:close()
    else
      pcall(vim.api.nvim_win_close, win, true)
    end
    local again = M.find(buf)
    if again == win then
      return
    end
    win = again
  end
end

return M
