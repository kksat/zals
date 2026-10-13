import test from "node:test";
import assert from "node:assert/strict";
import { createClientOptions } from "../src/clientOptions.ts";

test("createClientOptions attaches to file and untitled schemes for ansible language", () => {
  const options = createClientOptions();

  assert.deepEqual(options.documentSelector, [
    { scheme: "file", language: "ansible" },
    { scheme: "untitled", language: "ansible" },
  ]);
});

test("createClientOptions synchronizes ansible configuration section and sets initializationOptions", () => {
  const mockConfig = {
    ansible: { path: "ansible" },
    validation: { enabled: true, lint: { enabled: true, path: "ansible-lint" } },
  };
  const options = createClientOptions(mockConfig);

  assert.equal(options.synchronize?.configurationSection, "ansible");
  assert.deepEqual(options.initializationOptions, { ansible: mockConfig });
});
