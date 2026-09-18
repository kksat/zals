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

.PHONY: build test run fmt clean

build:
	zig build

test:
	zig build test

run: build
	./zig-out/bin/zals $(ARGS)

fmt:
	zig fmt src build.zig

clean:
	rm -rf zig-out .zig-cache