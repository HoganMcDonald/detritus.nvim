local h = require("harness")
local t = h.t

local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

---Spawn the real server, feed it requests, and return decoded responses by id.
---@param requests table[]
---@param opts { cwd: string, db: string }
local function converse(requests, opts)
  local lines = {}
  for _, request in ipairs(requests) do
    lines[#lines + 1] = type(request) == "string" and request or vim.json.encode(request)
  end
  local res = vim
    .system({ vim.v.progpath, "--headless", "--clean", "-l", root .. "/bin/detritus-mcp.lua" }, {
      cwd = opts.cwd,
      stdin = table.concat(lines, "\n") .. "\n",
      text = true,
      env = { DETRITUS_DB = opts.db },
    })
    :wait(15000)
  local responses = {}
  for line in vim.gsplit(res.stdout, "\n", { plain = true, trimempty = true }) do
    local message = vim.json.decode(line, { luanil = { object = true, array = true } })
    responses[message.id == nil and "null" or message.id] = message
  end
  return responses, res
end

local function call(id, name, arguments)
  return { jsonrpc = "2.0", id = id, method = "tools/call", params = { name = name, arguments = arguments } }
end

local function payload(response)
  return vim.json.decode(response.result.content[1].text, { luanil = { object = true, array = true } })
end

local init = {
  jsonrpc = "2.0",
  id = 1,
  method = "initialize",
  params = { protocolVersion = "2025-06-18", capabilities = {}, clientInfo = { name = "t", version = "0" } },
}

describe("mcp server", function()
  local repo = h.repo()
  local dbfile = h.tmpdir() .. "/mcp.db"
  local opts = { cwd = repo, db = dbfile }

  it("initializes, negotiates the protocol and ships instructions", function()
    local r = converse({ init, { jsonrpc = "2.0", method = "notifications/initialized" } }, opts)
    t.eq(r[1].result.protocolVersion, "2025-06-18")
    t.eq(r[1].result.serverInfo.name, "detritus")
    t.truthy(r[1].result.capabilities.tools)
    t.truthy(r[1].result.instructions:find("never HOW", 1, true))
  end)

  it("falls back to a supported protocol version", function()
    local old = vim.deepcopy(init)
    old.params.protocolVersion = "1999-01-01"
    t.eq(converse({ old }, opts)[1].result.protocolVersion, "2025-06-18")
  end)

  it("does not answer notifications", function()
    local r, res = converse({ { jsonrpc = "2.0", method = "notifications/initialized" } }, opts)
    t.eq(r, {})
    t.eq(res.stdout, "")
  end)

  it("lists every tool with an input schema", function()
    local r = converse({ { jsonrpc = "2.0", id = 2, method = "tools/list" } }, opts)
    local names = vim.tbl_map(function(tool)
      t.eq(tool.inputSchema.type, "object")
      return tool.name
    end, r[2].result.tools)
    table.sort(names)
    t.eq(names, {
      "add_steps",
      "clear_plan",
      "delete_step",
      "get_plan",
      "get_step",
      "list_plans",
      "move_step",
      "set_plan",
      "update_plan",
      "update_step",
    })
  end)

  it("pings", function()
    t.eq(converse({ { jsonrpc = "2.0", id = 3, method = "ping" } }, opts)[3].result, {})
  end)

  it("reports unknown methods and bad json without dying", function()
    local r = converse(
      { "{not json", { jsonrpc = "2.0", id = 4, method = "nope" }, { jsonrpc = "2.0", id = 5, method = "ping" } },
      opts
    )
    t.eq(r["null"].error.code, -32700)
    t.eq(r[4].error.code, -32601)
    t.truthy(r[5].result)
  end)

  it("runs a full plan lifecycle against the current branch", function()
    local r = converse({
      init,
      call(10, "set_plan", {
        title = "Sessions",
        steps = {
          {
            text = "Add `SessionToken`",
            details = { "has `user_id`" },
            refs = { { path = "src/token.rs", symbol = "SessionToken" } },
          },
          { text = "Wire into login" },
        },
      }),
      call(11, "get_plan", {}),
    }, opts)
    local plan = payload(r[11])
    t.eq(plan.branch, "main")
    t.eq(plan.project, repo)
    t.eq(plan.title, "Sessions")
    t.eq(plan.progress, { done = 0, total = 2 })
    t.eq(plan.steps[1].refs, { { path = "src/token.rs", symbol = "SessionToken" } })
    t.eq(plan.steps[2].details, {})

    local first, second = plan.steps[1].id, plan.steps[2].id
    local r2 = converse({
      call(20, "add_steps", { steps = { { text = "Middle" } }, after_step_id = first }),
      call(21, "update_step", { id = second, text = "Wire into `AuthService::login`" }),
      call(22, "move_step", { id = second, after_step_id = 0 }),
      call(23, "get_step", { id = second }),
      call(24, "list_plans", {}),
    }, opts)
    t.eq(#payload(r2[20]).added, 1)
    local updated = payload(r2[21])
    t.truthy(updated.modified)
    t.truthy(updated.step.changed)
    t.eq(payload(r2[22]).steps[1].id, second)
    t.truthy(payload(r2[23]).changed)
    t.eq(payload(r2[24]).plans[1].branch, "main")

    local r3 = converse({
      call(30, "delete_step", { id = first }),
      call(31, "clear_plan", {}),
      call(32, "get_plan", {}),
    }, opts)
    t.eq(#payload(r3[30]).steps, 2)
    t.eq(payload(r3[31]).removed_steps, 2)
    t.eq(payload(r3[32]).steps, {})
  end)

  it("partitions by branch and honours branch overrides", function()
    local r = converse({
      call(40, "set_plan", { steps = { { text = "on main" } } }),
      call(41, "set_plan", { branch = "other", steps = { { text = "on other" } } }),
      call(42, "get_plan", {}),
      call(43, "get_plan", { branch = "other" }),
    }, opts)
    t.eq(payload(r[42]).steps[1].text, "on main")
    t.eq(payload(r[43]).steps[1].text, "on other")
  end)

  it("follows git branch switches between calls", function()
    local r1 = converse({ call(50, "set_plan", { steps = { { text = "main only" } } }) }, opts)
    t.truthy(r1[50].result)
    h.git({ "checkout", "-q", "-b", "feature" }, repo)
    local r2 = converse({ call(51, "get_plan", {}) }, opts)
    t.eq(payload(r2[51]).branch, "feature")
    t.eq(payload(r2[51]).steps, {})
    h.git({ "checkout", "-q", "main" }, repo)
  end)

  it("returns tool errors as isError results, not protocol errors", function()
    local r = converse({
      call(60, "update_step", { id = 99999, text = "x" }),
      call(61, "set_plan", { steps = { { text = "" } } }),
      call(62, "get_plan", { project_dir = "/definitely/not/a/dir" }),
    }, opts)
    for _, id in ipairs({ 60, 61, 62 }) do
      t.truthy(r[id].result.isError, "call " .. id)
    end
    t.truthy(r[60].result.content[1].text:find("not found", 1, true))
  end)

  it("rejects unknown tools with a protocol error", function()
    local r = converse({ call(70, "rm_rf", {}) }, opts)
    t.eq(r[70].error.code, -32602)
  end)

  it("serves the decompose prompt", function()
    local r = converse({
      { jsonrpc = "2.0", id = 80, method = "prompts/list" },
      {
        jsonrpc = "2.0",
        id = 81,
        method = "prompts/get",
        params = { name = "decompose", arguments = { goal = "auth" } },
      },
    }, opts)
    t.eq(r[80].result.prompts[1].name, "decompose")
    t.truthy(r[81].result.messages[1].content.text:find("Goal: auth", 1, true))
  end)

  it("keeps stdout clean: only JSON-RPC lines", function()
    local _, res = converse({ init, call(90, "get_plan", {}) }, opts)
    for line in vim.gsplit(res.stdout, "\n", { plain = true, trimempty = true }) do
      t.truthy(pcall(vim.json.decode, line), "non-JSON on stdout: " .. line)
    end
  end)
end)
