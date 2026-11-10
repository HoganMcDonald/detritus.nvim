local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
local root = vim.fs.dirname(here)
vim.opt.rtp:prepend(root)
package.path = here .. "/?.lua;" .. package.path

local harness = require("harness")

local only = arg and arg[1]
local files = vim.fn.glob(here .. "/*_spec.lua", false, true)
table.sort(files)
for _, file in ipairs(files) do
  if not only or file:find(only, 1, true) then
    io.stdout:write(vim.fs.basename(file), "\n")
    dofile(file)
  end
end

io.stdout:write(("\n%d passed, %d failed\n"):format(harness.passed, harness.failed))
io.stdout:flush()
os.exit(harness.failed == 0 and 0 or 1)
