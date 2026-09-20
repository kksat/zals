# Convenience wrapper around `zig build`.
#
# macOS 26 + Xcode 26.5 SDK note:
#   Zig 0.15.1's bundled lld does not match a plain `arm64-macos` request against
#   the SDK's `libSystem.B.tbd`, which only lists `arm64e-macos`. The result is a
#   link failure with undefined libc symbols (`_abort`, `_getenv`, ...). Pointing
#   DEVELOPER_DIR at a nonexistent path makes Zig skip SDK discovery and use its
#   bundled libc stubs, which link correctly. This is safe for a pure-Zig project
#   with vendored C sources. See docs/adr/0019-toolchain-build-and-platforms.md.
ifeq ($(shell uname -s),Darwin)
export DEVELOPER_DIR := /nonexistent
endif

ARGS ?=

.PHONY: build test run fmt clean parity smoke

build:
	zig build

test:
	zig build test

# Compare zals against the upstream Ansible Language Server. Requires the
# upstream package (see test/parity/compare.py) and a built zals binary.
parity: build
	python3 test/parity/compare.py $(ARGS)

# Exercise the references, definition, implementation, and code-action
# providers over stdio against the committed fixtures.
smoke: build
	python3 test/smoke_references.py
	python3 test/smoke_code_actions.py
	python3 test/smoke_role_navigation.py

run: build
	./zig-out/bin/zals $(ARGS)

fmt:
	zig fmt src build.zig

clean:
	rm -rf zig-out .zig-cache