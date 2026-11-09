---Resolve which plan a directory belongs to: `project` is the repository's
---common git dir (shared by all worktrees), `branch` is the checked-out branch.
local M = {}

---@param args string[]
---@param cwd string
---@return string?
local function git(args, cwd)
  local ok, res = pcall(function()
    return vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait(3000)
  end)
  if not ok or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout)
end

---@param path string
---@return string
local function real(path)
  return vim.uv.fs_realpath(path) or path
end

---@class detritus.ResolvedScope: detritus.Scope
---@field git_dir? string
---@field is_git boolean

---@param cwd? string
---@return detritus.ResolvedScope
function M.resolve(cwd)
  cwd = real(cwd or vim.uv.cwd() or ".")

  local dirs = git({ "rev-parse", "--path-format=absolute", "--git-common-dir", "--absolute-git-dir" }, cwd)
  if not dirs then
    return { project = cwd, branch = "_", root = cwd, is_git = false }
  end
  local common, git_dir = unpack(vim.split(dirs, "\n", { plain = true }))
  common = real(common)
  -- Normal repos: <root>/.git -> <root>. Bare repos keep their own path.
  local project = common:gsub("/%.git/?$", "")

  local root = git({ "rev-parse", "--show-toplevel" }, cwd)

  local branch = git({ "symbolic-ref", "--short", "-q", "HEAD" }, cwd)
  if not branch or branch == "" then
    local sha = git({ "rev-parse", "--short", "HEAD" }, cwd)
    branch = sha and ("@" .. sha) or "HEAD"
  end

  return {
    project = project,
    branch = branch,
    root = root and real(root) or cwd,
    git_dir = git_dir and real(git_dir) or nil,
    is_git = true,
  }
end

return M
