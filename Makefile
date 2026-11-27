ARGS ?=
OPTIMIZE ?=
SUITE ?=
FILE ?=
FILTER ?=

.PHONY: help check lint hooks build test e2e e2e-negative zig-test zig neovim-test run fmt clean parity smoke benchmark-operations performance-ci

help:
	@echo 'make check                          lint + build + unit tests; run before committing'
	@echo 'make build [OPTIMIZE=ReleaseFast]   build zig-out/bin/zals'
	@echo 'make test                           unit tests'
	@echo 'make e2e [SUITE=navigation-e2e]     all stdio E2E suites, or one (see zig build -l)'
	@echo 'make e2e-negative                   negative root variable rename E2E suite'
	@echo 'make zig-test FILE=test/x.zig [FILTER=name]  build, then run one Zig test root'
	@echo 'make zig ARGS="build -l"            any zig command with the macOS workaround'
	@echo 'make performance-ci ARGS="run --baseline-tree <path> --output <path>"  optimized CI comparison'
	@echo 'make smoke | parity | fmt | hooks | run ARGS=--version'

# Pre-commit gate; CI runs lint, test, e2e, and smoke as separate jobs.
check: lint build test

lint:
	zig fmt --check src build.zig build.zig.zon test
	python3 tools/lint/comments.py

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

e2e-negative:
	zig build variable-rename-negative-e2e

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
	nvim --headless -u NONE -l test/neovim_lsp.lua

# Compare zals against the upstream Ansible Language Server. Requires the
# upstream package (see test/parity/compare.py) and a built zals binary.
parity: build
	python3 test/parity/compare.py $(ARGS)

smoke: build
	python3 test/smoke_references.py
	python3 test/smoke_code_actions.py
	python3 test/smoke_role_navigation.py
	python3 test/smoke_workspace.py
	python3 test/smoke_cold_start.py
	python3 test/smoke_shutdown.py
	python3 test/benchmark_operations.py --files 2 --tasks 2 --sessions 1 --samples 1 --warmup 0 > /dev/null

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
	rm -rf zig-out .zig-cache zig-pkg