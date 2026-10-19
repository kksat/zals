import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { Errors, Manifest, setLogger, VERSION } from 'release-please';
import { Simple } from 'release-please/build/src/strategies/simple.js';
import { buildStrategy } from 'release-please/build/src/factory.js';
import { parseConventionalCommits } from 'release-please/build/src/commit.js';
import { TagName } from 'release-please/build/src/util/tag-name.js';
import { Version } from 'release-please/build/src/version.js';
import { installReleaseNotesGate, main, NOTES_STATUS, publishNotesStatuses,
  releaseOutputs, runReleasePlease, validateCandidate, validateNotesRef } from './runner.mjs';

setLogger({ debug() {}, info() {}, warn() {}, error() {} });
const sha = 'a'.repeat(40);
const approved = '## 0.2.0\n\n### Editing Ansible\n\n- Navigate role contracts confidently.\n';
function candidate(overrides = {}) {
  return { path: '.', sha, tag: TagName.parse('v0.2.0'), notes: 'technical commit list',
    name: 'v0.2.0', pullRequest: { number: 42 }, forceTag: true, ...overrides };
}

function fixture(candidates = [candidate()]) {
  const mutations = [];
  const github = {
    repository: { owner: 'kksat', repo: 'zals', defaultBranch: 'main' },
    async createRelease(release, options) {
      // Simulate the first upstream mutation, including forceTag's tag creation.
      if (options.forceTag) mutations.push(['tag', release.sha]);
      mutations.push(['release', release, options]);
      return { tagName: release.tag.toString(), notes: release.notes, url: 'https://example.test/release' };
    },
    async commentOnIssue(...args) { mutations.push(['comment', ...args]); },
    async removeIssueLabels(...args) { mutations.push(['removeLabels', ...args]); },
    async addIssueLabels(...args) { mutations.push(['addLabels', ...args]); },
  };
  // Exercise the real upstream createReleases implementation, not a replacement.
  const manifest = new Manifest(github, 'main', { '.': { releaseType: 'simple' } },
    { '.': Version.parse('0.1.0') }, { sequentialCalls: true });
  manifest.buildReleases = async () => candidates;
  return { github, manifest, mutations };
}

for (const fail of [async () => { throw new Error('approval missing'); }, async () => '', async () => ' \n']) {
  test(`validation failure prevents upstream tag, release, PR, comment, and labels: ${fail}`, async () => {
    const { github, manifest, mutations } = fixture();
    let loads = 0;
    await assert.rejects(runReleasePlease({ github, loadManifest: async () => { loads++; return manifest; },
      validate: fail, output: () => assert.fail('must not report a created release') }));
    assert.deepEqual(mutations, []);
    assert.equal(loads, 1, 'must not create a new release PR on validation failure');
  });
}

test('preflights every candidate before any upstream mutation', async () => {
  const { github, manifest, mutations } = fixture([candidate(), candidate({ sha: 'b'.repeat(40) })]);
  installReleaseNotesGate(github, manifest, async release => {
    if (release.sha !== sha) throw new Error('stale second candidate');
    return approved;
  });
  await assert.rejects(manifest.createReleases(), /stale second candidate/);
  assert.deepEqual(mutations, []);
});

test('initial create receives exact approved notes and unchanged upstream options/candidate', async () => {
  const release = candidate({ draft: false, prerelease: false });
  const { github, manifest, mutations } = fixture([release]);
  const originalCreate = github.createRelease;
  const originalBuild = manifest.buildReleases;
  let validations = 0;
  const restore = installReleaseNotesGate(github, manifest, async received => {
    assert.equal(received, release);
    validations++;
    assert.deepEqual(mutations, []);
    return approved;
  });
  const candidates = await manifest.buildReleases();
  assert.equal(candidates[0], release);
  const result = await manifest.createReleases();
  const created = mutations.find(([kind]) => kind === 'release');
  assert.equal(created[1].notes, approved);
  assert.deepEqual({ ...created[1], notes: release.notes }, release);
  assert.deepEqual(created[2], { draft: false, prerelease: false, forceTag: true });
  assert.equal(release.notes, 'technical commit list');
  assert.equal(result[0].notes, approved);
  assert.equal(validations, 1);
  assert.ok(mutations.some(([kind]) => kind === 'addLabels'));
  restore();
  assert.equal(github.createRelease, originalCreate);
  assert.equal(manifest.buildReleases, originalBuild);
});

test('actual createRelease boundary validates even without a build preflight', async () => {
  const { github, manifest, mutations } = fixture();
  installReleaseNotesGate(github, manifest, async () => { throw new Error('not approved'); });
  await assert.rejects(github.createRelease(candidate(), { forceTag: true }), /not approved/);
  assert.deepEqual(mutations, []);
});

test('rejects malformed, non-root, or SHA-less candidates before mutation', async () => {
  for (const override of [{ sha: undefined }, { sha: 'main' }, { path: 'editor' },
    { tag: TagName.parse('v0.2.0-beta.1') }, { pullRequest: undefined }]) {
    const { github, manifest, mutations } = fixture([candidate(override)]);
    installReleaseNotesGate(github, manifest, () => assert.fail('invalid candidate must not reach helper'));
    await assert.rejects(manifest.createReleases(), /Expected a single root release/);
    assert.deepEqual(mutations, []);
  }
});

test('helper validates candidate SHA, never workflow HEAD, preserving stdout exactly', async () => {
  const calls = [];
  const notes = await validateCandidate(candidate(), {
    repo: '/tmp/release repo', repository: 'kksat/zals', helper: '/trusted/notes.py',
    execute: async (...args) => { calls.push(args); return { stdout: approved }; },
  });
  assert.equal(notes, approved);
  assert.deepEqual(calls[0], ['git', ['-C', '/tmp/release repo', 'fetch', '--no-tags', 'origin', sha]]);
  assert.deepEqual(calls[1][1], ['/trusted/notes.py', '--repo', '/tmp/release repo', 'verify',
    '--ref', sha, '--version', '0.2.0', '--github-repository', 'kksat/zals']);
});

test('helper failure cannot fall back to technical notes', async () => {
  await assert.rejects(validateCandidate(candidate(), { repository: 'kksat/zals',
    execute: async command => {
      if (command === 'python3') throw new Error('approval rejected');
      return { stdout: '' };
    } }), /approval rejected/);
});

test('existing-release duplicate handling remains upstream and does not rewrite its body', async () => {
  const { github, manifest, mutations } = fixture();
  github.createRelease = async () => { throw new Errors.DuplicateReleaseError(new Error('exists'), 'tagName'); };
  installReleaseNotesGate(github, manifest, async () => approved);
  await assert.rejects(manifest.createReleases(), Errors.DuplicateReleaseError);
  assert.deepEqual(mutations.map(([kind]) => kind), ['removeLabels', 'addLabels']);
});

for (const releases of [[], [undefined], [{ path: '.', tagName: 'v0.2.0' }]]) {
  test(`outputs and fresh manifest for PR creation: ${JSON.stringify(releases)}`, async () => {
    const { github, manifest } = fixture();
    manifest.createReleases = async () => releases;
    const events = [];
    let loads = 0;
    const outputs = await runReleasePlease({ github,
      loadManifest: async () => {
        events.push('load');
        return ++loads === 1 ? manifest : { createPullRequests: async () => events.push('PR') };
      },
      output: value => events.push(value),
      updateStatuses: async () => events.push('status'),
    });
    const created = releases.some(Boolean);
    assert.deepEqual(outputs, { release_created: String(created), tag_name: created ? 'v0.2.0' : '' });
    assert.deepEqual(events, ['load', outputs, 'load', 'PR', 'status']);
  });
}

test('multiple pending root releases retain the stock action last-tag output', () => {
  assert.deepEqual(releaseOutputs([{ tagName: 'v0.2.0' }, { tagName: 'v0.3.0' }]),
    { release_created: 'true', tag_name: 'v0.3.0' });
});

// These snapshots come from the same pinned strategy as the stock v4 action.
// The gate cannot change Conventional Commit calculation or generated PR data.
for (const [message, previous, expected] of [
  ['feat: navigate roles', '0.1.0', '0.2.0'],
  ['fix: resolve role paths', '0.1.0', '0.1.1'],
  ['feat!: remove old setting', '0.1.0', '1.0.0'],
  ['feat!: remove old setting', '1.2.3', '2.0.0'],
  ['docs: clarify installation', '0.1.0', undefined],
]) {
  test(`upstream version and candidate regression: ${message} from ${previous}`, async () => {
    assert.equal(VERSION, '17.3.0');
    const { github, manifest, mutations } = fixture();
    const strategy = new Simple({ github, targetBranch: 'main', changelogPath: 'TECHNICAL_CHANGELOG.md' });
    const commits = parseConventionalCommits([{ sha, message, files: ['src/main.zig'] }]);
    const latest = { tag: TagName.parse(`v${previous}`), sha: 'b'.repeat(40) };
    const before = await strategy.buildReleasePullRequest(commits, latest);
    installReleaseNotesGate(github, manifest, async () => approved);
    const after = await strategy.buildReleasePullRequest(commits, latest);
    assert.equal(after?.version.toString(), expected);
    assert.deepEqual(after, before, 'the generated upstream release PR stays unchanged');
    if (!after) return;
    assert.deepEqual(after.updates.map(update => update.path), ['TECHNICAL_CHANGELOG.md', 'version.txt']);
    const pr = { number: 42, sha, title: after.title.toString(), body: after.body.toString(),
      headBranchName: after.headRefName, labels: [], files: [] };
    const built = (await strategy.buildReleases(pr))[0];
    const release = { ...built, path: '.', pullRequest: pr };
    const original = { ...release };
    await github.createRelease(release, {});
    assert.deepEqual(release, original);
    const created = mutations.find(([kind]) => kind === 'release')[1];
    assert.deepEqual({ ...created, notes: original.notes }, original);
    assert.equal(created.notes, approved);
  });
}

async function configuredRelease(config) {
  const github = {
    repository: { owner: 'kksat', repo: 'zals', defaultBranch: 'main' },
    getFileJson: async path => path === 'release-please-config.json' ? config : { '.': '0.1.0' },
  };
  const manifest = await Manifest.fromManifest(github, 'main');
  const strategy = await buildStrategy({ ...manifest.repositoryConfig['.'], github,
    targetBranch: 'main', path: '.' });
  const commits = parseConventionalCommits([{ sha, message: 'feat: navigate roles', files: ['src/main.zig'] }]);
  const pr = await strategy.buildReleasePullRequest(commits,
    { tag: TagName.parse('v0.1.0'), sha: 'b'.repeat(40) });
  const merged = { number: 42, sha, title: pr.title.toString(), body: pr.body.toString(),
    headBranchName: pr.headRefName, labels: ['autorelease: pending'], files: [] };
  github.pullRequestIterator = async function* () { yield merged; };
  return { manifest, version: pr.version.toString(), release: (await manifest.buildReleases())[0] };
}

for (const [name, override, expectedTag] of [
  ['original package-name configuration', undefined, 'zals-v0.2.0'],
  ['explicit root include-component-in-tag false', false, 'v0.2.0'],
]) {
  test(`actual Manifest config/tag regression: ${name}`, async () => {
    const config = JSON.parse(await readFile(new URL('../../release-please-config.json', import.meta.url), 'utf8'));
    assert.equal(config.packages['.']['package-name'], 'zals');
    // Reproduce the original config's omitted setting independently of the
    // integration config fix, then exercise the minimal explicit correction.
    delete config.packages['.']['include-component-in-tag'];
    if (override !== undefined) config.packages['.']['include-component-in-tag'] = override;
    const { version, release } = await configuredRelease(config);
    assert.equal(version, '0.2.0', 'tag spelling must not change version calculation');
    assert.equal(release.tag.toString(), expectedTag);
    assert.equal(release.sha, sha);
    assert.equal(release.pullRequest.number, 42);
  });
}

test('checked-in config passes unchanged through actual Manifest loading and tag construction', async () => {
  const config = JSON.parse(await readFile(new URL('../../release-please-config.json', import.meta.url), 'utf8'));
  const { version, release } = await configuredRelease(config);
  assert.equal(version, '0.2.0');
  assert.equal(release.tag.toString(),
    config.packages['.']['include-component-in-tag'] === false ? 'v0.2.0' : 'zals-v0.2.0');
});

test('PR-head helper reads version from the candidate, not the workflow checkout', async () => {
  const calls = [];
  await validateNotesRef(sha, { repository: 'kksat/zals',
    execute: async (...args) => { calls.push(args); return { stdout: approved }; } });
  assert.ok(calls[1][1].includes(sha));
  assert.ok(!calls[1][1].includes('--version'));
});

function statusFixture({ getError, statusError, untrusted = false } = {}) {
  const statuses = [];
  const pull = { number: 42, state: 'open', user: { login: 'github-actions[bot]' },
    base: { ref: 'main' }, head: { ref: 'release-please--branches--main', sha,
      repo: { full_name: 'kksat/zals' } } };
  const github = { repository: { owner: 'kksat', repo: 'zals', defaultBranch: 'main' },
    octokit: {
      paginate: { async *iterator() {
        yield { data: [{ ...pull, head: { ...pull.head, sha: 'b'.repeat(40) } }] };
      } },
      async request(route, options) {
        if (route.startsWith('GET')) {
          if (getError) throw new Error('PR read failed');
          return { data: untrusted ? { ...pull, user: { login: 'someone-else' } } : pull };
        }
        if (statusError) throw new Error('status write failed');
        statuses.push(options);
      },
    },
  };
  return { github, statuses };
}

for (const outcome of ['approved', 'missing', 'empty']) {
  test(`automatic status binds fresh exact PR head, outcome: ${outcome}`, async () => {
    const { github, statuses } = statusFixture();
    await publishNotesStatuses({ github, report() {}, targetUrl: 'https://example.test/run',
      validateHead: async head => {
        assert.equal(head, sha, 'must resolve current PR head, not a list snapshot or merge SHA');
        assert.equal(statuses[0].state, 'pending', 'old green status is reset before verification');
        if (outcome === 'missing') throw new Error('notes not approved yet');
        return outcome === 'empty' ? '' : approved;
      } });
    assert.deepEqual(statuses.map(status => status.state),
      ['pending', outcome === 'approved' ? 'success' : 'failure']);
    for (const status of statuses) {
      assert.equal(status.sha, sha);
      assert.equal(status.context, NOTES_STATUS);
      assert.equal(status.target_url, 'https://example.test/run');
    }
  });
}

for (const failure of [{ getError: true }, { statusError: true }, { untrusted: true }]) {
  test(`status API/identity errors never report green: ${JSON.stringify(failure)}`, async () => {
    const { github, statuses } = statusFixture(failure);
    await assert.rejects(publishNotesStatuses({ github,
      validateHead: () => assert.fail('API/identity error must not reach validation') }));
    assert.ok(!statuses.some(status => status.state === 'success'));
  });
}

test('CLI refuses to run without required GitHub environment', async () => {
  await assert.rejects(main({}), /GH_TOKEN, GITHUB_REPOSITORY, and GITHUB_OUTPUT/);
});
