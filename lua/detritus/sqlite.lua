---Minimal LuaJIT FFI binding for the system libsqlite3.
---
---Deliberately tiny: open, exec, parameterised queries, transactions. It has no
---dependencies, so it behaves identically inside Neovim and inside the headless
---`nvim -l` process that hosts the MCP server.
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef([[
  typedef struct sqlite3 sqlite3;
  typedef struct sqlite3_stmt sqlite3_stmt;

  int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
  int sqlite3_close(sqlite3 *db);
  int sqlite3_busy_timeout(sqlite3 *db, int ms);
  const char *sqlite3_errmsg(sqlite3 *db);
  int sqlite3_exec(sqlite3 *db, const char *sql, void *cb, void *arg, char **errmsg);
  void sqlite3_free(void *p);
  int sqlite3_changes(sqlite3 *db);
  int64_t sqlite3_last_insert_rowid(sqlite3 *db);

  int sqlite3_prepare_v2(sqlite3 *db, const char *sql, int nbytes, sqlite3_stmt **stmt, const char **tail);
  int sqlite3_step(sqlite3_stmt *stmt);
  int sqlite3_finalize(sqlite3_stmt *stmt);

  int sqlite3_bind_null(sqlite3_stmt *stmt, int i);
  int sqlite3_bind_int64(sqlite3_stmt *stmt, int i, int64_t v);
  int sqlite3_bind_double(sqlite3_stmt *stmt, int i, double v);
  int sqlite3_bind_text(sqlite3_stmt *stmt, int i, const char *v, int n, void (*destructor)(void *));

  int sqlite3_column_count(sqlite3_stmt *stmt);
  const char *sqlite3_column_name(sqlite3_stmt *stmt, int i);
  int sqlite3_column_type(sqlite3_stmt *stmt, int i);
  int64_t sqlite3_column_int64(sqlite3_stmt *stmt, int i);
  double sqlite3_column_double(sqlite3_stmt *stmt, int i);
  const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int i);
  int sqlite3_column_bytes(sqlite3_stmt *stmt, int i);
]])

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_OPEN_READWRITE = 0x2
local SQLITE_OPEN_CREATE = 0x4

local TYPE_INTEGER, TYPE_FLOAT, TYPE_TEXT, TYPE_BLOB, TYPE_NULL = 1, 2, 3, 4, 5

local M = {}

---@type table?
local lib

local function candidates()
  local list = {}
  local override = vim.env.DETRITUS_SQLITE_LIB
  if override and override ~= "" then
    list[#list + 1] = override
  end
  vim.list_extend(list, {
    "sqlite3",
    "libsqlite3.dylib",
    "libsqlite3.so.0",
    "libsqlite3.so",
    "/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib",
    "/usr/local/opt/sqlite/lib/libsqlite3.dylib",
    "sqlite3.dll",
  })
  return list
end

---Load libsqlite3, trying a list of well-known names.
---@return table lib
function M.load()
  if lib then
    return lib
  end
  local failures = {}
  for _, name in ipairs(candidates()) do
    local ok, loaded = pcall(ffi.load, name)
    if ok then
      lib = loaded
      return lib
    end
    failures[#failures + 1] = tostring(loaded)
  end
  error(
    "detritus: could not load libsqlite3 (set DETRITUS_SQLITE_LIB to its path):\n" .. table.concat(failures, "\n"),
    0
  )
end

---@class detritus.Database
---@field handle userdata
---@field path string
---@field private depth integer
local Database = {}
Database.__index = Database

local transient = ffi.cast("void (*)(void *)", -1)

---@param self detritus.Database
---@param what string
local function failure(self, what)
  local L = M.load()
  return ("sqlite %s failed: %s"):format(what, ffi.string(L.sqlite3_errmsg(self.handle)))
end

---Open (creating if needed) a database file.
---@param path string
---@param opts? { busy_timeout?: integer }
---@return detritus.Database
function M.open(path, opts)
  opts = opts or {}
  local L = M.load()
  if path ~= ":memory:" then
    vim.fn.mkdir(vim.fs.dirname(path), "p")
  end
  local pp = ffi.new("sqlite3*[1]")
  local rc = L.sqlite3_open_v2(path, pp, bit.bor(SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE), nil)
  local self = setmetatable({ handle = pp[0], path = path, depth = 0 }, Database)
  if rc ~= SQLITE_OK then
    local message = failure(self, "open (" .. path .. ")")
    L.sqlite3_close(self.handle)
    error(message, 0)
  end
  L.sqlite3_busy_timeout(self.handle, opts.busy_timeout or 5000)
  return self
end

function Database:close()
  if self.handle then
    M.load().sqlite3_close(self.handle)
    self.handle = nil
  end
end

---Run one or more statements without parameters or results.
---@param sql string
function Database:exec(sql)
  local L = M.load()
  local rc = L.sqlite3_exec(self.handle, sql, nil, nil, nil)
  if rc ~= SQLITE_OK then
    error(failure(self, "exec"), 0)
  end
end

---@param stmt userdata
---@param params? any[]
local function bind(self, stmt, params)
  if not params then
    return
  end
  local L = M.load()
  local count = params.n or #params
  for i = 1, count do
    local value = params[i]
    local rc
    local kind = type(value)
    if value == nil or value == vim.NIL then
      rc = L.sqlite3_bind_null(stmt, i)
    elseif kind == "boolean" then
      rc = L.sqlite3_bind_int64(stmt, i, value and 1 or 0)
    elseif kind == "number" then
      if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
        rc = L.sqlite3_bind_int64(stmt, i, value)
      else
        rc = L.sqlite3_bind_double(stmt, i, value)
      end
    elseif kind == "string" then
      rc = L.sqlite3_bind_text(stmt, i, value, #value, transient)
    else
      error(("sqlite bind: unsupported parameter type %s at index %d"):format(kind, i), 0)
    end
    if rc ~= SQLITE_OK then
      error(failure(self, "bind"), 0)
    end
  end
end

---@param stmt userdata
---@return table
local function read_row(stmt)
  local L = M.load()
  local row = {}
  for i = 0, L.sqlite3_column_count(stmt) - 1 do
    local kind = L.sqlite3_column_type(stmt, i)
    local value
    if kind == TYPE_INTEGER then
      value = tonumber(L.sqlite3_column_int64(stmt, i))
    elseif kind == TYPE_FLOAT then
      value = L.sqlite3_column_double(stmt, i)
    elseif kind == TYPE_TEXT or kind == TYPE_BLOB then
      value = ffi.string(L.sqlite3_column_text(stmt, i), L.sqlite3_column_bytes(stmt, i))
    elseif kind == TYPE_NULL then
      value = nil
    end
    if value ~= nil then
      row[ffi.string(L.sqlite3_column_name(stmt, i))] = value
    end
  end
  return row
end

---Prepare, bind and step through a statement, calling `on_row` for each row.
---@param sql string
---@param params? any[]
---@param on_row? fun(row: table)
function Database:each(sql, params, on_row)
  local L = M.load()
  local pp = ffi.new("sqlite3_stmt*[1]")
  if L.sqlite3_prepare_v2(self.handle, sql, #sql, pp, nil) ~= SQLITE_OK then
    error(failure(self, "prepare"), 0)
  end
  local stmt = pp[0]
  local ok, err = pcall(function()
    bind(self, stmt, params)
    while true do
      local rc = L.sqlite3_step(stmt)
      if rc == SQLITE_ROW then
        if on_row then
          on_row(read_row(stmt))
        end
      elseif rc == SQLITE_DONE then
        return
      else
        error(failure(self, "step"), 0)
      end
    end
  end)
  L.sqlite3_finalize(stmt)
  if not ok then
    error(err, 0)
  end
end

---Run a statement, returning the number of rows it changed.
---@param sql string
---@param params? any[]
---@return integer changes
function Database:run(sql, params)
  self:each(sql, params)
  return M.load().sqlite3_changes(self.handle)
end

---@param sql string
---@param params? any[]
---@return table[]
function Database:all(sql, params)
  local rows = {}
  self:each(sql, params, function(row)
    rows[#rows + 1] = row
  end)
  return rows
end

---@param sql string
---@param params? any[]
---@return table?
function Database:one(sql, params)
  return self:all(sql, params)[1]
end

---Return the first column of the first row.
---@param sql string
---@param params? any[]
---@return any
function Database:scalar(sql, params)
  local row = self:one(sql, params)
  if not row then
    return nil
  end
  -- Rows are keyed by column name, so take whichever single value is present.
  for _, value in pairs(row) do
    return value
  end
  return nil
end

---@return integer
function Database:last_insert_rowid()
  return tonumber(M.load().sqlite3_last_insert_rowid(self.handle))
end

---Run `fn` in a write transaction, rolling back if it raises. Re-entrant calls
---join the outer transaction.
---@generic T
---@param fn fun(): T
---@return T
function Database:transaction(fn)
  if self.depth > 0 then
    return fn()
  end
  self:exec("BEGIN IMMEDIATE")
  self.depth = 1
  local ok, result = pcall(fn)
  self.depth = 0
  if ok then
    self:exec("COMMIT")
    return result
  end
  pcall(self.exec, self, "ROLLBACK")
  error(result, 0)
end

return M
