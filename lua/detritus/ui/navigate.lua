---`gd` in the panel: jump to the file / symbol a step refers to.
local config = require("detritus.config")
local panel = require("detritus.ui.panel")
local render = require("detritus.ui.render")

local M = {}

local SIDE_FILETYPES = {
  detritus = true,
  ["neo-tree"] = true,
  Outline = true,
  ["neotest-summary"] = true,
  ["neotest-output-panel"] = true,
  codecompanion = true,
  trouble = true,
  qf = true,
  help = true,
  edgy = true,
}

local function notify(message, level)
  vim.notify("detritus: " .. message, level or vim.log.levels.WARN)
end

---Whether `win` is a normal editing window we can open code in.
---@param win integer
local function is_editor_win(win)
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "" and not SIDE_FILETYPES[vim.bo[buf].filetype]
end

---Pick (or make) the window to open code in: the previous window if it is an
---editor window, otherwise the first one, otherwise a fresh split.
---@return integer win
local function target_window()
  local alt = vim.fn.win_getid(vim.fn.winnr("#"))
  if alt ~= 0 and vim.api.nvim_win_is_valid(alt) and is_editor_win(alt) then
    return alt
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_editor_win(win) then
      return win
    end
  end
  vim.cmd("topleft vnew")
  return vim.api.nvim_get_current_win()
end

---Absolute paths `path` could refer to, most likely first.
---@param path string
---@return string[]
local function path_candidates(path)
  local scope = panel.state.scope
  local candidates = {}
  if path:sub(1, 1) == "/" then
    candidates[1] = path
  elseif path:sub(1, 1) == "~" then
    candidates[1] = vim.fn.expand(path)
  else
    if scope and scope.root then
      candidates[#candidates + 1] = vim.fs.joinpath(scope.root, path)
    end
    candidates[#candidates + 1] = vim.fs.joinpath(vim.fn.getcwd(), path)
  end
  return candidates
end

---@param path string
---@return string? absolute
local function resolve_path(path)
  for _, candidate in ipairs(path_candidates(path)) do
    local stat = vim.uv.fs_stat(candidate)
    if stat and stat.type == "file" then
      return candidate
    end
  end
end

---Absolute path for a file that doesn't exist yet, anchored at the plan's
---project root like a relative ref is when it exists.
---@param path string
---@return string? absolute, string? err
local function new_file_path(path)
  local absolute = path_candidates(path)[1]
  if not absolute then
    return nil, "cannot resolve path"
  end
  local stat = vim.uv.fs_stat(absolute)
  if stat then
    return nil, stat.type == "directory" and "is a directory" or "already exists"
  end
  return absolute
end

---Make the first `:write` of a not-yet-existing file create its parent
---directories, so nothing touches the disk until the user saves.
---@param buf integer
local function mkdir_on_first_write(buf)
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = buf,
    once = true,
    desc = "detritus: create parent directories of a new file",
    callback = function(args)
      vim.fn.mkdir(vim.fn.fnamemodify(args.match, ":p:h"), "p")
    end,
  })
end

---Whether a backticked token reads as a file path rather than a symbol:
---it contains a directory separator, or is a bare name filetype detection
---recognizes (`init.lua`, `Makefile`).
---@param token string
local function looks_like_path(token)
  if token:find("[%s:<>(){}]") then
    return false
  end
  if token:find("/", 1, true) then
    return true
  end
  return token:find(".", 1, true) ~= nil and vim.filetype.match({ filename = token }) ~= nil
end

---@param win integer
---@param line integer 1-based
---@param col? integer 0-based byte column
local function jump(win, line, col)
  local buf = vim.api.nvim_win_get_buf(win)
  line = math.max(1, math.min(line, vim.api.nvim_buf_line_count(buf)))
  pcall(vim.api.nvim_win_set_cursor, win, { line, col or 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
end

---------------------------------------------------------------------------
-- Symbol lookup without LSP
---------------------------------------------------------------------------

local DEFINITION_KEYWORDS = {
  "fn",
  "struct",
  "enum",
  "trait",
  "impl",
  "type",
  "class",
  "interface",
  "function",
  "def",
  "const",
  "static",
  "let",
  "var",
  "mod",
  "module",
  "func",
  "object",
  "record",
  "protocol",
  "namespace",
  "macro_rules",
}

---@param symbol string
---@return string[]
local function symbol_parts(symbol)
  local parts = {}
  for part in symbol:gmatch("[^:%.#/]+") do
    parts[#parts + 1] = part:gsub("%(.*$", ""):gsub("<.*$", "")
  end
  return parts
end

---Find the line defining `name`, preferring lines with a definition keyword
---before it, falling back to the first whole-word occurrence.
---@param lines string[]
---@param name string
---@param from? integer
---@return integer? line, integer? col
local function find_definition(lines, name, from)
  local pattern = "%f[%w_]" .. vim.pesc(name) .. "%f[^%w_]"
  local first, first_col
  for i = from or 1, #lines do
    local s = lines[i]:find(pattern)
    if s then
      local before = lines[i]:sub(1, s - 1)
      for _, keyword in ipairs(DEFINITION_KEYWORDS) do
        if before:find("%f[%w_]" .. keyword .. "%f[^%w_]") then
          return i, s - 1
        end
      end
      if not first then
        first, first_col = i, s - 1
      end
    end
  end
  return first, first_col
end

---@return boolean found
local function locate_by_text(buf, win, symbol)
  local parts = symbol_parts(symbol)
  if #parts == 0 then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local from = 1
  if #parts > 1 then
    from = find_definition(lines, parts[#parts - 1]) or 1
  end
  local line, col = find_definition(lines, parts[#parts], from)
  if not line and from > 1 then
    line, col = find_definition(lines, parts[#parts], 1)
  end
  if line then
    jump(win, line, col)
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- Symbol lookup via LSP
---------------------------------------------------------------------------

---Strip rust-style `impl<T> Trait for Type` and generics down to a bare name.
---@param name string
---@return string
local function normalize_part(name)
  name = name:gsub("^impl%s*<[^>]*>%s*", ""):gsub("^impl%s+", "")
  local after_for = name:match("%sfor%s+(.+)$")
  if after_for then
    name = after_for
  end
  name = name:gsub("<.*>", ""):gsub("%(.*%)", ""):gsub("%s+", "")
  return name
end

---@param symbols table[]
---@param chain string[]
---@param out { path: string[], pos: table }[]
local function flatten(symbols, chain, out)
  for _, sym in ipairs(symbols) do
    local path = vim.list_extend(vim.deepcopy(chain), { normalize_part(sym.name) })
    if not sym.children and sym.containerName and sym.containerName ~= "" then
      path = {}
      for part in sym.containerName:gmatch("[^:%.]+") do
        path[#path + 1] = normalize_part(part)
      end
      path[#path + 1] = normalize_part(sym.name)
    end
    local range = sym.selectionRange or (sym.location and sym.location.range) or sym.range
    if range then
      out[#out + 1] = { path = path, pos = range.start }
    end
    if sym.children then
      flatten(sym.children, path, out)
    end
  end
end

---@param path string[]
---@param target string[]
local function suffix_matches(path, target)
  if #path < #target then
    return false
  end
  for i = 0, #target - 1 do
    if path[#path - i] ~= target[#target - i] then
      return false
    end
  end
  return true
end

---Try documentSymbol on `buf`; falls back to text search when no client is
---attached or nothing matches.
local function locate_in_buffer(buf, win, symbol, fallback_line)
  local function fallback()
    if locate_by_text(buf, win, symbol) then
      return
    end
    if fallback_line then
      jump(win, fallback_line)
    else
      notify(("symbol %s not found"):format(symbol))
    end
  end

  local clients = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/documentSymbol" })
  if #clients == 0 then
    return fallback()
  end

  local target = vim.tbl_map(normalize_part, symbol_parts(symbol))
  clients[1]:request(
    "textDocument/documentSymbol",
    { textDocument = vim.lsp.util.make_text_document_params(buf) },
    function(err, result)
      if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then
        return
      end
      if err or not result then
        return fallback()
      end
      local flat = {}
      flatten(result, {}, flat)
      for _, item in ipairs(flat) do
        if suffix_matches(item.path, target) then
          return jump(win, item.pos.line + 1, item.pos.character)
        end
      end
      fallback()
    end,
    buf
  )
end

---Last resort for symbol-only refs: ripgrep-less whole-word search of the repo.
local function grep_symbol(win, symbol)
  local parts = symbol_parts(symbol)
  local name = parts[#parts]
  if not name then
    return
  end
  local root = (panel.state.scope and panel.state.scope.root) or vim.fn.getcwd()
  vim.system({ "git", "grep", "-n", "-w", "--", name }, { cwd = root, text = true }, function(res)
    vim.schedule(function()
      local lines = vim.split(vim.trim(res.stdout or ""), "\n", { trimempty = true })
      if #lines == 0 then
        return notify(("symbol %s not found"):format(symbol))
      end
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      vim.api.nvim_set_current_win(win)
      local qf_items = {}
      for _, line in ipairs(lines) do
        local file, lnum, text = line:match("^(.-):(%d+):(.*)$")
        if file then
          qf_items[#qf_items + 1] = { filename = vim.fs.joinpath(root, file), lnum = tonumber(lnum), text = text }
        end
      end
      vim.fn.setqflist({}, " ", { title = "detritus: " .. symbol, items = qf_items })
      if #qf_items == 1 then
        vim.cmd("cfirst")
      else
        vim.cmd("copen")
      end
    end)
  end)
end

---Symbol-only reference: ask every LSP client that supports workspace/symbol.
local function locate_in_workspace(win, symbol)
  local clients = vim.lsp.get_clients({ method = "workspace/symbol" })
  if #clients == 0 then
    return grep_symbol(win, symbol)
  end
  local parts = symbol_parts(symbol)
  local name = parts[#parts]
  local target = vim.tbl_map(normalize_part, parts)

  local pending, matches = #clients, {}
  for _, client in ipairs(clients) do
    client:request("workspace/symbol", { query = name }, function(err, result)
      if not err then
        for _, sym in ipairs(result or {}) do
          local path = {}
          for part in (sym.containerName or ""):gmatch("[^:%.]+") do
            path[#path + 1] = normalize_part(part)
          end
          path[#path + 1] = normalize_part(sym.name)
          if suffix_matches(path, target) and sym.location then
            matches[#matches + 1] = { location = sym.location, encoding = client.offset_encoding, sym = sym }
          end
        end
      end
      pending = pending - 1
      if pending > 0 then
        return
      end
      vim.schedule(function()
        if #matches == 0 then
          return grep_symbol(win, symbol)
        end
        local function show(match)
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_current_win(win)
          end
          local loc = match.location
          vim.lsp.util.show_document({
            uri = loc.uri,
            range = loc.range or { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
          }, match.encoding, { focus = true })
        end
        if #matches == 1 then
          return show(matches[1])
        end
        vim.ui.select(matches, {
          prompt = "Symbol " .. symbol,
          format_item = function(match)
            return ("%s  %s"):format(match.sym.name, vim.uri_to_fname(match.location.uri))
          end,
        }, function(choice)
          if choice then
            show(choice)
          end
        end)
      end)
    end)
  end
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

---Open a reference in an editor window.
---@param target detritus.Ref
function M.open_target(target)
  local win = target_window()
  if not (target.path or target.symbol) then
    return
  end

  if target.path then
    local absolute = resolve_path(target.path)
    local created = false
    if not absolute then
      local err
      absolute, err = new_file_path(target.path)
      if not absolute then
        return notify(("cannot open %s: %s"):format(target.path, err))
      end
      created = true
    end
    vim.api.nvim_set_current_win(win)
    vim.cmd.edit(vim.fn.fnameescape(absolute))
    local buf = vim.api.nvim_get_current_buf()
    if created then
      mkdir_on_first_write(buf)
      notify(("new file %s (written on :w)"):format(target.path), vim.log.levels.INFO)
    elseif target.symbol then
      locate_in_buffer(buf, win, target.symbol, target.line)
    elseif target.line then
      jump(win, target.line)
    end
  else
    locate_in_workspace(win, target.symbol)
  end

  if config.get().layout == "float" then
    panel.close()
  end
end

---`foo.rs:12` / `src/foo.rs` / `Symbol` / `Type::method()` inside backticks.
---@param token string
---@param refs detritus.Ref[]
---@return detritus.Ref
local function token_to_target(token, refs)
  token = vim.trim(token):gsub("%(%)$", "")
  local path, line = token:match("^(.-):(%d+)$")
  if path and resolve_path(path) then
    return { path = path, line = tonumber(line) }
  end
  if resolve_path(token) then
    return { path = token }
  end
  -- A path that doesn't exist yet: `gd` opens a new buffer for it.
  if path and looks_like_path(path) then
    return { path = path, line = tonumber(line) }
  end
  if looks_like_path(token) then
    return { path = token }
  end
  -- A symbol one of the step's refs already points at keeps its file context.
  for _, ref in ipairs(refs) do
    if ref.symbol and (ref.symbol == token or ref.symbol:sub(-#token - 1) == ":" .. token) then
      return ref
    end
  end
  local context
  for _, ref in ipairs(refs) do
    if ref.path then
      context = ref.path
      break
    end
  end
  return { path = context, symbol = token }
end

---@return string?
local function token_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local init = 1
  while true do
    local s, e = line:find("`([^`]+)`", init)
    if not s then
      return nil
    end
    if col >= s and col <= e then
      return line:sub(s + 1, e - 1)
    end
    init = e + 1
  end
end

---gd: a ref line jumps to that ref; a `backticked` token jumps to that
---file/symbol; otherwise the step's own refs are used (asking if several).
function M.goto_ref()
  local state = panel.state
  if not state.index or not state.plan then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local ref = state.index.ref_at[row]
  if ref then
    return M.open_target(ref)
  end

  local id = state.index.step_at[row]
  if not id then
    return
  end
  local step
  for _, candidate in ipairs(state.plan.steps) do
    if candidate.id == id then
      step = candidate
      break
    end
  end
  if not step then
    return
  end

  local token = token_under_cursor()
  if token then
    return M.open_target(token_to_target(token, step.refs))
  end
  if #step.refs == 0 then
    return notify("this step has no references")
  end
  if #step.refs == 1 then
    return M.open_target(step.refs[1])
  end
  vim.ui.select(step.refs, {
    prompt = "Go to",
    format_item = render.ref_label,
  }, function(choice)
    if choice then
      M.open_target(choice)
    end
  end)
end

return M
