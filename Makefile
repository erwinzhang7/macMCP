# macMCP — convenience targets. Recipes use tabs (Make requirement).
.PHONY: build test selftest release package install clean

build:
	swift build

# Protocol self-test: builds, then drives the shim ⇄ agent over the unix socket.
test: selftest
selftest: build
	python3 test/protocol_selftest.py

release:
	swift build -c release

package:
	./scripts/package-app.sh

install:
	./scripts/install.sh

clean:
	swift package clean
	rm -rf .build macMCP.app
