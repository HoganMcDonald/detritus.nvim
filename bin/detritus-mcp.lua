-- detritus MCP server entry point.
--
--   nvim --headless --clean -l /path/to/detritus.nvim/bin/detritus-mcp.lua
--
-- Speaks MCP over stdio. The plan database defaults to
-- ~/.local/share/detritus/detritus.db; override it with $DETRITUS_DB.
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(source)))
vim.opt.rtp:prepend(root)

local ok, err = pcall(function()
  require("detritus.mcp.server").run()
end)
if not ok then
  io.stderr:write("[detritus-mcp] fatal: ", tostring(err), "\n")
  os.exit(1)
end
os.exit(0)
