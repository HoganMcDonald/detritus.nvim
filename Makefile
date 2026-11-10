.PHONY: test fmt lint typecheck docs

NVIM ?= nvim

test:
	$(NVIM) --headless --clean -l tests/run.lua

fmt:
	stylua .

lint:
	stylua --check .

typecheck:
	VIMRUNTIME="$$($(NVIM) --clean --headless --cmd 'lua io.write(vim.env.VIMRUNTIME)' --cmd q 2>&1)" \
	  lua-language-server --check . --configpath "$$PWD/.luarc.json" --checklevel=Error --logpath "$${TMPDIR:-/tmp}/detritus-luals"

docs:
	$(NVIM) --headless --clean -u NONE -c 'helptags doc' -c 'qa!'
	@for cmd in toggle open close refresh branch clear mcp; do \
	  grep -q "$$cmd" doc/detritus.txt || { echo "doc/detritus.txt does not mention :Detritus $$cmd"; exit 1; }; \
	done
