---Tiny dependency-free test harness for `nvim --headless --clean -l tests/run.lua`.
local M = { passed = 0, failed = 0, failures = {} }

local path = {}

local function out(s)
  io.stdout:write(s, "\n")
end

function _G.describe(name, fn)
  path[#path + 1] = name
  fn()
  path[#path] = nil
end

function _G.it(name, fn)
  local full = table.concat(path, " > ") .. " > " .. name
  local ok, err = xpcall(fn, function(e)
    return debug.traceback(tostring(e), 2)
  end)
  if ok then
    M.passed = M.passed + 1
    out("  ok   " .. full)
  else
    M.failed = M.failed + 1
    M.failures[#M.failures + 1] = full
    out("  FAIL " .. full .. "\n" .. err)
  end
end

local T = {}

function T.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      (msg and (msg .. ": ") or "") .. "expected " .. vim.inspect(expected) .. "\n     got " .. vim.inspect(actual),
      2
    )
  end
end

function T.truthy(value, msg)
  if not value then
    error(msg or ("expected truthy, got " .. vim.inspect(value)), 2)
  end
end

function T.falsy(value, msg)
  if value then
    error(msg or ("expected falsy, got " .. vim.inspect(value)), 2)
  end
end

---Assert `fn` raises an error whose message contains `pattern` (plain match).
function T.throws(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    error("expected an error but none was raised", 2)
  end
  if pattern and not tostring(err):find(pattern, 1, true) then
    error(("expected error containing %q, got %q"):format(pattern, tostring(err)), 2)
  end
end

M.t = T

---Fresh temp directory removed by the caller (or left to the OS).
function M.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return (vim.uv.fs_realpath(dir))
end

---@param args string[]
---@param cwd string
function M.git(args, cwd)
  local res = vim
    .system(vim.list_extend({ "git", "-c", "user.email=t@t", "-c", "user.name=t" }, args), {
      cwd = cwd,
      text = true,
    })
    :wait()
  if res.code ~= 0 then
    error("git " .. table.concat(args, " ") .. " failed: " .. (res.stderr or ""))
  end
  return vim.trim(res.stdout)
end

---Temp git repo with one commit on branch `main`.
function M.repo()
  local dir = M.tmpdir()
  M.git({ "init", "-q", "-b", "main" }, dir)
  vim.fn.writefile({ "hello" }, dir .. "/README.md")
  M.git({ "add", "." }, dir)
  M.git({ "commit", "-q", "-m", "init" }, dir)
  return dir
end

return M
