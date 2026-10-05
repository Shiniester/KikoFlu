"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { test } = require("node:test");
const release = require("./commit-release.cjs");

const gitContext = ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"];

function cleanEnv(extra = {}) {
  const env = { ...process.env, ...extra };
  for (const key of gitContext) delete env[key];
  return env;
}

function git(root, args, options = {}) {
  const result = spawnSync("git", ["-C", root, ...args], {
    cwd: root,
    env: cleanEnv(options.env),
    input: options.input,
    encoding: "utf8",
    windowsHide: true,
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, (result.stderr || "").trim());
  return (result.stdout || "").trim();
}

async function until(check, description) {
  const deadline = Date.now() + 7000;
  while (!check() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.ok(check(), `timed out waiting for ${description}`);
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
}

function commitFile(root, name, content, message) {
  fs.writeFileSync(path.join(root, name), content);
  git(root, ["add", "--", name]);
  git(root, ["commit", "-m", message]);
  return git(root, ["rev-parse", "HEAD"]);
}

test("queues exact commits, gates turn commits, pushes promptly, and serializes releases", async (t) => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "kikoflu-commit-release-"));
  t.after(() => {
    const target = path.resolve(base);
    const tempRoot = path.resolve(os.tmpdir()) + path.sep;
    if (!target.startsWith(tempRoot) || !path.basename(target).startsWith("kikoflu-commit-release-")) {
      throw new Error("unexpected test fixture path");
    }
    fs.rmSync(target, { recursive: true, force: true });
  });

  const repo = path.join(base, "repo");
  const bare = path.join(base, "origin.git");
  const emptyHooks = path.join(base, "empty-hooks");
  fs.mkdirSync(repo);
  fs.mkdirSync(emptyHooks);
  git(base, ["init", "--bare", bare]);
  git(repo, ["init", "--initial-branch=main"]);
  git(repo, ["config", "user.name", "Commit Release Test"]);
  git(repo, ["config", "user.email", "commit-release@example.invalid"]);
  git(repo, ["config", "commit.gpgSign", "false"]);
  git(repo, ["config", "core.hooksPath", emptyHooks]);
  commitFile(repo, "base.txt", "base\n", "fixture base");
  git(repo, ["remote", "add", "origin", bare]);
  git(repo, ["push", "-u", "origin", "main"]);
  git(repo, ["tag", "v1.0.0"]);
  git(repo, ["push", "origin", "refs/tags/v1.0.0"]);
  git(repo, ["switch", "-c", "local-main-target"]);
  git(repo, ["branch", "--set-upstream-to=origin/main", "local-main-target"]);

  let workerStarts = 0;
  const resolveRepo = (root, branch, env) => ({
    ...release.resolveRoute(root, branch, env),
    githubHost: "github.com",
    githubRepo: "test/KikoFlu",
  });
  const capture = (temporaryIndex = "") => release.captureCommit(repo, {
    GIT_INDEX_FILE: temporaryIndex,
  }, {
    resolveRoute: resolveRepo,
    startWorker: () => { workerStarts++; },
  });

  const sha1 = commitFile(repo, "one.txt", "first\n", "first change");
  const first = capture("C:\\temp\\turn-commit-first.index");
  assert.equal(first.head, sha1);
  assert.equal(first.localBranch, "local-main-target");
  assert.equal(first.remoteBranch, "main");
  assert.equal(first.workflow, "build.yml");
  assert.equal(first.turnCommit, true);
  const request = JSON.parse(fs.readFileSync(first.requestPath, "utf8"));
  assert.deepEqual(request, { head: sha1, branch: "refs/heads/local-main-target" });
  assert.equal(release.validAccepted(first), false);
  fs.writeFileSync(first.requestPath.replace(/\.request$/, ".accepted"), JSON.stringify({ head: "f".repeat(40), branch: first.branch }));
  assert.equal(release.validAccepted(first), false);

  const sha2 = commitFile(repo, "two.txt", "second\n", "second change");
  const second = capture();
  assert.equal(second.head, sha2);
  assert.equal(second.turnCommit, false);
  assert.equal(workerStarts, 2);
  fs.writeFileSync(first.requestPath.replace(/\.request$/, ".accepted"), JSON.stringify(request));
  assert.equal(release.validAccepted(first), true);

  const plannerStarted = deferred();
  const continuePlanner = deferred();
  const dispatches = [];
  const runs = new Map();
  const releases = [{ tag_name: "v1.0.0", draft: false, prerelease: false, published_at: "2026-01-01T00:00:00Z" }];
  const plannedBases = [];
  const services = {
    workerPollMs: 5,
    pollMs: 10,
    workflowPollMs: 1,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, Math.min(ms, 5))),
    plan: async (job, inventory) => {
      plannedBases.push({ head: job.head, baseline: inventory.stable.tag_name });
      if (job.head === sha1) {
        plannerStarted.resolve();
        await continuePlanner.promise;
      }
      return { publish: true, bump: "patch", release_notes: `Release ${job.head}`, reason: "localized compatible changes" };
    },
    gh: async (job, args, input) => {
      assert.ok(args.includes(`X-GitHub-Api-Version:${"2026-03-10"}`));
      const endpoint = args[args.length - 1];
      if (endpoint.includes("/releases?")) return { status: 0, stdout: JSON.stringify([releases]) };
      if (endpoint.endsWith("/dispatches")) {
        const body = JSON.parse(input);
        const id = dispatches.length + 1;
        dispatches.push({ job, body, id });
        runs.set(String(id), { dispatch: dispatches[dispatches.length - 1], polls: 0 });
        return { status: 0, stdout: JSON.stringify({ workflow_run_id: id, html_url: `https://example.invalid/actions/runs/${id}` }) };
      }
      const runId = endpoint.split("/").pop();
      const run = runs.get(runId);
      assert.ok(run, `unexpected workflow run ${runId}`);
      run.polls++;
      if (run.polls === 1) return { status: 0, stdout: JSON.stringify({ status: "in_progress", conclusion: null }) };
      const inputVersion = run.dispatch.body.inputs.version;
      const tag = `v${inputVersion}`;
      const target = run.dispatch.body.inputs.commit_sha;
      if (!releases.some((item) => item.tag_name === tag)) {
        git(repo, ["tag", tag, target]);
        git(repo, ["push", "origin", `refs/tags/${tag}:refs/tags/${tag}`]);
        releases.push({ tag_name: tag, draft: false, prerelease: false, published_at: new Date(Date.now() + idSort(runId)).toISOString() });
      }
      return { status: 0, stdout: JSON.stringify({ status: "completed", conclusion: "success" }) };
    },
  };

  const commonDir = first.commonDir;
  const worker = release.runWorker(commonDir, services);
  await until(() => git(bare, ["rev-parse", "refs/heads/main"]) === sha2, "newer queued SHA push");
  assert.equal(dispatches.length, 0, "turn commit must wait for the index-install ACK");

  fs.writeFileSync(path.join(first.gitDir, DATA_DIR + "-unused"), "");
  fs.writeFileSync(path.join(repo, "three.txt"), "third\n");
  const sha3 = (() => {
    git(repo, ["add", "--", "three.txt"]);
    git(repo, ["commit", "-m", "third change"]);
    return git(repo, ["rev-parse", "HEAD"]);
  })();
  const third = capture();
  assert.equal(third.head, sha3);
  await until(() => git(bare, ["rev-parse", "refs/heads/main"]) === sha3, "push during release planning");
  await plannerStarted.promise;
  assert.equal(dispatches.length, 0, "the first planner is held before dispatch");
  continuePlanner.resolve();
  await worker;

  assert.deepEqual(dispatches.map((item) => item.body), [
    { ref: "main", inputs: { version: "1.0.1", release_notes: `Release ${sha1}`, commit_sha: sha1 } },
    { ref: "main", inputs: { version: "1.0.2", release_notes: `Release ${sha2}`, commit_sha: sha2 } },
    { ref: "main", inputs: { version: "1.0.3", release_notes: `Release ${sha3}`, commit_sha: sha3 } },
  ]);
  assert.deepEqual(plannedBases.map((item) => item.baseline), ["v1.0.0", "v1.0.1", "v1.0.2"]);
  assert.equal(git(bare, ["rev-parse", "refs/heads/main"]), sha3);

  git(repo, ["switch", "-c", "local-beta-target"]);
  git(repo, ["config", "branch.local-beta-target.remote", "origin"]);
  git(repo, ["config", "branch.local-beta-target.merge", "refs/heads/feature/beta"]);
  const betaSha = commitFile(repo, "beta.txt", "beta\n", "beta change");
  const beta = capture();
  assert.equal(beta.head, betaSha);
  assert.equal(beta.remoteBranch, "feature/beta");
  assert.equal(beta.workflow, "build_android_beta.yml");
});

function idSort(id) {
  return Number(id) * 1000;
}
