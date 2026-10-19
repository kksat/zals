// Keep release-please's version, PR, label, and release mechanics upstream.
// Bind each tag to the approved product before publishing the curated body.
import { execFile } from 'node:child_process';
import { appendFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { setTimeout as sleep } from 'node:timers/promises';
import { GitHub, Manifest } from 'release-please';

const exec = promisify(execFile);

function candidateIdentity(release) {
  const tag = release.tag.toString();
  const version = release.tag.version.toString();
  if ((release.path && release.path !== '.') || tag !== `v${version}` ||
      !/^\d+\.\d+\.\d+$/.test(version) || !/^[a-f0-9]{40}$/.test(release.sha ?? '') ||
      !Number.isInteger(release.pullRequest?.number)) {
    throw new Error('Expected a single root release with a semantic version, candidate SHA, and pull request');
  }
  return `${release.sha}:${tag}:${release.pullRequest.number}`;
}

function requireNotes(notes) {
  if (typeof notes !== 'string' || !notes.trim()) {
    throw new Error('The curated notes validator returned an empty release body');
  }
  return notes;
}

export async function readTagCommit(github, tag) {
  const { owner, repo } = github.repository;
  const api = github.octokit.git;
  let object;
  try {
    object = (await api.getRef({ owner, repo, ref: `tags/${tag}` })).data.object;
  } catch (error) {
    if (error.status === 404) return null;
    throw error;
  }
  const seen = new Set();
  while (object?.type === 'tag') {
    if (!/^[a-f0-9]{40}$/.test(object.sha ?? '') || seen.has(object.sha) || seen.size >= 100) {
      throw new Error(`Invalid or cyclic annotated tag ${tag}`);
    }
    seen.add(object.sha);
    // A broken annotated tag (even a 404) is not an absent ref.
    object = (await api.getTag({ owner, repo, tag_sha: object.sha })).data.object;
  }
  if (object?.type !== 'commit' || !/^[a-f0-9]{40}$/.test(object.sha ?? '')) {
    throw new Error(`Tag ${tag} does not resolve to a commit`);
  }
  return object.sha;
}

export async function assertReleaseTag(github, release, { claim = false, required = false } = {}) {
  candidateIdentity(release);
  const tag = release.tag.toString();
  let target = await readTagCommit(github, tag);
  if (target === null && claim) {
    const { owner, repo } = github.repository;
    try {
      // An atomic create, never update/force: a competing creator cannot move it.
      await github.octokit.git.createRef({ owner, repo, ref: `refs/tags/${tag}`, sha: release.sha });
    } catch (error) {
      if (error.status !== 422) throw error;
      // Unlike upstream forceTag, 422 is not proof of an acceptable target.
    }
    target = await readTagCommit(github, tag);
    required = true;
  }
  if ((target === null && required) || (target !== null && target !== release.sha)) {
    throw new Error(`Release tag ${tag} must resolve to approved candidate ${release.sha}; found ${target ?? 'no tag'}`);
  }
}

// Preflight *all* candidates before createReleases can mutate tags/releases or
// labels. Also guard the actual createRelease boundary (before forceTag runs),
// including a candidate discovered after preflight. Never alter a candidate.
export function installReleaseNotesGate(github, manifest, validate) {
  const createRelease = github.createRelease;
  const buildReleases = manifest.buildReleases;
  const approved = new Map();
  async function notesFor(release) {
    const identity = candidateIdentity(release);
    if (!approved.has(identity)) {
      approved.set(identity, requireNotes(await validate(release)));
    }
    return approved.get(identity);
  }
  manifest.buildReleases = async function (...args) {
    const candidates = await buildReleases.apply(this, args);
    for (const candidate of candidates) {
      await notesFor(candidate);
      await assertReleaseTag(github, candidate);
    }
    return candidates;
  };
  github.createRelease = async function (release, options) {
    const notes = await notesFor(release);
    await assertReleaseTag(github, release, { claim: true });
    await assertReleaseTag(github, release, { required: true });
    // 17.3.0's forceTag catches every createRef 422 and continues. Our atomic
    // claim already established the tag; do not re-enter that unsafe fallback.
    return createRelease.call(this, { ...release, notes }, { ...options, forceTag: false });
  };
  return () => {
    github.createRelease = createRelease;
    manifest.buildReleases = buildReleases;
  };
}

export async function validateNotesRef(sha, {
  version,
  repo = process.cwd(),
  repository = process.env.GITHUB_REPOSITORY,
  helper = fileURLToPath(new URL('./notes.py', import.meta.url)),
  execute = exec,
} = {}) {
  if (!/^[a-f0-9]{40}$/.test(sha ?? '')) throw new Error('Expected an exact candidate SHA');
  if (!/^[\w.-]+\/[\w.-]+$/.test(repository ?? '')) {
    throw new Error('GITHUB_REPOSITORY must be OWNER/REPO');
  }
  // Full history and tags are checked out by the workflow. Explicitly fetch the
  // candidate as it may predate this workflow revision or be newly discovered.
  await execute('git', ['-C', repo, 'fetch', '--no-tags', 'origin', sha]);
  const { stdout } = await execute('python3', [helper, '--repo', repo, 'verify',
    '--ref', sha, ...(version ? ['--version', version] : []),
    '--github-repository', repository], { maxBuffer: 4 * 1024 * 1024 });
  return requireNotes(stdout);
}

export async function validateCandidate(release, options = {}) {
  candidateIdentity(release);
  return validateNotesRef(release.sha, { ...options, version: release.tag.version.toString() });
}

export const NOTES_STATUS = 'approved curated release notes';

function isReleasePullRequest(pull, repository) {
  return pull.state === 'open' && pull.user?.login === 'github-actions[bot]' &&
    pull.base?.ref === repository.defaultBranch &&
    pull.head?.repo?.full_name === `${repository.owner}/${repository.repo}` &&
    pull.head.ref.startsWith('release-please--branches--');
}

function requireReleasePullRequest(pull, repository) {
  if (!isReleasePullRequest(pull, repository) || !/^[a-f0-9]{40}$/.test(pull.head.sha ?? '')) {
    throw new Error('Release PR identity changed while resolving its exact head');
  }
  return pull;
}

// release-please skips an unchanged PR body, even when approved notes merged on
// main. Refresh only that strict bot branch, with GitHub's expected-head guard;
// never force-push or validate the old head while an update is still pending.
export async function refreshReleasePullRequest(github, pull, {
  wait = sleep, pollAttempts = 30, pollDelay = 2000, maxRefreshes = 3,
} = {}) {
  const { owner, repo, defaultBranch } = github.repository;
  const api = github.octokit;
  requireReleasePullRequest(pull, github.repository);
  for (let refresh = 0; refresh < maxRefreshes; refresh++) {
    const { data: base } = await api.request('GET /repos/{owner}/{repo}/git/ref/{ref}',
      { owner, repo, ref: `heads/${defaultBranch}` });
    if (base.object?.type !== 'commit' || !/^[a-f0-9]{40}$/.test(base.object.sha ?? '')) {
      throw new Error('Cannot resolve the current release base commit');
    }
    const { data: comparison } = await api.request('GET /repos/{owner}/{repo}/compare/{basehead}',
      { owner, repo, basehead: `${base.object.sha}...${pull.head.sha}` });
    if (!Number.isInteger(comparison.behind_by) || comparison.behind_by < 0) {
      throw new Error('Cannot determine whether the release PR includes the current base');
    }
    if (comparison.behind_by === 0) return pull;
    const expected = pull.head.sha;
    await api.request('PUT /repos/{owner}/{repo}/pulls/{pull_number}/update-branch',
      { owner, repo, pull_number: pull.number, expected_head_sha: expected });
    let updated;
    for (let attempt = 0; attempt < pollAttempts; attempt++) {
      await wait(pollDelay);
      const { data } = await api.request('GET /repos/{owner}/{repo}/pulls/{pull_number}',
        { owner, repo, pull_number: pull.number });
      updated = requireReleasePullRequest(data, github.repository);
      if (updated.head.sha !== expected) break;
    }
    if (!updated || updated.head.sha === expected) {
      throw new Error('Timed out waiting for the release PR branch update');
    }
    pull = updated;
  }
  throw new Error('Release base kept advancing while refreshing the release PR');
}

// GITHUB_TOKEN suppresses PR workflow events, so publish a commit status directly
// after upstream PR creation/update. List also finds unchanged PRs for reruns.
// This is not the pre-tag gate: missing notes are expected while drafting a PR.
export async function publishNotesStatuses({ github, validateHead = validateNotesRef,
  report = message => console.error(message), targetUrl, refreshOptions }) {
  const { owner, repo, defaultBranch } = github.repository;
  const api = github.octokit;
  for await (const { data: pulls } of api.paginate.iterator('GET /repos/{owner}/{repo}/pulls',
    { owner, repo, state: 'open', base: defaultBranch, per_page: 100 })) {
    for (const listed of pulls) {
      if (!isReleasePullRequest(listed, github.repository)) continue;
      // Never assume the upstream PullRequest.sha means head SHA (it denotes the
      // merge commit). Fetch the exact current head from the REST PR object.
      const { data } = await api.request('GET /repos/{owner}/{repo}/pulls/{pull_number}',
        { owner, repo, pull_number: listed.number });
      let pull = requireReleasePullRequest(data, github.repository);
      const status = (state, description) => api.request('POST /repos/{owner}/{repo}/statuses/{sha}',
        { owner, repo, sha: pull.head.sha, state, description, context: NOTES_STATUS,
          ...(targetUrl ? { target_url: targetUrl } : {}) });
      await status('pending', 'Refreshing and validating approved notes for this release PR');
      const originalHead = pull.head.sha;
      try {
        pull = await refreshReleasePullRequest(github, pull, refreshOptions);
      } catch (error) {
        await status('failure', 'Could not safely refresh the release PR from its current base');
        throw error;
      }
      const sha = pull.head.sha;
      if (sha !== originalHead) {
        await status('pending', 'Validating approved notes for the refreshed release PR head');
      }
      try {
        requireNotes(await validateHead(sha));
      } catch (error) {
        await status('failure', 'Curated notes missing, stale, unapproved, or verification unavailable');
        report(`Release PR #${pull.number} (${sha}) notes validation failed: ${error.message}`);
        continue;
      }
      await status('success', 'Approved curated notes cover this exact release PR head');
    }
  }
}

export function releaseOutputs(releases) {
  const roots = releases.filter(release => release && (!release.path || release.path === '.'));
  // The action writes root outputs once per release, leaving the last tag when
  // recovering multiple pending release PRs. Preserve that upstream behavior.
  return { release_created: String(roots.length > 0), tag_name: roots.at(-1)?.tagName ?? '' };
}

export async function runReleasePlease({ github, loadManifest, validate = validateCandidate,
  updateStatuses = async () => {}, output = async () => {} }) {
  const manifest = await loadManifest();
  const restore = installReleaseNotesGate(github, manifest, validate);
  let outputs;
  try {
    outputs = releaseOutputs(await manifest.createReleases());
    await output(outputs);
  } finally {
    restore();
  }
  // As in release-please-action v4, reload the manifest after publishing so the
  // next PR uses the newly released versions, not the pre-release snapshot.
  const nextManifest = await loadManifest();
  await nextManifest.createPullRequests();
  await updateStatuses();
  return outputs;
}

export async function main(env = process.env) {
  if (!env.GH_TOKEN || !/^[\w.-]+\/[\w.-]+$/.test(env.GITHUB_REPOSITORY ?? '') || !env.GITHUB_OUTPUT) {
    throw new Error('GH_TOKEN, GITHUB_REPOSITORY, and GITHUB_OUTPUT are required');
  }
  const [owner, repo] = env.GITHUB_REPOSITORY.split('/');
  const github = await GitHub.create({ owner, repo, token: env.GH_TOKEN });
  await runReleasePlease({
    github,
    loadManifest: () => Manifest.fromManifest(github, github.repository.defaultBranch,
      'release-please-config.json', '.release-please-manifest.json'),
    validate: release => validateCandidate(release, { repository: env.GITHUB_REPOSITORY }),
    updateStatuses: () => publishNotesStatuses({ github,
      validateHead: sha => validateNotesRef(sha, { repository: env.GITHUB_REPOSITORY }),
      targetUrl: env.GITHUB_RUN_ID
        ? `${env.GITHUB_SERVER_URL ?? 'https://github.com'}/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}`
        : undefined }),
    output: outputs => appendFile(env.GITHUB_OUTPUT,
      Object.entries(outputs).map(([key, value]) => `${key}=${value}\n`).join('')),
  });
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    console.error(error.stack ?? error.message);
    process.exitCode = 1;
  });
}
