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

.PHONY: build test e2e neovim-test run fmt clean parity smoke benchmark-operations

build:
	zig build

test:
	zig build test
	python3 -m unittest discover -s test -p 'test_benchmark_operations.py'

e2e:
	zig build e2e

# Optional editor integration test; requires Neovim 0.11+.
neovim-test: build
	nvim --headless -u NONE -l test/neovim_attachment.lua

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
	python3 test/smoke_workspace.py
	python3 test/smoke_cold_start.py
	python3 test/benchmark_operations.py --files 2 --tasks 2 --sessions 1 --samples 1 --warmup 0 > /dev/null

# End-to-end request latency tables; pass output paths/load via ARGS.
benchmark-operations: build
	python3 test/benchmark_operations.py --label Debug $(ARGS)

run: build
	./zig-out/bin/zals $(ARGS)

fmt:
	zig fmt src build.zig test

clean:
	rm -rf zig-out .zig-cache