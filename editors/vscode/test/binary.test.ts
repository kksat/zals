import test from "node:test";
import assert from "node:assert/strict";
import * as path from "node:path";
import { resolveBinaryPath } from "../src/binary.ts";

test("resolveBinaryPath returns bin/zals on POSIX systems (linux, darwin)", () => {
  const extPath = "/path/to/extension";
  const linuxPath = resolveBinaryPath(extPath, "linux");
  assert.equal(linuxPath, path.join(extPath, "bin", "zals"));

  const darwinPath = resolveBinaryPath(extPath, "darwin");
  assert.equal(darwinPath, path.join(extPath, "bin", "zals"));
});

test("resolveBinaryPath returns bin/zals.exe on win32", () => {
  const extPath = "C:\\path\\to\\extension";
  const winPath = resolveBinaryPath(extPath, "win32");
  assert.equal(winPath, path.join(extPath, "bin", "zals.exe"));
});
