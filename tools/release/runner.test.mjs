import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { Errors, GitHub, Manifest, setLogger, VERSION } from 'release-please';
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
  const tags = new Map();
  const github = {
    octokit: { git: {
      async getRef({ ref }) {
        if (!tags.has(ref)) throw Object.assign(new Error('Not found'), { status: 404 });
        return { data: { object: { type: 'commit', sha: tags.get(ref) } } };
      },
      async createRef({ ref, sha }) {
        tags.set(ref.replace(/^refs\//, ''), sha);
        mutations.push(['tag', sha]);
      },
    } },
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

test('initial create receives exact notes/options and candidate; gate owns atomic tag claim', async () => {
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
  assert.deepEqual(created[2], { draft: false, prerelease: false, forceTag: false });
  assert.equal(mutations.filter(([kind]) => kind === 'tag').length, 1);
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
  github.octokit.git.getRef = async () => ({ data: { object: { type: 'commit', sha } } });
  github.createRelease = async () => { throw new Errors.DuplicateReleaseError(new Error('exists'), 'tagName'); };
  installReleaseNotesGate(github, manifest, async () => approved);
  await assert.rejects(manifest.createReleases(), Errors.DuplicateReleaseError);
  assert.deepEqual(mutations.map(([kind]) => kind), ['removeLabels', 'addLabels']);
});

// Real pinned GitHub.createRelease + Manifest; only REST is fake. GitHub ignores
// target_commitish for existing tags, so recording the actual tag is essential.
async function upstreamTagFixture({ target = null, annotated = false, race, forceTag = false,
  refError, tagError, claimError, raceAnnotated = false } = {}) {
  const calls = [];
  let object = target && { type: annotated ? 'tag' : 'commit', sha: annotated ? 'c'.repeat(40) : target };
  const tagObjects = new Map([
    ['c'.repeat(40), { type: 'tag', sha: 'd'.repeat(40) }],
    ['d'.repeat(40), { type: 'commit', sha: race ?? target }],
  ]);
  const octokit = {
    git: {
      async getRef(args) {
        calls.push(['getRef', args]);
        if (refError) throw Object.assign(new Error('Ref read failed'), { status: refError });
        if (!object) throw Object.assign(new Error('Not found'), { status: 404 });
        return { data: { object } };
      },
      async getTag({ tag_sha }) {
        calls.push(['getTag', tag_sha]);
        if (tagError) throw Object.assign(new Error('Tag read failed'), { status: tagError });
        return { data: { object: tagObjects.get(tag_sha) } };
      },
      async createRef(args) {
        calls.push(['createRef', args]);
        if (claimError) throw Object.assign(new Error('Claim failed'), { status: claimError });
        if (race) {
          object = { type: raceAnnotated ? 'tag' : 'commit', sha: raceAnnotated ? 'c'.repeat(40) : race };
          throw Object.assign(new Error('Reference already exists'), { status: 422 });
        }
        assert.equal(object, null, 'must not blindly repeat upstream forceTag ref creation');
        object = { type: 'commit', sha: args.sha };
        return { data: { object } };
      },
    },
    repos: { async createRelease(args) {
      let actual = object;
      while (actual?.type === 'tag') actual = tagObjects.get(actual.sha);
      calls.push(['release', { ...args, actualTagTarget: actual?.sha }]);
      return { data: { id: 1, tag_name: args.tag_name, target_commitish: args.target_commitish,
        body: args.body, html_url: 'https://example.test/release', upload_url: 'https://example.test/upload' } };
    } },
    issues: {
      async createComment() { calls.push(['comment']); return { data: {} }; },
      async removeLabel() { calls.push(['removeLabel']); return { data: {} }; },
      async addLabels() { calls.push(['addLabels']); return { data: {} }; },
    },
  };
  const github = await GitHub.create({ owner: 'kksat', repo: 'zals', defaultBranch: 'main',
    octokitAPIs: { octokit, request: async () => assert.fail('unexpected network request'),
      graphql: async () => assert.fail('unexpected graphql') } });
  const manifest = new Manifest(github, 'main', { '.': { releaseType: 'simple' } },
    { '.': Version.parse('0.1.0') }, { sequentialCalls: true });
  manifest.buildReleases = async () => [candidate({ forceTag })];
  installReleaseNotesGate(github, manifest, async () => approved);
  return { github, manifest, calls, setTarget: value => { object = { type: 'commit', sha: value }; } };
}

for (const forceTag of [false, true]) {
  for (const annotated of [false, true]) {
    test(`real upstream rejects mismatched existing tag; forceTag=${forceTag}, annotated=${annotated}`, async () => {
      const { manifest, calls } = await upstreamTagFixture({ target: 'b'.repeat(40), forceTag, annotated });
      await assert.rejects(manifest.createReleases(), /must resolve to approved candidate/);
      assert.ok(!calls.some(([kind]) => ['createRef', 'release', 'comment', 'removeLabel', 'addLabels'].includes(kind)));
      if (annotated) assert.equal(calls.filter(([kind]) => kind === 'getTag').length, 2);
    });
    test(`real upstream accepts matching peeled tag without changing it; forceTag=${forceTag}, annotated=${annotated}`, async () => {
      const { manifest, calls } = await upstreamTagFixture({ target: sha, forceTag, annotated });
      const releases = await manifest.createReleases();
      assert.equal(releases[0].tagName, 'v0.2.0');
      assert.ok(!calls.some(([kind]) => kind === 'createRef'));
      assert.equal(calls.find(([kind]) => kind === 'release')[1].actualTagTarget, sha);
      assert.equal(calls.find(([kind]) => kind === 'release')[1].body, approved);
      assert.deepEqual(calls.filter(([kind]) => ['comment', 'removeLabel', 'addLabels'].includes(kind))
        .map(([kind]) => kind), ['comment', 'removeLabel', 'addLabels']);
    });
  }
  for (const race of [undefined, sha, 'b'.repeat(40)]) {
    test(`real upstream atomically claims absent ref and checks 422 race; forceTag=${forceTag}, race=${race}`, async () => {
      const { manifest, calls } = await upstreamTagFixture({ forceTag, race });
      if (race && race !== sha) {
        await assert.rejects(manifest.createReleases(), /must resolve to approved candidate/);
        assert.ok(!calls.some(([kind]) => ['release', 'comment', 'removeLabel', 'addLabels'].includes(kind)));
      } else {
        await manifest.createReleases();
        assert.equal(calls.find(([kind]) => kind === 'release')[1].actualTagTarget, sha);
      }
      const claims = calls.filter(([kind]) => kind === 'createRef');
      assert.equal(claims.length, 1);
      assert.deepEqual(claims[0][1], { owner: 'kksat', repo: 'zals', ref: 'refs/tags/v0.2.0', sha });
    });
  }
}

for (const race of [sha, 'b'.repeat(40)]) {
  test(`422 race re-peels an annotated competing tag: ${race}`, async () => {
    const { manifest, calls } = await upstreamTagFixture({ race, raceAnnotated: true });
    if (race === sha) await manifest.createReleases();
    else await assert.rejects(manifest.createReleases(), /must resolve to approved candidate/);
    assert.ok(calls.some(([kind]) => kind === 'getTag'));
    assert.equal(calls.some(([kind]) => kind === 'release'), race === sha);
  });
}

test('final delegate guard rejects a ref changed after the atomic claim was verified', async () => {
  const { github, manifest, calls, setTarget } = await upstreamTagFixture();
  const getRef = github.octokit.git.getRef;
  let reads = 0;
  github.octokit.git.getRef = async args => {
    if (++reads === 4) setTarget('b'.repeat(40));
    return getRef(args);
  };
  await assert.rejects(manifest.createReleases(), /must resolve to approved candidate/);
  assert.ok(calls.some(([kind]) => kind === 'createRef'));
  assert.ok(!calls.some(([kind]) => kind === 'release'));
});

for (const refError of [401, 403, 422, 500]) {
  test(`tag GET ${refError} is not treated as absence`, async () => {
    const { manifest, calls } = await upstreamTagFixture({ refError });
    await assert.rejects(manifest.createReleases(), /Ref read failed/);
    assert.ok(!calls.some(([kind]) => ['createRef', 'release'].includes(kind)));
  });
}

for (const options of [{ target: sha, annotated: true, tagError: 404 },
  { claimError: 422 }, { claimError: 403 }, { claimError: 500 }]) {
  test(`broken annotation or unsuccessful atomic claim fails closed: ${JSON.stringify(options)}`, async () => {
    const { manifest, calls } = await upstreamTagFixture(options);
    await assert.rejects(manifest.createReleases());
    assert.ok(!calls.some(([kind]) => ['release', 'comment', 'removeLabel', 'addLabels'].includes(kind)));
  });
}

test('tag is checked again at actual delegate even after approved preflight', async () => {
  const { github, manifest, calls, setTarget } = await upstreamTagFixture({ target: sha });
  const [release] = await manifest.buildReleases();
  setTarget('b'.repeat(40));
  await assert.rejects(github.createRelease(release, {}), /must resolve to approved candidate/);
  assert.ok(!calls.some(([kind]) => kind === 'release'));
});

test('all existing tags preflight before claiming the first absent candidate tag', async () => {
  const { github, manifest, calls } = await upstreamTagFixture();
  const build = manifest.buildReleases;
  // Build two candidates through the gate, with the second tag already wrong.
  const second = candidate({ tag: TagName.parse('v0.3.0') });
  manifest.buildReleases = async () => [...await build(), second];
  const underlying = github.octokit.git.getRef;
  github.octokit.git.getRef = async args => args.ref === 'tags/v0.3.0'
    ? { data: { object: { type: 'commit', sha: 'b'.repeat(40) } } } : underlying(args);
  // Reinstall around the extended build so all tags are still preflighted.
  installReleaseNotesGate(github, manifest, async () => approved);
  await assert.rejects(manifest.createReleases(), /must resolve to approved candidate/);
  assert.ok(!calls.some(([kind]) => ['createRef', 'release'].includes(kind)));
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
  assert.equal(config.packages['.']['include-component-in-tag'], false,
    'the root release config must explicitly preserve documented vX.Y.Z tags');
  const { version, release } = await configuredRelease(config);
  assert.equal(version, '0.2.0');
  assert.equal(release.tag.toString(), 'v0.2.0');
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
        if (route.includes('/git/ref/')) {
          return { data: { object: { type: 'commit', sha: 'c'.repeat(40) } } };
        }
        if (route.includes('/compare/')) return { data: { behind_by: 0 } };
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

for (const approvedHead of [true, false]) {
  test(`unchanged bot PR automatically refreshes from main and statuses only updated head; approved=${approvedHead}`, async () => {
    const { github, statuses } = statusFixture();
    const request = github.octokit.request;
    const newHead = 'e'.repeat(40);
    const updates = [];
    let polling = false;
    let polls = 0;
    github.octokit.request = async (route, args) => {
      if (route.startsWith('PUT')) {
        updates.push(args);
        polling = true;
        return { status: 202 };
      }
      if (route.includes('/compare/')) {
        return { data: { behind_by: args.basehead.endsWith(newHead) ? 0 : 1 } };
      }
      const response = await request(route, args);
      if (polling && route.includes('/pulls/')) {
        polls++;
        if (polls >= 2) return { data: { ...response.data, head: { ...response.data.head, sha: newHead } } };
      }
      return response;
    };
    await publishNotesStatuses({ github, refreshOptions: { wait: async () => {}, pollAttempts: 3 }, report() {},
      validateHead: async head => {
        assert.equal(head, newHead);
        if (!approvedHead) throw new Error('notes expected to be incomplete while drafting');
        return approved;
      } });
    assert.deepEqual(updates, [{ owner: 'kksat', repo: 'zals', pull_number: 42, expected_head_sha: sha }]);
    assert.equal(polls, 2, 'must poll until GitHub actually returns a changed head');
    assert.deepEqual(statuses.map(({ sha, state }) => [sha, state]),
      [[sha, 'pending'], [newHead, 'pending'], [newHead, approvedHead ? 'success' : 'failure']]);
  });
}

for (const problem of ['compare unavailable', 'malformed comparison', 'invalid base',
  'update conflict', 'poll timeout', 'identity changed']) {
  test(`branch refresh fails closed without green or validating stale head: ${problem}`, async () => {
    const { github, statuses } = statusFixture();
    const request = github.octokit.request;
    let polling = false;
    github.octokit.request = async (route, args) => {
      if (route.includes('/git/ref/') && problem === 'invalid base') return { data: {} };
      if (route.includes('/compare/')) {
        if (problem === 'compare unavailable') throw new Error('compare unavailable');
        if (problem === 'malformed comparison') return { data: {} };
        return { data: { behind_by: 1 } };
      }
      if (route.startsWith('PUT')) {
        if (problem === 'update conflict') throw Object.assign(new Error('update conflict'), { status: 422 });
        polling = true;
        return { status: 202 };
      }
      const response = await request(route, args);
      if (polling && route.includes('/pulls/') && problem === 'identity changed') {
        return { data: { ...response.data, user: { login: 'someone-else' } } };
      }
      return response;
    };
    await assert.rejects(publishNotesStatuses({ github,
      refreshOptions: { wait: async () => {}, pollAttempts: 2 },
      validateHead: () => assert.fail('must not validate an unrefreshed or untrusted head') }));
    assert.deepEqual(statuses.map(status => status.state), ['pending', 'failure']);
  });
}

test('CLI refuses to run without required GitHub environment', async () => {
  await assert.rejects(main({}), /GH_TOKEN, GITHUB_REPOSITORY, and GITHUB_OUTPUT/);
});
