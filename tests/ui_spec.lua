local h = require("harness")
local t = h.t
local db = require("detritus.db")

local detritus = require("detritus")
local panel = require("detritus.ui.panel")

local function buf_lines()
  return vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false)
end

local function buf_text()
  return table.concat(buf_lines(), "\n")
end

local function wait_for(cond, ms)
  return vim.wait(ms or 3000, cond, 20)
end

---Run the panel keymap `lhs` as if typed, with the panel window focused.
local function press(lhs)
  local map = vim.fn.maparg(lhs, "n", false, true)
  assert(map.callback, "no mapping for " .. lhs)
  map.callback()
end

local function goto_line(pattern)
  for i, line in ipairs(buf_lines()) do
    if line:find(pattern, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  error("no line matching " .. pattern .. " in:\n" .. buf_text())
end

describe("ui", function()
  local repo = h.repo()
  vim.fn.mkdir(repo .. "/src", "p")
  vim.fn.writefile({
    "pub struct SessionToken {",
    "    user_id: u64,",
    "}",
    "",
    "impl SessionToken {",
    "    pub fn new(user_id: u64) -> Self {",
    "        Self { user_id }",
    "    }",
    "}",
  }, repo .. "/src/token.rs")
  vim.fn.writefile({ "fn main() {}" }, repo .. "/src/main.rs")
  h.git({ "add", "." }, repo)
  h.git({ "commit", "-q", "-m", "files" }, repo)

  local dbfile = h.tmpdir() .. "/ui.db"
  vim.cmd.cd(repo)
  detritus.setup({ layout = "sidebar", width = 44, db_path = dbfile, poll_ms = 100 })

  -- A second connection plays the part of the MCP server.
  local agent = db.open(dbfile)
  local scope = { project = repo, branch = "main" }

  agent:set_plan(scope, {
    title = "Sessions",
    steps = {
      {
        text = "Add `SessionToken` struct",
        details = { "has `user_id`" },
        refs = { { path = "src/token.rs", symbol = "SessionToken" } },
      },
      {
        text = "Implement `SessionToken::new`",
        refs = { { path = "src/token.rs", symbol = "SessionToken::new" }, { path = "src/main.rs", line = 1 } },
      },
      { text = "Wire it in" },
    },
  })

  vim.cmd.edit(repo .. "/src/main.rs")
  local editor = vim.api.nvim_get_current_win()

  it("opens a persistent right-hand sidebar", function()
    local win = detritus.open()
    t.truthy(win and vim.api.nvim_win_is_valid(win))
    t.eq(vim.bo[panel.state.buf].filetype, "detritus")
    t.eq(vim.api.nvim_win_get_width(win), 44)
    t.falsy(vim.bo[panel.state.buf].modifiable)
    t.truthy(vim.api.nvim_win_get_position(win)[2] > vim.api.nvim_win_get_position(editor)[2], "panel is to the right")
    t.truthy(buf_text():find("Add `SessionToken` struct", 1, true))
    t.truthy(detritus.is_open())
    t.eq(detritus.status(), "0/3")
  end)

  it("toggles closed but keeps the buffer", function()
    local buf = panel.state.buf
    detritus.toggle()
    t.falsy(detritus.is_open())
    t.truthy(vim.api.nvim_buf_is_valid(buf))
    detritus.toggle()
    t.truthy(detritus.is_open())
    t.eq(panel.state.buf, buf)
  end)

  it("checks steps off with x and persists it", function()
    goto_line("Wire it in")
    press("x")
    t.truthy(buf_text():find("✓ Wire it in", 1, true))
    t.eq(detritus.status(), "1/3")
    t.truthy(agent:get_plan(scope).steps[3].done)
    press("x")
    t.truthy(buf_text():find("☐ Wire it in", 1, true))
  end)

  it("live-updates when the agent writes, flagging changed steps", function()
    local steps = agent:get_plan(scope).steps
    goto_line("Wire it in")
    press("x")
    agent:update_step(scope, steps[3].id, { text = "Wire it into `AuthService`" })
    t.truthy(
      wait_for(function()
        return buf_text():find("⚠️ Wire it into", 1, true) ~= nil
      end),
      "expected the warning after an external update:\n" .. buf_text()
    )
    t.truthy(buf_text():find("☐ ⚠️ Wire it into", 1, true), "changed step must be unchecked")
    t.eq(detritus.status(), "0/3")
  end)

  it("live-updates for added steps", function()
    agent:add_steps(scope, { { text = "Brand new step" } })
    t.truthy(wait_for(function()
      return buf_text():find("Brand new step", 1, true) ~= nil
    end))
    agent:delete_step(scope, agent:get_plan(scope).steps[4].id)
    t.truthy(wait_for(function()
      return buf_text():find("Brand new step", 1, true) == nil
    end))
  end)

  it("acknowledging a changed step with x clears the warning", function()
    goto_line("Wire it into")
    press("x")
    t.falsy(buf_text():find("⚠️", 1, true))
    t.truthy(buf_text():find("✓ Wire it into", 1, true))
  end)

  it("folds details", function()
    goto_line("Add `SessionToken`")
    t.truthy(buf_text():find("has `user_id`", 1, true))
    press("za")
    t.falsy(buf_text():find("has `user_id`", 1, true))
    press("za")
    t.truthy(buf_text():find("has `user_id`", 1, true))
  end)

  it("jumps between unchecked steps", function()
    goto_line("Add `SessionToken`")
    press("]]")
    t.truthy(vim.api.nvim_get_current_line():find("Implement `SessionToken::new`", 1, true))
    press("[[")
    t.truthy(vim.api.nvim_get_current_line():find("Add `SessionToken`", 1, true))
  end)

  it("gd on a ref line opens the file at the symbol in the editor window", function()
    goto_line("src/token.rs  SessionToken")
    press("gd")
    t.eq(vim.api.nvim_get_current_win(), editor)
    t.truthy(vim.api.nvim_buf_get_name(0):find("src/token.rs", 1, true))
    t.eq(vim.api.nvim_win_get_cursor(0)[1], 1)
    vim.cmd.edit(repo .. "/src/main.rs")
  end)

  it("gd resolves qualified symbols to the method, not the type", function()
    detritus.open()
    goto_line("src/token.rs  SessionToken::new")
    press("gd")
    t.eq(vim.api.nvim_win_get_cursor(0)[1], 6, "expected `fn new` line")
  end)

  it("gd on a backticked token jumps to that symbol using the step's file", function()
    vim.cmd.edit(repo .. "/src/main.rs")
    detritus.open()
    goto_line("Implement `SessionToken::new`")
    local line = vim.api.nvim_get_current_line()
    local col = line:find("SessionToken::new", 1, true)
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], col })
    press("gd")
    t.eq(vim.api.nvim_win_get_cursor(0)[1], 6)
  end)

  it("gd on a plain step line with several refs asks which one", function()
    vim.cmd.edit(repo .. "/src/main.rs")
    detritus.open()
    goto_line("Implement `SessionToken::new`")
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], 3 })
    local asked
    local original = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      asked = #items
      on_choice(items[2])
    end
    press("gd")
    vim.ui.select = original
    t.eq(asked, 2)
    t.truthy(vim.api.nvim_buf_get_name(0):find("src/main.rs", 1, true))
  end)

  it("gd on a ref to a missing file opens a new buffer without touching the disk", function()
    agent:add_steps(scope, { { text = "ghost", refs = { { path = "nope/missing.rs", symbol = "Nothing" } } } })
    t.truthy(wait_for(function()
      return buf_text():find("ghost", 1, true) ~= nil
    end))
    detritus.open()
    goto_line("nope/missing.rs")
    local messages = {}
    local original = vim.notify
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
    press("gd")
    vim.notify = original
    t.eq(vim.api.nvim_get_current_win(), editor)
    t.eq(vim.api.nvim_buf_get_name(0), vim.uv.fs_realpath(repo) .. "/nope/missing.rs")
    t.falsy(vim.uv.fs_stat(repo .. "/nope"), "nothing on disk until written")
    t.truthy(messages[1] and messages[1]:find("new file nope/missing.rs", 1, true))
    t.eq(#messages, 1, "no symbol-not-found noise for a new file")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "// hi" })
    vim.cmd.write()
    t.eq(vim.fn.readfile(repo .. "/nope/missing.rs"), { "// hi" }, ":w creates parent directories and the file")
    vim.cmd.edit(repo .. "/src/main.rs")
  end)

  it("gd on a backticked path that doesn't exist opens a new buffer", function()
    agent:add_steps(scope, { { text = "Add `src/new/thing.rs` module" } })
    t.truthy(wait_for(function()
      return buf_text():find("src/new/thing.rs", 1, true) ~= nil
    end))
    detritus.open()
    goto_line("src/new/thing.rs")
    local line = vim.api.nvim_get_current_line()
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], (line:find("thing", 1, true)) })
    press("gd")
    t.truthy(vim.api.nvim_buf_get_name(0):find("src/new/thing.rs", 1, true))
    t.falsy(vim.uv.fs_stat(repo .. "/src/new"), "nothing on disk until written")
    vim.cmd.edit(repo .. "/src/main.rs")
  end)

  it("gd on a backticked symbol never opens a new file", function()
    agent:add_steps(scope, { { text = "Rename `user.id` field" } })
    t.truthy(wait_for(function()
      return buf_text():find("user.id", 1, true) ~= nil
    end))
    detritus.open()
    goto_line("user.id")
    local line = vim.api.nvim_get_current_line()
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], (line:find("user", 1, true)) })
    local original = vim.notify
    vim.notify = function() end
    press("gd")
    vim.notify = original
    t.falsy(vim.uv.fs_stat(repo .. "/user.id"))
  end)

  it("follows branch switches and keeps plans separate", function()
    detritus.open()
    h.git({ "checkout", "-q", "-b", "feature" }, repo)
    t.truthy(
      wait_for(function()
        return buf_text():find("No steps for this branch", 1, true) ~= nil
      end),
      "HEAD watcher should switch the view:\n" .. buf_text()
    )
    t.truthy(buf_lines()[2]:find("feature", 1, true))

    agent:set_plan({ project = repo, branch = "feature" }, { steps = { { text = "feature-only step" } } })
    t.truthy(wait_for(function()
      return buf_text():find("feature-only step", 1, true) ~= nil
    end))

    h.git({ "checkout", "-q", "main" }, repo)
    t.truthy(wait_for(function()
      return buf_text():find("Add `SessionToken` struct", 1, true) ~= nil
    end))
    t.falsy(buf_text():find("feature-only step", 1, true))
  end)

  it("can pin another branch's plan and unpins when the checkout moves", function()
    local picked
    local original = vim.ui.select
    vim.ui.select = function(items, _, on_choice)
      for _, item in ipairs(items) do
        if item.branch == "feature" then
          picked = item
        end
      end
      on_choice(picked)
    end
    detritus.select_branch()
    vim.ui.select = original
    t.truthy(picked)
    t.truthy(buf_text():find("feature-only step", 1, true))
    h.git({ "checkout", "-q", "-b", "other" }, repo)
    t.truthy(wait_for(function()
      return panel.state.pinned == nil
    end))
    h.git({ "checkout", "-q", "main" }, repo)
    t.truthy(wait_for(function()
      return buf_text():find("Add `SessionToken` struct", 1, true) ~= nil
    end))
  end)

  it("deletes a step after confirmation", function()
    detritus.open()
    goto_line("ghost")
    local confirm = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    press("dd")
    vim.fn.confirm = confirm
    t.falsy(buf_text():find("ghost", 1, true))
  end)

  it("adds a step after the cursor step", function()
    detritus.open()
    goto_line("Add `SessionToken`")
    local original = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("manual step")
    end
    press("a")
    vim.ui.input = original
    local texts = vim.tbl_map(function(s)
      return s.text
    end, agent:get_plan(scope).steps)
    t.eq(texts[2], "manual step")
  end)

  it("closes with q", function()
    detritus.open()
    press("q")
    t.falsy(detritus.is_open())
  end)

  it("supports a floating layout", function()
    detritus.setup({ layout = "float" })
    local win = detritus.open()
    t.truthy(win)
    t.truthy(vim.api.nvim_win_get_config(win).relative ~= "")
    detritus.close()
    t.falsy(detritus.is_open())
  end)

  it("float: gd closes the float after jumping", function()
    vim.cmd.edit(repo .. "/src/main.rs")
    detritus.open()
    goto_line("src/main.rs:1")
    press("gd")
    t.falsy(detritus.is_open())
    t.truthy(vim.api.nvim_buf_get_name(0):find("src/main.rs", 1, true))
  end)

  it("degrades the edgy layout to a sidebar when edgy is missing", function()
    detritus.setup({ layout = "edgy" })
    local win = detritus.open()
    t.truthy(win and vim.api.nvim_win_get_config(win).relative == "")
    detritus.close()
  end)

  it("lets keymaps be rebound or disabled", function()
    detritus.setup({ layout = "sidebar", keys = { toggle = "t", delete = false } })
    detritus.open()
    t.truthy(vim.fn.maparg("t", "n", false, true).callback)
    t.eq(vim.fn.maparg("x", "n"), "")
    t.eq(vim.fn.maparg("dd", "n"), "")
  end)
end)
