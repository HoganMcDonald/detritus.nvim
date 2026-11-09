local M = {}

function M.check()
  vim.health.start("detritus")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10+ is required")
  end

  local ok, err = pcall(function()
    require("detritus.sqlite").load()
  end)
  if ok then
    vim.health.ok("libsqlite3 loaded")
  else
    vim.health.error("libsqlite3 not found", { tostring(err) })
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git found")
  else
    vim.health.error("git not found (plans are partitioned by branch)")
  end

  local path = require("detritus.config").get().db_path or require("detritus.db").default_path()
  local opened, store = pcall(require("detritus.db").open, path)
  if opened then
    vim.health.ok("database writable: " .. path)
    store:close()
  else
    vim.health.error("cannot open database: " .. path, { tostring(store) })
  end
  if vim.env.DETRITUS_DB and vim.env.DETRITUS_DB ~= "" then
    vim.health.info("DETRITUS_DB is set; the MCP server must see the same value")
  elseif require("detritus.config").get().db_path then
    vim.health.warn(
      "db_path is customised",
      { "Set DETRITUS_DB to the same path in your agent's MCP server env so both use one database." }
    )
  end

  local edgy = pcall(require, "edgy")
  local layout = require("detritus.config").get().layout
  if layout == "edgy" and not edgy then
    vim.health.warn("layout = 'edgy' but edgy.nvim is not installed; falling back to a sidebar")
  elseif edgy then
    vim.health.ok("edgy.nvim found" .. (layout == "edgy" and "" or " (unused: layout = '" .. layout .. "')"))
  end

  vim.health.info("MCP command: " .. table.concat(require("detritus").mcp_command(), " "))
end

return M
