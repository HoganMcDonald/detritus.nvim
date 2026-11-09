---Debounced directory watching on top of libuv fs_event.
---Directories (not files) are watched because both SQLite (WAL) and git replace
---files by rename, which would silently end a per-file watcher.
local M = {}

---@param dir string
---@param filter fun(filename: string): boolean
---@param callback fun()  Runs on the main loop
---@param delay? integer Debounce in ms
---@return { stop: fun() }?
function M.dir(dir, filter, callback, delay)
  local handle = vim.uv.new_fs_event()
  local timer = vim.uv.new_timer()
  if not handle or not timer then
    return nil
  end
  local ok = handle:start(dir, {}, function(err, filename)
    if err or (filename and not filter(filename)) then
      return
    end
    timer:stop()
    timer:start(delay or 50, 0, vim.schedule_wrap(callback))
  end)
  if not ok then
    handle:close()
    timer:close()
    return nil
  end
  local stopped = false
  return {
    stop = function()
      if stopped then
        return
      end
      stopped = true
      timer:stop()
      timer:close()
      handle:stop()
      handle:close()
    end,
  }
end

return M
