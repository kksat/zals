// Keep release-please's version, PR, label, and tag mechanics upstream. Only the
// initial GitHub release body comes from the separately approved curated notes.
import { execFile } from 'node:child_process';
import { appendFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
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
    for (const candidate of candidates) await notesFor(candidate);
    return candidates;
  };
  github.createRelease = async function (release, options) {
    const notes = await notesFor(release);
    return createRelease.call(this, { ...release, notes }, options);
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

// GITHUB_TOKEN suppresses PR workflow events, so publish a commit status directly
// after upstream PR creation/update. List also finds unchanged PRs for reruns.
// This is not the pre-tag gate: missing notes are expected while drafting a PR.
export async function publishNotesStatuses({ github, validateHead = validateNotesRef,
  report = message => console.error(message), targetUrl }) {
  const { owner, repo, defaultBranch } = github.repository;
  const api = github.octokit;
  for await (const { data: pulls } of api.paginate.iterator('GET /repos/{owner}/{repo}/pulls',
    { owner, repo, state: 'open', base: defaultBranch, per_page: 100 })) {
    for (const listed of pulls) {
      if (!isReleasePullRequest(listed, github.repository)) continue;
      // Never assume the upstream PullRequest.sha means head SHA (it denotes the
      // merge commit). Fetch the exact current head from the REST PR object.
      const { data: pull } = await api.request('GET /repos/{owner}/{repo}/pulls/{pull_number}',
        { owner, repo, pull_number: listed.number });
      if (!isReleasePullRequest(pull, github.repository) || !/^[a-f0-9]{40}$/.test(pull.head.sha ?? '')) {
        throw new Error('Release PR identity changed while resolving its exact head');
      }
      const sha = pull.head.sha;
      const status = (state, description) => api.request('POST /repos/{owner}/{repo}/statuses/{sha}',
        { owner, repo, sha, state, description, context: NOTES_STATUS,
          ...(targetUrl ? { target_url: targetUrl } : {}) });
      await status('pending', 'Validating separately approved notes for this exact release PR head');
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
