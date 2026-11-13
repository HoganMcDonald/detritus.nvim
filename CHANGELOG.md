# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- `gd` on a reference to a file that does not exist yet now opens a new buffer
  for it instead of reporting "file not found". The file (and any missing
  parent directories) is only created when you `:write`.

## [0.1.0] - 2026-11-10

### Added

- Plan panel with `edgy`, `sidebar` and `float` layouts.
- Plans stored in SQLite, partitioned by project and git branch.
- Headless MCP server (`bin/detritus-mcp.lua`) with tools to read and edit plans.
- Live sync between the MCP server and the panel.
- `gd` to jump to files and symbols a step references, using LSP when available.
- `:checkhealth detritus`.

[Unreleased]: https://github.com/HoganMcDonald/detritus.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/HoganMcDonald/detritus.nvim/releases/tag/v0.1.0
