---detritus.nvim: a persistent panel for the manual implementation plan an agent
---hands you over MCP.
local M = {}

---Keep in sync with the latest release tag (see CHANGELOG.md).
M.version = "0.1.0"

---@param opts? table See detritus.config
function M.setup(opts)
  require("detritus.config").setup(opts)
  require("detritus.ui.panel").reconfigure()
end

---@param opts? { enter?: boolean }
function M.open(opts)
  return require("detritus.ui.panel").open(opts)
end

function M.close()
  require("detritus.ui.panel").close()
end

---@param opts? { enter?: boolean }
function M.toggle(opts)
  require("detritus.ui.panel").toggle(opts)
end

function M.refresh()
  local panel = require("detritus.ui.panel")
  panel.sync_scope()
  panel.refresh()
end

---Pick another branch's plan to view.
function M.select_branch()
  require("detritus.ui.panel").select_branch()
end

---Delete the displayed plan (asks first).
function M.clear()
  require("detritus.ui.panel").clear()
end

---@return boolean
function M.is_open()
  return require("detritus.ui.panel").is_open()
end

---Progress such as "2/5" for statuslines; empty when there is no plan.
---@return string
function M.status()
  return require("detritus.ui.panel").status()
end

---Entry for edgy.nvim's `right`/`left` lists.
---@param overrides? table
---@return table
function M.edgy_view(overrides)
  return vim.tbl_extend("force", { title = "Plan", ft = "detritus" }, overrides or {})
end

---The plugin's root directory.
---@return string
function M.root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(source))))
end

---Command that starts the MCP server over stdio, for any agent harness.
---@return string[]
function M.mcp_command()
  return { "nvim", "--headless", "--clean", "-l", vim.fs.joinpath(M.root(), "bin", "detritus-mcp.lua") }
end

return M
