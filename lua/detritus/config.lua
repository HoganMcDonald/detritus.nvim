local M = {}

---@alias detritus.Layout "edgy" | "float" | "sidebar"

---@class detritus.Config
---@field layout detritus.Layout `edgy` hands the window to edgy.nvim, `sidebar` is a plain right-hand split, `float` is a centered float
---@field width number Width in columns of the sidebar / edgy split
---@field float { width: number, height: number, border: string|string[] } Fractions (<= 1) or absolute sizes
---@field db_path? string Defaults to $DETRITUS_DB or ~/.local/share/detritus/detritus.db; keep it in sync with the MCP server
---@field icons { done: string, todo: string, changed: string, bullet: string, ref: string, branch: string }
---@field keys table<string, string|string[]|false> Buffer-local keymaps for the panel; `false` disables one
---@field enter boolean Focus the panel when opening it
---@field poll_ms integer Safety-net poll interval (ms) while the panel is visible; 0 disables. File watching is the primary mechanism
M.defaults = {
  layout = "edgy",
  width = 50,
  float = { width = 0.4, height = 0.6, border = "rounded" },
  db_path = nil,
  icons = { done = "✓", todo = "☐", changed = "⚠️", bullet = "•", ref = "↳", branch = "\u{e0a0}" },
  keys = {
    toggle = { "x", "<CR>" },
    goto_ref = "gd",
    add = "a",
    delete = "dd",
    fold = "za",
    fold_all = "zM",
    unfold_all = "zR",
    next_open = "]]",
    prev_open = "[[",
    refresh = "R",
    close = "q",
    help = "?",
  },
  enter = true,
  poll_ms = 1000,
}

---@type detritus.Config
M.options = vim.deepcopy(M.defaults)

local layouts = { edgy = true, float = true, sidebar = true }

---@param opts? table
---@return detritus.Config
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  vim.validate("layout", merged.layout, function(v)
    return layouts[v] == true
  end, "one of 'edgy', 'float' or 'sidebar'")
  vim.validate("width", merged.width, "number")
  M.options = merged
  return merged
end

---@return detritus.Config
function M.get()
  return M.options
end

return M
