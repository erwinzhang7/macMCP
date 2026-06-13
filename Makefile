# macMCP — convenience targets. Recipes use tabs (Make requirement).
.PHONY: build test selftest release install clean

build:
	swift build

# Protocol self-test: builds, then drives the shim ⇄ agent over the unix socket.
test: selftest
selftest: build
	python3 test/protocol_selftest.py

release:
	swift build -c release

# Dev install: build release and register the shim with Claude Code (user scope). The shim
# auto-launches the sibling `macmcp-agent` binary on first connect. For the full menu-bar app
# + TCC grants + network extension, use scripts/install.sh (added in later phases).
install: release
	@SHIM="$$(swift build -c release --show-bin-path)/macmcp"; \
	claude mcp add macmcp --scope user -- "$$SHIM" && \
	echo "" && \
	echo "✓ Registered 'macmcp' MCP server (user scope):" && \
	echo "    $$SHIM" && \
	echo "" && \
	echo "Restart your MCP client to load the mac_* tools."

clean:
	swift package clean
	rm -rf .build macMCP.app
