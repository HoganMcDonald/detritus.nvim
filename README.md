# detritus.nvim

[![CI](https://github.com/HoganMcDonald/detritus.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/HoganMcDonald/detritus.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10%2B-green.svg?logo=neovim&logoColor=white)

A persistent plan panel for Neovim, fed by an agent over MCP.

AI agents are good at planning and happy to write all the code. Sometimes you
want to write it yourself and use the agent as a planner. detritus gives the
agent somewhere to put the plan, and gives you a checklist that lives next to
your code.

You plan a feature with an agent, then say "I want to implement this myself".
The agent decomposes the work into small, one-sentence steps and stores them
through detritus's MCP tools. They show up in a panel next to your code, where
you check them off as you build, and jump to the files and symbols they mention
with `gd`.

```
 Session tokens  1/4
  feat/session-tokens

 ✓ Add a `SessionToken` struct holding the user id and expiry.
     ↳ src/token.rs  SessionToken
 ☐ ⚠️ Implement `SessionToken::new` with validation.
     • rejects a zero `user_id`
     • rejects an `expires_at` in the past
     ↳ src/token.rs  SessionToken::new
 ☐ Issue a token from `AuthService::login`.
     ↳ src/auth.rs  AuthService::login
```

- Steps live in SQLite, partitioned by **project and git branch**. Switch
  branches and the panel switches plans.
- If the agent changes a step you have already seen, it is flagged with `⚠️` and
  unchecked so you know to go back to it.
- The MCP server runs without Neovim. The panel picks up the agent's writes live.

## Quick start

1. **Install the plugin** (see [Install](#install)).
2. **Register the MCP server with your agent.** Run `:Detritus mcp` in Neovim: it
   prints the exact command for your install and copies it to your clipboard.
   See [MCP server](#mcp-server) for Claude Code, OpenCode and Codex.
3. **Ask your agent to plan, then take over.** Say something like "plan this
   feature, then store the steps in detritus, I'll implement it myself". Open
   the panel with `:Detritus`.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Using the panel](#using-the-panel)
- [MCP server](#mcp-server)
- [Database](#database)
- [Contributing](#contributing)

## Requirements

- Neovim 0.10+ (LuaJIT)
- `git`
- The system `libsqlite3` (macOS and most Linux distros ship it). Set
  `DETRITUS_SQLITE_LIB` to its path if it is not found. `:checkhealth detritus`
  verifies everything.
- macOS or Linux. Windows is untested.
- Optional: [edgy.nvim](https://github.com/folke/edgy.nvim) for the `edgy` layout.

## Install

No build step is needed, and `setup()` is optional.

```lua
-- lazy.nvim
{ "HoganMcDonald/detritus.nvim", cmd = "Detritus", opts = {} }

-- vim.pack (Neovim 0.12+)
vim.pack.add({ "https://github.com/HoganMcDonald/detritus.nvim" })
require("detritus").setup()

-- a local checkout (lazy.nvim)
{ dir = "~/src/detritus.nvim", cmd = "Detritus", opts = {} }
```

After installing, run `:checkhealth detritus`.

### Layouts

`layout` controls where the panel opens:

| layout    | behaviour                                                                |
| --------- | ------------------------------------------------------------------------ |
| `edgy`    | Opens a right split that [edgy.nvim](https://github.com/folke/edgy.nvim) adopts (default). Falls back to `sidebar` if edgy is missing. |
| `sidebar` | A plain full-height split on the right with a fixed width.               |
| `float`   | A centered floating window. `gd` closes it after jumping.                |

For `edgy`, add a view for the filetype to your edgy config:

```lua
require("edgy").setup({
  right = {
    require("detritus").edgy_view(), -- { title = "Plan", ft = "detritus" }
  },
})
```

### Configuration

```lua
require("detritus").setup({
  layout = "edgy", -- "edgy" | "float" | "sidebar"
  width = 50, -- sidebar / edgy split width
  float = { width = 0.4, height = 0.6, border = "rounded" },
  enter = true, -- focus the panel when it opens
  db_path = nil, -- see "Database" below
  poll_ms = 1000, -- safety-net poll while visible; 0 disables
  icons = { done = "✓", todo = "☐", changed = "⚠️", bullet = "•", ref = "↳", branch = "\u{e0a0}" },
  keys = { -- buffer-local; set one to false to disable it
    toggle = { "x", "<CR>" },
    goto_ref = "gd",
    add = "a",
    delete = "dd",
    fold = "za",
    fold_all = "zM",
    unfold_all = "zR",
    next_open = "]]",
    prev_open = "[[",
    refresh = "R",
    close = "q",
    help = "?",
  },
})
```

No global keymaps are created. Bind your own, for example:

```lua
vim.keymap.set("n", "<leader>pp", "<cmd>Detritus toggle<cr>", { desc = "Toggle plan" })
```

## Using the panel

| key          | action                                                                     |
| ------------ | -------------------------------------------------------------------------- |
| `x` / `<CR>` | Toggle done. Checking a `⚠️` step acknowledges it.                         |
| `gd`         | Jump to a reference (see below)                                            |
| `]]` / `[[`  | Next / previous unchecked step                                             |
| `za`         | Fold or unfold a step's details; `zM` / `zR` for all                       |
| `a`          | Add your own step after the current one                                    |
| `dd`         | Delete a step (asks first)                                                 |
| `R`          | Refresh                                                                    |
| `q`          | Close (the buffer persists, so reopening is instant)                       |
| `?`          | Show the key list                                                          |

**`gd`** picks its target in this order:

1. On a `↳ path:line  symbol` line: that reference.
2. On a `` `backticked` `` token in the step text: that file (`` `src/a.rs:12` ``)
   or symbol (`` `Foo::new` ``), searched in the step's referenced files first.
3. Otherwise the step's references, asking which one if there are several.

Symbols are resolved with LSP `documentSymbol` when a client is attached (so
`SessionToken::new` lands on the method, not the type), and a definition-aware
text search otherwise. Symbol-only references use `workspace/symbol`, then
`git grep`. Code opens in your previous editing window, never in the panel.

If a referenced file doesn't exist yet, `gd` opens an empty buffer for it
(relative to the project root). Nothing touches the disk until you `:write`,
which also creates any missing parent directories. A backticked token counts as
a path when it contains a `/` or is a bare filename Neovim recognizes
(`init.lua`, `Makefile`); anything else is treated as a symbol and never opens
a new file.

### Commands

`:Detritus [toggle|open|close|refresh|branch|clear|mcp]`

- `branch` picks another branch's plan to view. It unpins itself when you check
  out something else.
- `clear` deletes the displayed plan after a confirmation.
- `mcp` shows the MCP server command (and copies it to the clipboard).

Statusline: `require("detritus").status()` returns e.g. `"2/5"` (empty when
there is no plan).

## MCP server

The server speaks MCP over stdio and runs headless, so it works whether or not
Neovim is open:

```
nvim --headless --clean -l /path/to/detritus.nvim/bin/detritus-mcp.lua
```

It resolves the plan from the **working directory it was started in** (the
agent's project), partitioned by the checked-out branch, and re-checks the
branch on every call.

The path to `detritus-mcp.lua` depends on where your plugin manager puts the
plugin (for lazy.nvim that is `~/.local/share/nvim/lazy/detritus.nvim` by
default). Run **`:Detritus mcp`** to get the exact command for your machine. The
snippets below use `/path/to/detritus.nvim` as a stand-in.

### Claude Code

```sh
claude mcp add --scope user detritus -- \
  nvim --headless --clean -l /path/to/detritus.nvim/bin/detritus-mcp.lua
```

### OpenCode (`opencode.json`)

```json
{
  "mcp": {
    "detritus": {
      "type": "local",
      "command": ["nvim", "--headless", "--clean", "-l", "/path/to/detritus.nvim/bin/detritus-mcp.lua"]
    }
  }
}
```

### Codex (`config.toml`)

```toml
[mcp_servers.detritus]
command = "nvim"
args = ["--headless", "--clean", "-l", "/path/to/detritus.nvim/bin/detritus-mcp.lua"]
```

### Tools

All tools accept optional `project_dir` and `branch` to target another
repository or branch.

| tool          | purpose                                                              |
| ------------- | -------------------------------------------------------------------- |
| `get_plan`    | Title, progress and every step (id, text, details, refs, done, changed) |
| `get_step`    | One step                                                             |
| `set_plan`    | Replace the whole plan (discards progress)                           |
| `update_plan` | Set the plan title                                                   |
| `add_steps`   | Add steps; append, or insert after a step id (`0` = start)           |
| `update_step` | Patch `text`, `details` or `refs`; real changes flag the step `⚠️`   |
| `move_step`   | Reorder (never flags)                                                |
| `delete_step` | Remove a step                                                        |
| `clear_plan`  | Delete the branch's plan                                             |
| `list_plans`  | Every branch in the project that has a plan                          |

Agents cannot check steps off; that is yours alone.

The server ships instructions to the agent on how to write steps: one sentence
each, what rather than how, invariants in `details`, `refs` for files and
symbols, ordered so each step can follow the ones above. A `decompose` MCP
prompt carries the same guidance.

A step is `{ text, details?: string[], refs?: [{ path?, line?, symbol? }] }`.
Paths are relative to the repository root.

## Database

One SQLite file (WAL mode) holds every project:
`${XDG_DATA_HOME:-~/.local/share}/detritus/detritus.db`. It deliberately ignores
`NVIM_APPNAME`, so the headless server and every Neovim config share it.

To relocate it, set `DETRITUS_DB` for **both** Neovim and the MCP server (the
server takes it from its environment, e.g. via `-e DETRITUS_DB=...`). Setting
only `setup({ db_path })` splits the panel from the server; `:checkhealth`
warns about that.

Plans are keyed by `(project, branch)`. `project` is the repository's common git
directory, so every worktree of a repo shares it while each branch keeps its own
plan. A detached HEAD uses `@<short-sha>`; outside git the directory is the
project and the branch is `_`.

## How the panel stays in sync

The MCP server and Neovim are separate processes sharing the database file.
Neovim watches the data directory and `.git/HEAD` with libuv, debounced, and
confirms real changes with `PRAGMA data_version`. A once-a-second poll (only
while the panel is visible) is a safety net where file events are lossy.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for
how to run the tests and linters.

## License

[MIT](LICENSE)
