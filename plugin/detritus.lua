if vim.g.loaded_detritus then
  return
end
vim.g.loaded_detritus = true

local subcommands = {
  toggle = function()
    require("detritus").toggle()
  end,
  open = function()
    require("detritus").open()
  end,
  close = function()
    require("detritus").close()
  end,
  refresh = function()
    require("detritus").refresh()
  end,
  branch = function()
    require("detritus").select_branch()
  end,
  clear = function()
    require("detritus").clear()
  end,
  mcp = function()
    local command = require("detritus").mcp_command()
    vim.notify("detritus MCP command:\n" .. table.concat(command, " "), vim.log.levels.INFO)
    vim.fn.setreg("+", table.concat(command, " "))
  end,
}

vim.api.nvim_create_user_command("Detritus", function(args)
  local name = args.fargs[1] or "toggle"
  local run = subcommands[name]
  if not run then
    vim.notify("detritus: unknown subcommand " .. name, vim.log.levels.ERROR)
    return
  end
  run()
end, {
  nargs = "?",
  desc = "detritus plan panel",
  complete = function(arglead)
    local names = vim.tbl_keys(subcommands)
    table.sort(names)
    return vim.tbl_filter(function(name)
      return vim.startswith(name, arglead)
    end, names)
  end,
})
