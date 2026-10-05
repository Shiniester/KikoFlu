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
  let worker;
  let acceptedFile;
  let acceptedRequest;
  let continuePlanner;
  t.after(async () => {
    continuePlanner?.resolve();
    if (acceptedFile && acceptedRequest) fs.writeFileSync(acceptedFile, JSON.stringify(acceptedRequest));
    if (worker) await worker;
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
  const resolveRepo = (root, branch) => {
    const localBranch = branch.slice("refs/heads/".length);
    const remote = git(root, ["config", "--get", `branch.${localBranch}.remote`]);
    const merge = git(root, ["config", "--get", `branch.${localBranch}.merge`]);
    const remoteBranch = merge.slice("refs/heads/".length);
    return {
      localBranch,
      remote,
      remoteBranch,
      remoteUrl: git(root, ["config", "--get", `remote.${remote}.url`]),
      githubHost: "github.com",
      githubRepo: "test/KikoFlu",
      setUpstream: false,
      workflow: remoteBranch === "main" ? "build.yml" : "build_android_beta.yml",
    };
  };
  const capture = (temporaryIndex = "") => release.captureCommit(repo, {
    GIT_INDEX_FILE: temporaryIndex,
  }, {
    resolveRoute: resolveRepo,
    startWorker: () => { workerStarts++; },
  });

  const sha1 = commitFile(repo, "one.txt", "first\n", "first change");
  const first = capture("C:\\temp\\turn-commit-first.index");
  assert.equal(first.head, sha1, JSON.stringify(first));
  assert.equal(first.localBranch, "local-main-target");
  assert.equal(first.remoteBranch, "main");
  assert.equal(first.workflow, "build.yml");
  assert.equal(first.turnCommit, true);
  const request = JSON.parse(fs.readFileSync(first.requestPath, "utf8"));
  acceptedFile = first.requestPath.replace(/\.request$/, ".accepted");
  acceptedRequest = request;
  assert.deepEqual(request, { head: sha1, branch: "refs/heads/local-main-target" });
  assert.equal(release.validAccepted(first), false);
  fs.writeFileSync(first.requestPath.replace(/\.request$/, ".accepted"), JSON.stringify({ head: "f".repeat(40), branch: first.branch }));
  assert.equal(release.validAccepted(first), false);

  continuePlanner = deferred();
  const dispatches = [];
  const runs = new Map();
  let monitorFailures = 0;
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
        await continuePlanner.promise;
      }
      return { publish: true, bump: "patch", release_notes: `Release ${job.head}`, reason: "localized compatible changes" };
    },
    gh: async (job, args, input) => {
      assert.ok(args.includes(`X-GitHub-Api-Version:${"2026-03-10"}`));
      const endpoint = args[args.length - 1];
      if (endpoint.includes("/releases?")) return { status: 0, stdout: JSON.stringify([releases]) };
      if (endpoint.endsWith("/dispatches")) {
        if (dispatches.length) assert.equal(runs.get(String(dispatches.at(-1).id)).finished, true, "wait for the previous workflow before dispatching another");
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
      if (runId === "1" && run.polls === 1) {
        monitorFailures++;
        throw new Error("temporary workflow status failure");
      }
      if (run.polls <= (runId === "1" ? 2 : 1)) return { status: 0, stdout: JSON.stringify({ status: "in_progress", conclusion: null }) };
      const inputVersion = run.dispatch.body.inputs.version;
      if (runId !== "2") {
        const tag = `v${inputVersion}`;
        const target = run.dispatch.body.inputs.commit_sha;
        if (!releases.some((item) => item.tag_name === tag)) {
          git(repo, ["tag", tag, target]);
          git(repo, ["push", "origin", `refs/tags/${tag}:refs/tags/${tag}`]);
          releases.push({ tag_name: tag, draft: false, prerelease: false, published_at: new Date(Date.now() + idSort(runId)).toISOString() });
        }
      }
      run.finished = true;
      return { status: 0, stdout: JSON.stringify({ status: "completed", conclusion: runId === "2" ? "failure" : "success" }) };
    },
  };

  const commonDir = first.commonDir;
  const inventoryForMajor = { version: { major: 4, minor: 8, patch: 1 }, tags: new Set(), releases: [] };
  assert.equal(release.selectVersion({ workflow: "build.yml" }, inventoryForMajor, "major"), "5.0.0");
  assert.equal(release.selectVersion({ workflow: "build.yml" }, inventoryForMajor, "minor"), "4.9.0");
  assert.equal(release.selectVersion({ workflow: "build.yml" }, inventoryForMajor, "patch"), "4.8.2");
  const originalRemoteHead = git(bare, ["rev-parse", "refs/heads/main"]);
  worker = release.runWorker(commonDir, services);
  await until(() => release.readJobs(commonDir).find((job) => job.head === sha1)?.pushState === "waiting", "turn commit ACK wait");
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(git(bare, ["rev-parse", "refs/heads/main"]), originalRemoteHead, "a turn commit must not push before its ACK");
  assert.equal(dispatches.length, 0, "turn commit must wait for the index-install ACK");
  assert.equal(release.validAccepted(first), false);
  fs.writeFileSync(first.requestPath.replace(/\.request$/, ".accepted"), JSON.stringify(request));
  assert.equal(release.validAccepted(first), true);
  await until(() => git(bare, ["rev-parse", "refs/heads/main"]) === sha1, "accepted turn SHA push");
  await until(() => plannedBases.some((item) => item.head === sha1), "first release planner");

  const sha2 = commitFile(repo, "two.txt", "second\n", "second change");
  const second = capture();
  assert.equal(second.head, sha2);
  assert.equal(second.turnCommit, false);
  assert.equal(workerStarts, 2);
  await until(() => git(bare, ["rev-parse", "refs/heads/main"]) === sha2, "newer queued SHA push while planning");

  fs.writeFileSync(path.join(repo, "three.txt"), "third\n");
  const sha3 = (() => {
    git(repo, ["add", "--", "three.txt"]);
    git(repo, ["commit", "-m", "third change"]);
    return git(repo, ["rev-parse", "HEAD"]);
  })();
  const third = capture();
  assert.equal(third.head, sha3);
  await until(() => git(bare, ["rev-parse", "refs/heads/main"]) === sha3, "push during release planning");
  assert.equal(dispatches.length, 0, "the first planner is held before dispatch");
  continuePlanner.resolve();
  await worker;

  assert.deepEqual(dispatches.map((item) => item.body), [
    { ref: "main", inputs: { version: "1.0.1", release_notes: `Release ${sha1}`, commit_sha: sha1 } },
    { ref: "main", inputs: { version: "1.0.2", release_notes: `Release ${sha2}`, commit_sha: sha2 } },
    { ref: "main", inputs: { version: "1.0.2", release_notes: `Release ${sha3}`, commit_sha: sha3 } },
  ]);
  assert.deepEqual(plannedBases.map((item) => item.baseline), ["v1.0.0", "v1.0.1", "v1.0.1"]);
  assert.equal(monitorFailures, 1, "temporary workflow status failures are retried before later releases");
  assert.equal(git(bare, ["rev-parse", "refs/heads/main"]), sha3);
  const mainJobs = release.readJobs(commonDir);
  const persistedDispatch = mainJobs.find((job) => job.head === sha1);
  assert.equal(persistedDispatch.schemaVersion, 1);
  assert.equal(persistedDispatch.releaseVersion, "1.0.1");
  assert.equal(persistedDispatch.releaseState, "done");
  const failedWorkflow = mainJobs.find((job) => job.head === sha2);
  assert.equal(failedWorkflow.releaseState, "failed");
  assert.equal(failedWorkflow.releaseError, "workflow concluded failure");
  assert.match(release.status(repo), /workflow concluded failure/);
  assert.match(release.status(repo), /version=1\.0\.2/);

  git(repo, ["switch", "-c", "local-beta-target", sha1]);
  git(repo, ["config", "branch.local-beta-target.remote", "origin"]);
  git(repo, ["config", "branch.local-beta-target.merge", "refs/heads/feature/beta"]);
  const betaSha = commitFile(repo, "beta.txt", "beta\n", "beta change");
  const beta = capture();
  assert.equal(beta.head, betaSha);
  assert.equal(beta.remoteBranch, "feature/beta");
  assert.equal(beta.workflow, "build_android_beta.yml");
  let betaPlanned = false;
  const betaWorker = release.runWorker(commonDir, {
    ...services,
    plan: async () => {
      betaPlanned = true;
      return { publish: false, bump: "none", release_notes: "", reason: "fixture inspected divergent Beta target" };
    },
  });
  await betaWorker;
  const betaJob = release.readJobs(commonDir).find((job) => job.head === betaSha);
  assert.equal(betaPlanned, true, "a feature commit may diverge from the latest stable baseline");
  assert.equal(betaJob.releaseState, "none");
  assert.equal(git(bare, ["rev-parse", "refs/heads/feature/beta"]), betaSha);

  git(repo, ["switch", "local-main-target"]);
  const failedSha = commitFile(repo, "planner-failure.txt", "failure path\n", "planner failure fixture");
  const failed = capture();
  let failureCalls = 0;
  await release.runWorker(commonDir, {
    ...services,
    plan: async () => {
      failureCalls++;
      return { publish: true, bump: "invalid", release_notes: "", reason: "invalid plan fixture" };
    },
  });
  const failedJob = release.readJobs(commonDir).find((job) => job.head === failedSha);
  assert.equal(failureCalls, 1);
  assert.equal(failedJob.releaseState, "failed");
  assert.equal(failedJob.schemaVersion, 1);
  assert.equal(failedJob.releaseVersion, null);
  assert.equal(dispatches.length, 3, "an invalid planner result must not dispatch a workflow");

  const ambiguousSha = commitFile(repo, "ambiguous.txt", "ambiguous dispatch\n", "ambiguous dispatch fixture");
  const ambiguous = capture();
  assert.equal(ambiguous.head, ambiguousSha);
  let ambiguousPosts = 0;
  let spawnedWorkers = 0;
  const ambiguousServices = {
    ...services,
    plan: async () => ({ publish: true, bump: "patch", release_notes: "ambiguous fixture", reason: "patch" }),
    gh: async (_job, args) => {
      const endpoint = args.at(-1);
      if (endpoint.includes("/releases?")) return { status: 0, stdout: JSON.stringify([releases]) };
      if (endpoint.endsWith("/dispatches")) {
        ambiguousPosts++;
        return { status: 0, stdout: JSON.stringify({ message: "accepted without run details" }) };
      }
      throw new Error(`unexpected GitHub call ${endpoint}`);
    },
    startWorker: () => { spawnedWorkers++; },
  };
  await release.runWorker(commonDir, ambiguousServices);
  const ambiguousJob = release.readJobs(commonDir).find((job) => job.head === ambiguousSha);
  assert.equal(ambiguousJob.releaseState, "uncertain");
  assert.equal(ambiguousJob.releaseVersion, "1.0.3");
  assert.equal(ambiguousPosts, 1);

  const laterSha = commitFile(repo, "after-ambiguous.txt", "later commit\n", "after ambiguous dispatch");
  const later = capture();
  await release.runWorker(commonDir, ambiguousServices);
  const laterJob = release.readJobs(commonDir).find((job) => job.head === laterSha);
  assert.equal(git(bare, ["rev-parse", "refs/heads/main"]), laterSha, "later commits still push while release planning is blocked");
  assert.equal(laterJob.pushState, "pushed");
  assert.equal(laterJob.releaseState, "queued", "an uncertain dispatch blocks later version selection");
  assert.equal(ambiguousPosts, 1, "a second worker must not repeat an ambiguous dispatch");
  assert.equal(spawnedWorkers, 0, "an uncertain head job must not start a polling loop");

  const beforeExpired = git(bare, ["rev-parse", "refs/heads/main"]);
  const expiredSha = commitFile(repo, "expired-turn.txt", "unaccepted turn\n", "expired turn fixture");
  const expired = capture("C:\\temp\\turn-commit-expired.index");
  assert.equal(release.validAccepted(expired), false);
  const expiredNow = Date.now() + 5 * 60 * 1000;
  await release.runWorker(commonDir, { ...services, now: () => expiredNow, startWorker: () => { spawnedWorkers++; } });
  const expiredJob = release.readJobs(commonDir).find((job) => job.head === expiredSha);
  assert.equal(expiredJob.pushState, "blocked");
  assert.equal(expiredJob.releaseState, "blocked");
  assert.equal(git(bare, ["rev-parse", "refs/heads/main"]), beforeExpired, "an expired unaccepted turn SHA stays unpushed");
  assert.equal(spawnedWorkers, 0);
});

test("native post-commit hook captures a commit without starting network work in the fixture", async (t) => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "kikoflu-native-hook-"));
  t.after(() => {
    const target = path.resolve(base);
    const tempRoot = path.resolve(os.tmpdir()) + path.sep;
    if (!target.startsWith(tempRoot) || !path.basename(target).startsWith("kikoflu-native-hook-")) {
      throw new Error("unexpected native-hook fixture path");
    }
    fs.rmSync(target, { recursive: true, force: true });
  });

  fs.mkdirSync(path.join(base, "repo"));
  const repo = path.join(base, "repo");
  git(repo, ["init", "--initial-branch=main"]);
  git(repo, ["config", "user.name", "Native Hook Test"]);
  git(repo, ["config", "user.email", "native-hook@example.invalid"]);
  git(repo, ["remote", "add", "origin", "git@github.com:test/fixture.git"]);
  commitFile(repo, "base.txt", "base\n", "hook fixture base");

  const commonDir = git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"]);
  const queueRoot = path.join(commonDir, "kikoflu-auto-release");
  fs.mkdirSync(queueRoot, { recursive: true });
  fs.writeFileSync(path.join(queueRoot, "worker.lock"), JSON.stringify({ pid: process.pid }));
  release.installHook(repo);

  fs.writeFileSync(path.join(repo, "hooked.txt"), "captured\n");
  git(repo, ["add", "--", "hooked.txt"]);
  git(repo, ["commit", "-m", "native hook commit"]);
  const head = git(repo, ["rev-parse", "HEAD"]);
  await new Promise((resolve) => setTimeout(resolve, 300));

  const jobs = release.readJobs(commonDir);
  assert.equal(jobs.length, 1);
  assert.equal(jobs[0].head, head);
  assert.equal(jobs[0].branch, "refs/heads/main");
  assert.equal(jobs[0].remoteBranch, "main", "a branch without an upstream defaults to origin and its own name");
  assert.equal(jobs[0].workflow, "build.yml");
  assert.equal(jobs[0].setUpstream, true);
  assert.equal(jobs[0].pushState, "queued");
  assert.equal(git(repo, ["config", "--local", "--get", "core.hooksPath"]), path.resolve(__dirname, "..", ".githooks"));
});

function idSort(id) {
  return Number(id) * 1000;
}
