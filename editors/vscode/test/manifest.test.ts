import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";

const pkgPath = path.resolve(process.cwd(), "package.json");
const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf-8"));

test("manifest has required identity", () => {
  assert.equal(pkg.publisher, "kksat");
  assert.equal(pkg.name, "zals");
  assert.equal(pkg.displayName, "Ansible Language Server (zals)");
});

test("manifest disables untrusted workspaces", () => {
  assert.equal(pkg.capabilities?.untrustedWorkspaces?.supported, false);
});

test("manifest requires VS Code engine ^1.82.0", () => {
  assert.equal(pkg.engines?.vscode, "^1.82.0");
});

test("manifest contributes only language client and no commands", () => {
  assert.equal(pkg.contributes?.commands, undefined);
});

test("manifest contributes exactly the 9 approved settings", () => {
  const properties = pkg.contributes?.configuration?.properties;
  assert.ok(properties, "configuration.properties should exist");

  const keys = Object.keys(properties).sort();
  const expectedKeys = [
    "ansible.ansible.path",
    "ansible.ansible.useFullyQualifiedCollectionNames",
    "ansible.completion.provideModuleOptionAliases",
    "ansible.completion.provideRedirectModules",
    "ansible.validation.enabled",
    "ansible.validation.lint.arguments",
    "ansible.validation.lint.autoFixOnSave",
    "ansible.validation.lint.enabled",
    "ansible.validation.lint.path",
  ].sort();

  assert.deepEqual(keys, expectedKeys);

  // Assert no python configuration is present
  const pythonKeys = keys.filter((k) => k.startsWith("ansible.python."));
  assert.deepEqual(pythonKeys, []);
});

test("manifest contributes language and grammar", () => {
  const languages = pkg.contributes?.languages;
  assert.equal(languages?.length, 1);
  assert.equal(languages[0].id, "ansible");

  const expectedFilenames = [
    "site.yml",
    "site.yaml",
    "galaxy.yml",
    "galaxy.yaml",
    "execution-environment.yml",
    "execution-environment.yaml",
    "requirements.yml",
    "requirements.yaml",
  ];
  assert.deepEqual(languages[0].filenames.sort(), expectedFilenames.sort());

  const grammars = pkg.contributes?.grammars;
  assert.equal(grammars?.length, 1);
  assert.equal(grammars[0].language, "ansible");
  assert.equal(grammars[0].scopeName, "source.ansible");
});
