---Newline-delimited JSON-RPC 2.0 over stdio, implementing the slice of MCP that
---detritus needs: initialize, ping, tools and prompts.
---
---Runs as a plain blocking read loop under `nvim --headless -l`. Stdout carries
---protocol messages only; anything diagnostic goes to stderr.
local db = require("detritus.db")
local tools = require("detritus.mcp.tools")

local M = {}

local VERSION = "0.1.0"

local SUPPORTED_PROTOCOLS = { "2025-06-18", "2025-03-26", "2024-11-05" }

local ERR = {
  parse = -32700,
  invalid_request = -32600,
  method_not_found = -32601,
  invalid_params = -32602,
  internal = -32603,
}

local function log(message)
  io.stderr:write("[detritus-mcp] ", message, "\n")
end

local function send(message)
  io.stdout:write(vim.json.encode(message), "\n")
  io.stdout:flush()
end

local function reply(id, result)
  send({ jsonrpc = "2.0", id = id, result = result })
end

local function reply_error(id, code, message)
  send({ jsonrpc = "2.0", id = id == nil and vim.NIL or id, error = { code = code, message = message } })
end

local function negotiate_protocol(requested)
  for _, version in ipairs(SUPPORTED_PROTOCOLS) do
    if version == requested then
      return version
    end
  end
  return SUPPORTED_PROTOCOLS[1]
end

---@param store detritus.Store
---@return table<string, fun(id: any, params: table)>
local function handlers(store)
  return {
    ["initialize"] = function(id, params)
      reply(id, {
        protocolVersion = negotiate_protocol(params.protocolVersion),
        capabilities = { tools = { listChanged = false }, prompts = { listChanged = false } },
        serverInfo = { name = "detritus", title = "detritus.nvim", version = VERSION },
        instructions = tools.instructions,
      })
    end,

    ["ping"] = function(id)
      reply(id, vim.empty_dict())
    end,

    ["tools/list"] = function(id)
      reply(id, { tools = tools.list() })
    end,

    ["tools/call"] = function(id, params)
      if type(params.name) ~= "string" then
        return reply_error(id, ERR.invalid_params, "tools/call requires a tool name")
      end
      local result, known = tools.call(store, params.name, params.arguments)
      if not known then
        return reply_error(id, ERR.invalid_params, "unknown tool: " .. params.name)
      end
      reply(id, result)
    end,

    ["prompts/list"] = function(id)
      reply(id, {
        prompts = {
          {
            name = "decompose",
            title = "Decompose into manual steps",
            description = "Break the planned work into small steps for you to implement by hand.",
            arguments = {
              { name = "goal", description = "What to decompose (defaults to the current plan).", required = false },
            },
          },
        },
      })
    end,

    ["prompts/get"] = function(id, params)
      if params.name ~= "decompose" then
        return reply_error(id, ERR.invalid_params, "unknown prompt: " .. tostring(params.name))
      end
      reply(id, {
        description = "Decompose work into manual implementation steps",
        messages = {
          {
            role = "user",
            content = { type = "text", text = tools.decompose_prompt((params.arguments or {}).goal) },
          },
        },
      })
    end,
  }
end

---Handle one decoded message. Notifications (no id) never get a response.
---@param table_of_handlers table
---@param message any
local function dispatch(table_of_handlers, message)
  if type(message) ~= "table" or message.jsonrpc ~= "2.0" or type(message.method) ~= "string" then
    -- Responses to requests we never send, or garbage.
    if type(message) == "table" and message.id ~= nil and message.method == nil then
      return
    end
    return reply_error(type(message) == "table" and message.id or nil, ERR.invalid_request, "invalid request")
  end

  local is_notification = message.id == nil
  local handler = table_of_handlers[message.method]
  if not handler then
    if not is_notification then
      reply_error(message.id, ERR.method_not_found, "method not found: " .. message.method)
    end
    return
  end

  local ok, err = pcall(handler, message.id, type(message.params) == "table" and message.params or {})
  if not ok then
    log("handler error: " .. tostring(err))
    if not is_notification then
      reply_error(message.id, ERR.internal, tostring(err))
    end
  end
end

---Serve until stdin closes.
---@param opts? { db_path?: string }
function M.run(opts)
  opts = opts or {}
  local store = db.open(opts.db_path)
  local table_of_handlers = handlers(store)

  for line in io.stdin:lines() do
    if vim.trim(line) ~= "" then
      local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok then
        dispatch(table_of_handlers, message)
      else
        reply_error(nil, ERR.parse, "parse error")
      end
    end
  end

  store:close()
end

return M
