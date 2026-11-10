# Contributing

Thanks for helping out. Bug reports, ideas and pull requests are all welcome.

## Setup

You need Neovim 0.10+, `git` and the system `libsqlite3`. For formatting and
type checking, install [`stylua`](https://github.com/JohnnyMorganz/StyLua) and
[`lua-language-server`](https://github.com/LuaLS/lua-language-server).

```sh
git clone https://github.com/HoganMcDonald/detritus.nvim
cd detritus.nvim
```

## Checks

```sh
make test        # headless test suite
make lint        # stylua --check
make typecheck   # lua-language-server, errors only
make docs        # helptags build and a check that :help mentions every subcommand
make fmt         # format with stylua
```

Run one spec by name:

```sh
nvim --headless --clean -l tests/run.lua db
```

The suite covers the SQLite binding, the data layer, scope resolution, the MCP
protocol (it spawns the real server), rendering, and the panel UI including live
updates, branch switching and `gd`. Specs use temporary databases and
repositories, never your real plans.

## Running the MCP server by hand

```sh
nvim --headless --clean -l bin/detritus-mcp.lua
```

It speaks JSON-RPC over stdio. Set `DETRITUS_DB` to point it at a scratch
database while experimenting.

## Pull requests

- Add or update a spec for behaviour you change.
- Keep `README.md` and `doc/detritus.txt` in step with each other.
- Add a line under `Unreleased` in `CHANGELOG.md`.
- CI must pass: tests on Linux and macOS, stylua, typecheck and the docs check.
