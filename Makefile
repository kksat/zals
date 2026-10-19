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
# Optional knobs: OPTIMIZE (build), SUITE (e2e), FILE and FILTER (zig-test).
OPTIMIZE ?=
SUITE ?=
FILE ?=
FILTER ?=

.PHONY: help check lint hooks build test e2e zig-test zig neovim-test run fmt clean parity smoke benchmark-operations performance-ci

help:
	@echo 'make check                          lint + build + unit tests; run before committing'
	@echo 'make build [OPTIMIZE=ReleaseFast]   build zig-out/bin/zals'
	@echo 'make test                           unit tests'
	@echo 'make e2e [SUITE=navigation-e2e]     all stdio E2E suites, or one (see zig build -l)'
	@echo 'make zig-test FILE=test/x.zig [FILTER=name]  build, then run one Zig test root'
	@echo 'make zig ARGS="build -l"            any zig command with the macOS workaround'
	@echo 'make performance-ci ARGS="run --baseline-tree <path> --output <path>"  optimized CI comparison'
	@echo 'make smoke | parity | fmt | hooks | run ARGS=--version'

# Pre-commit gate; CI runs lint, test, e2e, and smoke as separate jobs.
check: lint build test

lint:
	zig fmt --check src build.zig build.zig.zon test

# Point git at the tracked hooks (fmt + whitespace, Conventional Commit subject).
hooks:
	git config core.hooksPath .githooks

build:
	zig build $(if $(OPTIMIZE),-Doptimize=$(OPTIMIZE))

test:
	zig build test
	python3 -m unittest discover -s test -p 'test_benchmark_operations.py'
	python3 -m unittest discover -s test -p 'test_release*.py'

e2e:
	zig build $(or $(SUITE),e2e)

# Stdio test roots spawn zig-out/bin/zals, so build it first.
zig-test:
	@test -n "$(FILE)" || { echo 'usage: make zig-test FILE=test/<root>.zig [FILTER=<test name>]'; exit 2; }
	zig build
	zig test $(FILE) $(if $(FILTER),--test-filter '$(FILTER)')

zig:
	zig $(ARGS)

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
	python3 test/smoke_shutdown.py
	python3 test/benchmark_operations.py --files 2 --tasks 2 --sessions 1 --samples 1 --warmup 0 > /dev/null

# End-to-end request latency tables; pass output paths/load via ARGS.
benchmark-operations: build
	python3 test/benchmark_operations.py --label Debug $(ARGS)

# Dedicated tooling owns both ReleaseSafe builds; no implicit Debug dependency.
performance-ci:
	python3 tools/performance/gate.py $(ARGS)

run: build
	./zig-out/bin/zals $(ARGS)

fmt:
	zig fmt src build.zig build.zig.zon test

clean:
	rm -rf zig-out .zig-cache