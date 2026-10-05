#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { randomUUID } = require("node:crypto");

const PROJECT_ROOT = path.resolve(__dirname, "..");
const HOOKS_DIR = path.join(PROJECT_ROOT, ".githooks");
const DATA_DIR = "kikoflu-auto-release";
const API_VERSION = "2026-03-10";
const ACK_WAIT_MS = 2 * 60 * 1000;
const INDEX_WAIT_MS = 2 * 60 * 1000;
const TURN_INDEX = /^turn-commit-.*\.index$/;
const RELEASE_POLICY_PATH = path.join(PROJECT_ROOT, ".codex", "skills", "release-automation", "SKILL.md");
const GIT_CONTEXT_ENV = [
  "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "GIT_PREFIX",
  "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_QUARANTINE_PATH",
  "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM",
];

function gitEnv(source = process.env) {
  const env = { ...source };
  for (const key of GIT_CONTEXT_ENV) delete env[key];
  return env;
}

function resultText(result) {
  return (result.stderr || result.stdout || "").trim().slice(0, 1000);
}

function commandSync(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env || gitEnv(),
    input: options.input,
    encoding: "utf8",
    windowsHide: true,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0 && !options.allowFailure) {
    throw new Error(`${command} ${args[0] || ""}: ${resultText(result) || `exit ${result.status}`}`);
  }
  return { status: result.status, stdout: result.stdout || "", stderr: result.stderr || "" };
}

function gitSync(root, args, options = {}) {
  return commandSync("git", ["-C", root, ...args], { ...options, env: gitEnv(options.env) });
}

function commandAsync(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env || gitEnv(),
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const out = [];
    const err = [];
    child.stdout.on("data", (chunk) => out.push(chunk));
    child.stderr.on("data", (chunk) => err.push(chunk));
    child.on("error", reject);
    child.on("close", (status) => {
      const result = {
        status,
        stdout: Buffer.concat(out).toString("utf8"),
        stderr: Buffer.concat(err).toString("utf8"),
      };
      if (status !== 0 && !options.allowFailure) {
        reject(new Error(`${command} ${args[0] || ""}: ${resultText(result) || `exit ${status}`}`));
      } else resolve(result);
    });
    if (options.input === undefined) child.stdin.end();
    else child.stdin.end(options.input);
  });
}

function gitValue(root, args, options = {}) {
  return gitSync(root, args, options).stdout.trim();
}

function repoPaths(cwd, env = process.env) {
  const clean = gitEnv(env);
  const rootResult = gitSync(cwd, ["rev-parse", "--show-toplevel"], { env: clean, allowFailure: true });
  if (rootResult.status !== 0) return null;
  const root = rootResult.stdout.trim();
  const gitDir = path.resolve(root, gitValue(root, ["rev-parse", "--absolute-git-dir"], { env: clean }));
  const commonDir = path.resolve(root, gitValue(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"], { env: clean }));
  return { root, gitDir, commonDir };
}

function optionalGitValue(root, args, env = process.env) {
  const result = gitSync(root, args, { env: gitEnv(env), allowFailure: true });
  return result.status === 0 ? result.stdout.trim() : null;
}

function remoteIdentity(remoteUrl) {
  let host;
  let repoPath;
  if (/^[^/]+@[^:]+:/.test(remoteUrl)) {
    const match = remoteUrl.match(/^[^@]+@([^:]+):(.+)$/);
    if (!match) return null;
    host = match[1];
    repoPath = match[2];
  } else {
    let parsed;
    try {
      parsed = new URL(remoteUrl);
    } catch {
      return null;
    }
    host = parsed.hostname;
    repoPath = parsed.pathname.replace(/^\//, "");
  }
  repoPath = repoPath.replace(/\.git$/i, "").replace(/\/$/, "");
  const parts = repoPath.split("/").filter(Boolean);
  if (!host || parts.length !== 2) return null;
  return { host, repo: `${parts[0]}/${parts[1]}` };
}

function resolveRoute(root, branchRef, env = process.env) {
  const localBranch = branchRef.slice("refs/heads/".length);
  const configuredRemote = optionalGitValue(root, ["config", "--get", `branch.${localBranch}.remote`], env);
  const configuredMerge = optionalGitValue(root, ["config", "--get", `branch.${localBranch}.merge`], env);
  const hasUpstream = Boolean(configuredRemote && configuredMerge && configuredMerge.startsWith("refs/heads/"));
  const remote = hasUpstream ? configuredRemote : "origin";
  const remoteBranch = hasUpstream ? configuredMerge.slice("refs/heads/".length) : localBranch;
  if (remote === ".") throw new Error("local-only upstreams cannot be pushed by commit-release");
  const remoteUrl = optionalGitValue(root, ["config", "--get", `remote.${remote}.url`], env);
  if (!remoteUrl) throw new Error(`remote ${remote} has no configured URL`);
  const identity = remoteIdentity(remoteUrl);
  if (!identity) throw new Error(`could not resolve a GitHub repository from remote ${remote}`);
  return {
    localBranch,
    remote,
    remoteBranch,
    remoteUrl,
    githubHost: identity.host,
    githubRepo: identity.repo,
    setUpstream: !hasUpstream,
    workflow: remoteBranch === "main" ? "build.yml" : "build_android_beta.yml",
  };
}

function queuePaths(commonDir) {
  const base = path.join(commonDir, DATA_DIR);
  return { base, queue: path.join(base, "queue"), lock: path.join(base, "worker.lock"), log: path.join(base, "worker.log") };
}

function logAt(commonDir, text) {
  try {
    const paths = queuePaths(commonDir);
    fs.mkdirSync(paths.base, { recursive: true });
    fs.appendFileSync(paths.log, `${new Date().toISOString()} ${String(text).replace(/[\r\n]+/g, " ").slice(0, 1400)}\n`, "utf8");
  } catch {}
}

function atomicJson(file, value) {
  const temp = `${file}.${process.pid}.${randomUUID()}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2) + "\n", "utf8");
  fs.renameSync(temp, file);
}

function writeRequest(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  try {
    const fd = fs.openSync(file, "wx");
    try { fs.writeFileSync(fd, JSON.stringify(value) + "\n", "utf8"); }
    finally { fs.closeSync(fd); }
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
    const prior = JSON.parse(fs.readFileSync(file, "utf8"));
    if (prior.head !== value.head || prior.branch !== value.branch) throw new Error(`conflicting finalize request ${file}`);
  }
}

function readJob(file) {
  try {
    const job = JSON.parse(fs.readFileSync(file, "utf8"));
    return job && job.schemaVersion === 1 && job.file === file ? job : null;
  } catch {
    return null;
  }
}

function readJobs(commonDir) {
  const paths = queuePaths(commonDir);
  if (!fs.existsSync(paths.queue)) return [];
  const jobs = [];
  for (const name of fs.readdirSync(paths.queue)) {
    if (!name.endsWith(".json")) continue;
    const job = readJob(path.join(paths.queue, name));
    if (job) jobs.push(job);
  }
  return jobs.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));
}

function enqueue(job) {
  const paths = queuePaths(job.commonDir);
  fs.mkdirSync(paths.queue, { recursive: true });
  const existing = readJobs(job.commonDir).find((item) => item.head === job.head && item.branch === job.branch && item.remote === job.remote && item.remoteBranch === job.remoteBranch);
  if (existing) return existing;
  job.id = randomUUID();
  job.createdAt = Date.now();
  job.file = path.join(paths.queue, `${job.id}.json`);
  job.pushState = "queued";
  job.pushError = "";
  job.releaseState = "queued";
  job.releaseError = "";
  job.runId = null;
  job.runUrl = null;
  job.finalizeDeadline = job.turnCommit ? Date.now() + ACK_WAIT_MS : null;
  atomicJson(job.file, job);
  return job;
}

function startWorker(commonDir, cwd = PROJECT_ROOT) {
  const env = gitEnv();
  const child = spawn(process.execPath, [__filename, "worker", commonDir], {
    cwd,
    env,
    detached: true,
    stdio: "ignore",
    windowsHide: true,
  });
  child.unref();
}

function captureCommit(cwd, env = process.env, dependencies = {}) {
  const temporaryIndex = env.GIT_INDEX_FILE || "";
  const paths = repoPaths(cwd, env);
  if (!paths) return { skipped: "not a Git repository" };
  const branch = optionalGitValue(paths.root, ["symbolic-ref", "-q", "HEAD"], env);
  if (!branch || !branch.startsWith("refs/heads/")) {
    logAt(paths.commonDir, `Skipped detached commit in ${paths.root}`);
    return { skipped: "detached HEAD" };
  }
  const head = gitValue(paths.root, ["rev-parse", "--verify", "HEAD"], { env: gitEnv(env) });
  try {
    const route = (dependencies.resolveRoute || resolveRoute)(paths.root, branch, env);
    const turnCommit = TURN_INDEX.test(path.basename(temporaryIndex));
    const requestPath = turnCommit ? path.join(paths.gitDir, DATA_DIR, "finalize", `${head}.request`) : null;
    if (requestPath) writeRequest(requestPath, { head, branch });
    const job = enqueue({
      schemaVersion: 1,
      releaseVersion: null,
      root: paths.root,
      gitDir: paths.gitDir,
      commonDir: paths.commonDir,
      head,
      branch,
      ...route,
      turnCommit,
      requestPath,
    });
    logAt(paths.commonDir, `Queued ${job.head} for ${job.remote}:${job.remoteBranch} (${job.workflow})`);
    (dependencies.startWorker || startWorker)(paths.commonDir, paths.root);
    return job;
  } catch (error) {
    logAt(paths.commonDir, `Post-commit enqueue failed for ${head}: ${error.message}`);
    return { error: error.message };
  }
}

function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; }
  catch (error) { return error.code === "EPERM"; }
}

function acquireWorkerLock(file) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = fs.openSync(file, "wx");
      fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, startedAt: Date.now() }) + "\n");
      fs.closeSync(fd);
      return true;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      let lock;
      try { lock = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
      if (!lock || isPidAlive(Number(lock.pid))) return false;
      try { fs.unlinkSync(file); } catch (unlinkError) { if (unlinkError.code !== "ENOENT") return false; }
    }
  }
  return false;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function gitPath(root, name) {
  return path.resolve(root, gitValue(root, ["rev-parse", "--git-path", name]));
}

function validAccepted(job) {
  if (!job.turnCommit || !job.requestPath) return true;
  try {
    const request = JSON.parse(fs.readFileSync(job.requestPath, "utf8"));
    const accepted = JSON.parse(fs.readFileSync(job.requestPath.replace(/\.request$/, ".accepted"), "utf8"));
    return request.head === job.head && request.branch === job.branch &&
      accepted.head === job.head && accepted.branch === job.branch;
  } catch {
    return false;
  }
}

async function waitForCommitReady(job, services) {
  const now = services.now || Date.now;
  const wait = services.sleep || sleep;
  if (job.turnCommit) {
    while (now() < job.finalizeDeadline) {
      if (validAccepted(job)) break;
      await wait(services.pollMs || 500);
    }
    if (!validAccepted(job)) return { ready: false, error: "turn-commit index installation was not accepted within two minutes" };
  }
  const indexPath = gitPath(job.root, "index");
  const deadline = now() + INDEX_WAIT_MS;
  while (fs.existsSync(indexPath + ".lock") && now() < deadline) await wait(services.pollMs || 500);
  if (fs.existsSync(indexPath + ".lock")) return { ready: false, error: "Git index.lock did not clear within two minutes" };
  const ancestor = gitSync(job.root, ["merge-base", "--is-ancestor", job.head, job.branch], { allowFailure: true });
  if (ancestor.status !== 0) return { ready: false, error: "captured commit is no longer reachable from its captured branch" };
  return { ready: true };
}

async function gitAsync(root, args, options = {}) {
  return commandAsync("git", ["-C", root, ...args], { ...options, env: gitEnv(options.env) });
}

async function pushCommit(job) {
  const refspec = `${job.head}:refs/heads/${job.remoteBranch}`;
  const pushed = await gitAsync(job.root, ["push", "--porcelain", job.remote, refspec], { allowFailure: true });
  if (pushed.status === 0) return { accepted: true, output: resultText(pushed) };

  const fetchRef = `refs/kikoflu-auto-release/fetch/${randomUUID()}`;
  const fetched = await gitAsync(job.root, [
    "fetch", "--no-tags", job.remote,
    `refs/heads/${job.remoteBranch}:${fetchRef}`,
  ], { allowFailure: true });
  if (fetched.status === 0) {
    const ancestor = await gitAsync(job.root, ["merge-base", "--is-ancestor", job.head, fetchRef], { allowFailure: true });
    await gitAsync(job.root, ["update-ref", "-d", fetchRef], { allowFailure: true });
    if (ancestor.status === 0) return { accepted: true, alreadyPushed: true };
  }
  return { accepted: false, error: resultText(pushed) || "Git push failed" };
}

async function establishUpstream(job) {
  if (!job.setUpstream) return;
  const currentRemote = optionalGitValue(job.root, ["config", "--get", `branch.${job.localBranch}.remote`]);
  const currentMerge = optionalGitValue(job.root, ["config", "--get", `branch.${job.localBranch}.merge`]);
  if (currentRemote || currentMerge) return;
  await gitAsync(job.root, ["config", `branch.${job.localBranch}.remote`, job.remote]);
  await gitAsync(job.root, ["config", `branch.${job.localBranch}.merge`, `refs/heads/${job.remoteBranch}`]);
}

async function pushJob(job, commonDir, services) {
  const ready = await waitForCommitReady(job, services);
  if (!ready.ready) return { state: "blocked", error: ready.error };
  const result = await pushCommit(job);
  if (!result.accepted) return { state: "failed", error: result.error };
  await establishUpstream(job);
  logAt(commonDir, `Pushed ${job.head} to ${job.remote}:${job.remoteBranch}${result.alreadyPushed ? " (already contained)" : ""}`);
  return { state: "pushed", error: "" };
}

function parseJsonOutput(text, description) {
  try { return JSON.parse(text); }
  catch (error) { throw new Error(`${description} returned invalid JSON: ${error.message}`); }
}

async function ghCall(job, args, input, services) {
  if (services.gh) return services.gh(job, args, input);
  const env = gitEnv();
  if (job.githubHost && job.githubHost !== "github.com") env.GH_HOST = job.githubHost;
  return commandAsync("gh", args, { cwd: job.root, env, input });
}

async function ghApi(job, endpoint, options = {}, services = {}) {
  const args = ["api", "-H", `X-GitHub-Api-Version:${API_VERSION}`];
  if (options.paginate) args.push("--paginate", "--slurp");
  if (options.method) args.push("--method", options.method);
  if (options.input !== undefined) args.push("--input", "-");
  args.push(endpoint);
  const result = await ghCall(job, args, options.input === undefined ? undefined : JSON.stringify(options.input), services);
  if (typeof result === "string") return result;
  if (!result || result.status !== 0) throw new Error(`gh api ${endpoint}: ${resultText(result || {}) || "failed"}`);
  return result.stdout;
}

function releaseArray(parsed) {
  if (!Array.isArray(parsed)) return [];
  return parsed.flatMap((page) => Array.isArray(page) ? page : [page]);
}

function parseStableVersion(tag) {
  const match = String(tag || "").match(/^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/);
  return match ? { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]) } : null;
}

function formatVersion(version) {
  return `${version.major}.${version.minor}.${version.patch}`;
}

async function releaseInventory(job, services) {
  const endpoint = `repos/${job.githubRepo}/releases?per_page=100`;
  const releaseText = await ghApi(job, endpoint, { paginate: true }, services);
  const releases = releaseArray(parseJsonOutput(releaseText, "GitHub releases"));
  const tagsOutput = await gitAsync(job.root, ["ls-remote", "--refs", job.remote, "refs/tags/*"]);
  const tagSet = new Set(tagsOutput.stdout.split(/\r?\n/).filter(Boolean).map((line) => line.split("\t")[1]).filter(Boolean).map((ref) => ref.slice("refs/tags/".length)));
  for (const release of releases) if (release.tag_name) tagSet.add(release.tag_name);
  const stable = releases
    .filter((release) => !release.draft && !release.prerelease && parseStableVersion(release.tag_name))
    .sort((a, b) => Date.parse(b.published_at || b.created_at || 0) - Date.parse(a.published_at || a.created_at || 0));
  if (!stable.length) throw new Error("no published stable release is available as a version baseline");
  const release = stable[0];
  const version = parseStableVersion(release.tag_name);
  if (!version) throw new Error(`stable release ${release.tag_name} has an invalid version tag`);
  const hiddenRef = `refs/kikoflu-auto-release/tags/${formatVersion(version)}`;
  const tagRef = `refs/tags/${release.tag_name}`;
  const fetched = await gitAsync(job.root, ["fetch", "--no-tags", job.remote, `${tagRef}:${hiddenRef}`], { allowFailure: true });
  if (fetched.status !== 0) throw new Error(`could not fetch stable baseline tag ${release.tag_name}: ${resultText(fetched)}`);
  const commit = (await gitAsync(job.root, ["rev-parse", "--verify", `${hiddenRef}^{commit}`])).stdout.trim();
  return { releases, tags: tagSet, stable: release, version, commit };
}

function selectVersion(job, inventory, bump) {
  const base = inventory.version;
  if (job.workflow === "build.yml") {
    const version = bump === "major"
      ? { major: base.major + 1, minor: 0, patch: 0 }
      : bump === "minor"
        ? { major: base.major, minor: base.minor + 1, patch: 0 }
        : { major: base.major, minor: base.minor, patch: base.patch + 1 };
    return formatVersion(version);
  }
  const next = { major: base.major, minor: base.minor, patch: base.patch + 1 };
  const prefix = `${next.major}.${next.minor}.${next.patch}-beta.`;
  let highest = 0;
  const existing = new Set(inventory.tags);
  for (const release of inventory.releases) if (release.tag_name) existing.add(release.tag_name);
  for (const tag of existing) {
    const match = String(tag).replace(/^v/, "").match(/^(.+)-beta\.(\d+)$/);
    if (match && match[1] === formatVersion(next)) highest = Math.max(highest, Number(match[2]));
  }
  return `${prefix}${highest + 1}`;
}

function availableVersion(version, inventory) {
  const tag = `v${version}`;
  return !inventory.tags.has(tag) && !inventory.tags.has(version) &&
    !inventory.releases.some((release) => release.tag_name === tag || release.tag_name === version);
}

function plannerPrompt(job, inventory) {
  const policy = fs.readFileSync(RELEASE_POLICY_PATH, "utf8");
  return [
    "Review this exact KikoFlu commit for a background release decision. The current repository policy follows; apply its channel and semantic version guidance to this decision:",
    policy,
    "This automation is authorized to push commits and queue releases. Your role is only to decide whether this exact commit warrants a release; do not commit, push, dispatch workflows, edit files, or start other agents.",
    "Use Git commands against the supplied exact target SHA, including `git diff <baseline> <target>` and `git show <target>:<path>` as needed. Do not inspect source from the current working-tree copy because it may differ from the target commit.",
    "If there are no releasable user-visible changes, return publish=false and bump=none.",
    `Channel: ${job.workflow === "build.yml" ? "stable all-platform" : "Android Beta"}`,
    `Remote branch: ${job.remoteBranch}`,
    `Stable baseline release: ${inventory.stable.tag_name}`,
    `Baseline commit: ${inventory.commit}`,
    `Exact target SHA: ${job.head}`,
    "Return only the schema response. release_notes should be concise Markdown describing user-visible changes; reason should state the impact-based bump decision.",
  ].join("\n");
}

function findCodex() {
  const names = process.platform === "win32" ? ["codex.exe"] : ["codex"];
  for (const folder of (process.env.PATH || "").split(path.delimiter)) {
    for (const name of names) {
      const candidate = path.join(folder, name);
      if (fs.existsSync(candidate)) return candidate;
    }
  }
  if (process.platform === "win32") {
    const local = process.env.LOCALAPPDATA || (process.env.USERPROFILE && path.join(process.env.USERPROFILE, "AppData", "Local"));
    const binRoot = local && path.join(local, "OpenAI", "Codex", "bin");
    if (binRoot && fs.existsSync(binRoot)) {
      const candidates = fs.readdirSync(binRoot, { withFileTypes: true })
        .filter((item) => item.isDirectory())
        .map((item) => path.join(binRoot, item.name, "codex.exe"))
        .filter((file) => fs.existsSync(file))
        .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
      if (candidates.length) return candidates[0];
    }
  }
  return process.platform === "win32" ? "codex.exe" : "codex";
}

async function runPlanner(job, inventory, services) {
  if (services.plan) return services.plan(job, inventory);
  const output = path.join(os.tmpdir(), `kikoflu-release-plan-${randomUUID()}.json`);
  const schema = path.join(PROJECT_ROOT, "scripts", "release-plan.schema.json");
  try {
    const result = await commandAsync(findCodex(), [
      "exec", "-C", job.root,
      "--sandbox", "read-only", "--ephemeral", "--disable", "hooks",
      "--output-schema", schema, "--output-last-message", output, "-",
    ], { cwd: job.root, env: gitEnv(), input: plannerPrompt(job, inventory) });
    if (result.status !== 0) throw new Error(`Codex release planner failed: ${resultText(result)}`);
    return parseJsonOutput(fs.readFileSync(output, "utf8"), "Codex release planner");
  } finally {
    try { fs.unlinkSync(output); } catch {}
  }
}

function validatePlan(plan) {
  if (!plan || typeof plan.publish !== "boolean" ||
      !["major", "minor", "patch", "none"].includes(plan.bump) ||
      typeof plan.release_notes !== "string" || typeof plan.reason !== "string") {
    throw new Error("Codex release planner output did not match the release schema");
  }
  if (plan.publish && plan.bump === "none") throw new Error("planner requested publish=true with bump=none");
  if (!plan.publish && plan.bump !== "none") throw new Error("planner requested publish=false with a version bump");
  return plan;
}

async function waitForWorkflow(job, services) {
  const wait = services.sleep || sleep;
  for (;;) {
    try {
      const endpoint = `repos/${job.githubRepo}/actions/runs/${job.runId}`;
      const result = parseJsonOutput(await ghApi(job, endpoint, {}, services), "GitHub workflow run");
      if (result.status === "completed") {
        job.runConclusion = result.conclusion || "unknown";
        job.releaseState = job.runConclusion === "success" ? "done" : "failed";
        job.releaseError = job.releaseState === "failed" ? `workflow concluded ${job.runConclusion}` : "";
        atomicJson(job.file, job);
        logAt(job.commonDir, `Workflow ${job.runId} finished (${job.runConclusion}) for ${job.head}`);
        return;
      }
    } catch (error) {
      logAt(job.commonDir, `Workflow status check failed for ${job.runId}; will retry: ${error.message}`);
    }
    await wait(services.workflowPollMs || 15000);
  }
}

async function dispatchWorkflow(job, version, notes, services) {
  const body = {
    ref: job.remoteBranch,
    inputs: { version, release_notes: notes, commit_sha: job.head },
  };
  const endpoint = `repos/${job.githubRepo}/actions/workflows/${job.workflow}/dispatches`;
  const text = await ghApi(job, endpoint, { method: "POST", input: body }, services);
  const response = parseJsonOutput(text, "GitHub workflow dispatch");
  if (!(Number.isInteger(response.workflow_run_id) || typeof response.workflow_run_id === "string") ||
      !(response.html_url || response.run_url)) throw new Error("GitHub accepted no usable workflow run details");
  job.runId = response.workflow_run_id;
  job.runUrl = response.html_url || response.run_url;
  job.releaseVersion = version;
  job.releaseState = "running";
  atomicJson(job.file, job);
  logAt(job.commonDir, `Dispatched ${job.workflow} ${version} for ${job.head}: ${job.runUrl}`);
}

async function releaseJob(job, services) {
  if (job.releaseState === "uncertain") return;
  if (job.releaseState === "running" && job.runId) return waitForWorkflow(job, services);
  if (job.releaseState === "dispatching") {
    job.releaseState = "uncertain";
    job.releaseError = "dispatch outcome was interrupted; inspect GitHub before retrying";
    atomicJson(job.file, job);
    logAt(job.commonDir, `${job.releaseError} (${job.head})`);
    return;
  }
  if (job.releaseState === "planning") job.releaseState = "queued";
  job.releaseState = "planning";
  atomicJson(job.file, job);

  const inventory = await releaseInventory(job, services);
  const ancestor = await gitAsync(job.root, ["merge-base", "--is-ancestor", inventory.commit, job.head], { allowFailure: true });
  if (ancestor.status !== 0 && job.workflow === "build.yml") {
    const alreadyReleased = await gitAsync(job.root, ["merge-base", "--is-ancestor", job.head, inventory.commit], { allowFailure: true });
    if (alreadyReleased.status === 0) {
      job.releaseState = "none";
      job.releaseError = `target is already included in stable baseline ${inventory.stable.tag_name}`;
      atomicJson(job.file, job);
      logAt(job.commonDir, `${job.head}: ${job.releaseError}`);
      return;
    }
    throw new Error(`stable baseline ${inventory.stable.tag_name} is not an ancestor of ${job.head}`);
  }
  const changed = await gitAsync(job.root, ["diff", "--quiet", inventory.commit, job.head], { allowFailure: true });
  if (changed.status === 0) {
    job.releaseState = "none";
    job.releaseError = "no changes since the latest stable release";
    atomicJson(job.file, job);
    logAt(job.commonDir, `${job.head}: ${job.releaseError}`);
    return;
  }
  const plan = validatePlan(await runPlanner(job, inventory, services));
  if (!plan.publish) {
    job.releaseState = "none";
    job.releaseError = plan.reason;
    atomicJson(job.file, job);
    logAt(job.commonDir, `${job.head}: no release (${plan.reason})`);
    return;
  }
  const version = selectVersion(job, inventory, plan.bump);
  if (!availableVersion(version, inventory)) throw new Error(`version tag/release v${version} already exists`);
  job.releaseState = "dispatching";
  job.releaseVersion = version;
  atomicJson(job.file, job);
  await dispatchWorkflow(job, version, plan.release_notes, services);
  await waitForWorkflow(job, services);
}

const TERMINAL_RELEASE = new Set(["none", "done", "failed", "blocked"]);

async function runWorker(commonDir, services = {}) {
  const paths = queuePaths(commonDir);
  if (!acquireWorkerLock(paths.lock)) return { alreadyRunning: true };
  const pushTasks = new Set();
  let releaseTask = null;
  const wait = services.sleep || sleep;
  try {
    for (;;) {
      const jobs = readJobs(commonDir);
      for (const job of jobs) {
        if ((job.pushState === "queued" || job.pushState === "waiting") && !pushTasks.has(job.id)) {
          job.pushState = "waiting";
          atomicJson(job.file, job);
          const task = pushJob(job, commonDir, services)
            .then((result) => {
              const latest = readJob(job.file) || job;
              latest.pushState = result.state;
              latest.pushError = result.error || "";
              if (result.state !== "pushed") {
                latest.releaseState = "blocked";
                latest.releaseError = "commit could not be pushed";
              }
              atomicJson(latest.file, latest);
              if (result.state !== "pushed") logAt(commonDir, `Push ${result.state} for ${job.head}: ${result.error}`);
            })
            .catch((error) => {
              const latest = readJob(job.file) || job;
              latest.pushState = "failed";
              latest.pushError = error.message;
              latest.releaseState = "blocked";
              latest.releaseError = "commit could not be pushed";
              atomicJson(latest.file, latest);
              logAt(commonDir, `Push failed for ${job.head}: ${error.message}`);
            })
            .finally(() => pushTasks.delete(job.id));
          pushTasks.add(job.id);
          void task;
        }
      }

      if (!releaseTask) {
        const first = jobs.find((job) => !TERMINAL_RELEASE.has(job.releaseState));
        if (first && first.releaseState === "uncertain") {
          // Keep later versions blocked until the ambiguous dispatch is inspected.
        } else if (first && first.pushState === "pushed") {
          releaseTask = releaseJob(first, services)
            .catch((error) => {
              const latest = readJob(first.file) || first;
              latest.releaseState = ["dispatching", "running", "uncertain"].includes(latest.releaseState) ? "uncertain" : "failed";
              latest.releaseError = error.message;
              atomicJson(latest.file, latest);
              logAt(commonDir, `${latest.releaseState === "uncertain" ? "Dispatch outcome uncertain" : "Release planning/dispatch failed"} for ${first.head}: ${error.message}`);
            })
            .finally(() => { releaseTask = null; });
        } else if (first && first.pushState === "failed") {
          first.releaseState = "blocked";
          first.releaseError = "commit could not be pushed";
          atomicJson(first.file, first);
        }
      }

      const latestJobs = readJobs(commonDir);
      const waitingPush = latestJobs.some((job) => job.pushState === "queued" || job.pushState === "waiting");
      const firstRelease = latestJobs.find((job) => !TERMINAL_RELEASE.has(job.releaseState));
      const waitingRelease = Boolean(firstRelease && firstRelease.pushState === "pushed" && firstRelease.releaseState !== "uncertain");
      if (!pushTasks.size && !releaseTask && !waitingPush && !waitingRelease) break;
      await wait(services.workerPollMs || 1000);
    }
  } finally {
    try { fs.unlinkSync(paths.lock); } catch (error) { if (error.code !== "ENOENT") logAt(commonDir, `Could not remove worker lock: ${error.message}`); }
  }
  const remaining = readJobs(commonDir);
  const firstPending = remaining.find((job) => !TERMINAL_RELEASE.has(job.releaseState));
  if (remaining.some((job) => job.pushState === "queued" || job.pushState === "waiting") ||
      (firstPending && firstPending.pushState === "pushed" && firstPending.releaseState !== "uncertain")) {
    (services.startWorker || startWorker)(commonDir, PROJECT_ROOT);
  }
  return { completed: true };
}

function installHook(cwd) {
  const paths = repoPaths(cwd);
  if (!paths) throw new Error("install must run inside a Git repository");
  const hookPath = path.resolve(HOOKS_DIR);
  const configured = optionalGitValue(paths.root, ["config", "--path", "--get", "core.hooksPath"]);
  if (configured && path.resolve(paths.root, configured) !== hookPath) {
    throw new Error(`core.hooksPath already points to ${configured}; refusing to replace it`);
  }
  if (!configured) {
    const defaultHooks = gitPath(paths.root, "hooks");
    const active = fs.existsSync(defaultHooks) ? fs.readdirSync(defaultHooks).filter((name) => !name.endsWith(".sample")) : [];
    if (active.length) throw new Error(`existing Git hooks found in ${defaultHooks}; refusing to hide them`);
  }
  fs.chmodSync(path.join(hookPath, "post-commit"), 0o755);
  gitSync(paths.root, ["config", "--local", "core.hooksPath", hookPath]);
  return `Installed post-commit hook path: ${hookPath}`;
}

function status(cwd) {
  const paths = repoPaths(cwd);
  if (!paths) throw new Error("status must run inside a Git repository");
  const jobs = readJobs(paths.commonDir);
  if (!jobs.length) return "No queued commit-release jobs.";
  return jobs.map((job) => [
    job.head,
    `${job.remote}:${job.remoteBranch}`,
    `push=${job.pushState}`,
    `release=${job.releaseState}`,
    job.releaseVersion ? `version=${job.releaseVersion}` : "",
    job.runUrl || "",
    job.pushError || job.releaseError || "",
  ].filter(Boolean).join("  ")).join("\n");
}

async function main(args) {
  const command = args[0] || "hook";
  if (command === "hook") {
    captureCommit(process.cwd());
    return;
  }
  if (command === "worker") {
    const commonDir = args[1];
    if (!commonDir) throw new Error("worker requires a Git common directory");
    await runWorker(commonDir);
    return;
  }
  if (command === "install") {
    process.stdout.write(installHook(process.cwd()) + "\n");
    return;
  }
  if (command === "status") {
    process.stdout.write(status(process.cwd()) + "\n");
    return;
  }
  throw new Error("usage: commit-release.cjs [install|status|hook|worker <git-common-dir>]");
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    process.stderr.write(`commit-release: ${error.message}\n`);
    process.exitCode = 1;
  });
}

module.exports = {
  captureCommit,
  enqueue,
  installHook,
  readJobs,
  remoteIdentity,
  resolveRoute,
  runWorker,
  selectVersion,
  status,
  validAccepted,
};
