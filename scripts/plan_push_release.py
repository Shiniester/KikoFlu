"""Plan a release for the exact pushed commit using its Conventional Commits."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
STABLE = re.compile(r"v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")
BUMP_LEVEL = {"none": 0, "patch": 1, "minor": 2, "major": 3}
COMMIT_SUBJECT = re.compile(
    r"(?P<type>[^\s():!]+)(?:\((?P<scope>[^()\r\n]+)\))?(?P<breaking>!)?: +(?P<description>\S.*)"
)
BREAKING_FOOTER = re.compile(r"(?P<token>BREAKING CHANGE|BREAKING-CHANGE):[ \t]*\S.*")
FOOTER_HEADER = re.compile(
    r"(?:BREAKING CHANGE|[A-Za-z0-9][A-Za-z0-9-]*)(?::[ \t]+|[ \t]+#)\S.*"
)
OUTPUT_KEYS = ("publish", "version", "release_notes", "commit_sha")


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True, encoding="utf-8")


def inventory(repo, resource):
    pages = json.loads(command("gh", "api", "--paginate", "--slurp",
                               f"repos/{repo}/{resource}?per_page=100"))
    return [item for page in pages for item in page]


def latest_stable(releases):
    stable = [r for r in releases if not r["draft"] and not r["prerelease"]]
    if not stable:
        raise ValueError("No published stable release; select a baseline manually.")
    release = max(stable, key=lambda r: r["published_at"])
    match = STABLE.fullmatch(release["tag_name"])
    if not match:
        raise ValueError("Latest stable release does not have a semantic version tag.")
    return release["tag_name"], tuple(map(int, match.groups()))


def next_version(base, branch, bump, existing):
    major, minor, patch = base
    if branch == "main":
        if bump == "major":
            version = f"{major + 1}.0.0"
        elif bump == "minor":
            version = f"{major}.{minor + 1}.0"
        elif bump == "patch":
            version = f"{major}.{minor}.{patch + 1}"
        else:
            raise ValueError("A published stable release requires a version bump.")
    else:
        prefix = f"{major}.{minor}.{patch + 1}-beta."
        numbers = [int(match.group(1)) for tag in existing
                   if (match := re.fullmatch(r"v?" + re.escape(prefix) + r"([1-9]\d*)", tag))]
        version = prefix + str(max(numbers, default=0) + 1)
    if version in existing or "v" + version in existing:
        raise ValueError(f"Release/tag already exists for {version}; resolve it manually.")
    return version


def read_commits(baseline, target):
    log = command("git", "log", "--format=%B%x00", "--encoding=UTF-8", "--reverse",
                  f"{baseline}..{target}", "--")
    return [message.strip("\r\n") for message in log.split("\0")
            if message.strip("\r\n")]


def latest_beta_ancestor(releases, base, target):
    major, minor, patch = base
    prefix = f"{major}.{minor}.{patch + 1}-beta."
    candidates = []
    for release in releases:
        if release["draft"] or not release["prerelease"]:
            continue
        match = re.fullmatch(r"v?" + re.escape(prefix) + r"([1-9]\d*)",
                             release["tag_name"])
        if match:
            candidates.append((int(match.group(1)), release["tag_name"]))

    eligible = []
    for number, tag in sorted(candidates, reverse=True):
        try:
            beta_target = command("git", "rev-parse", f"refs/tags/{tag}^{{commit}}").strip()
        except subprocess.CalledProcessError as error:
            raise ValueError(f"Could not resolve published Beta tag {tag}.") from error
        ancestry = subprocess.run(["git", "merge-base", "--is-ancestor", beta_target, target],
                                  cwd=ROOT)
        if ancestry.returncode == 0:
            eligible.append((number, tag, beta_target))
        elif ancestry.returncode != 1:
            raise RuntimeError(f"Could not compare published Beta tag {tag} to the push target.")

    # Visit by descending sequence, preferring descendant commits.
    latest = None
    for candidate in eligible:
        if latest is None:
            latest = candidate
            continue
        ancestry = subprocess.run(["git", "merge-base", "--is-ancestor", latest[2], candidate[2]],
                                  cwd=ROOT)
        if ancestry.returncode == 0:
            latest = candidate
        elif ancestry.returncode != 1:
            raise RuntimeError(f"Could not compare published Beta tags {latest[1]} and {candidate[1]}.")
    return (latest[1], latest[2]) if latest else (None, None)


def breaking_footer(lines):
    start = next((index for index, line in enumerate(lines[1:], 1)
                  if not lines[index - 1].strip() and FOOTER_HEADER.fullmatch(line)), None)
    if start is None:
        return None
    for line in lines[start:]:
        match = BREAKING_FOOTER.fullmatch(line)
        if match:
            return f"{match.group('token')} footer"
    return None


def classify_commit(message):
    lines = message.splitlines()
    if not lines:
        return None
    match = COMMIT_SUBJECT.fullmatch(lines[0])
    if not match or (match.group("scope") is not None and not match.group("scope").strip()):
        return None
    commit_type = match.group("type").casefold()
    breaking_rules = []
    if match.group("breaking"):
        breaking_rules.append("! marker")
    footer = breaking_footer(lines)
    if footer:
        breaking_rules.append(footer)
    if breaking_rules:
        return "major", " + ".join(breaking_rules)
    if commit_type == "feat":
        return "minor", "feat type"
    if commit_type == "fix":
        return "patch", "fix type"
    return None


def plan_commits(messages):
    matches = []
    for message in messages:
        lines = message.splitlines()
        subject = lines[0] if lines else ""
        decision = classify_commit(message)
        if decision:
            bump, rule = decision
            matches.append((bump, rule, subject))
    if not matches:
        return {"bump": "none", "release_notes": "",
                "reason": "No commit matched a fix or feat type, ! marker, or BREAKING CHANGE footer."}
    bump = max((entry[0] for entry in matches), key=BUMP_LEVEL.__getitem__)
    notes = "\n".join(f"- {subject}" for _, _, subject in matches)
    rules = "; ".join(f"{level.upper()} via {rule}: {subject}"
                       for level, rule, subject in matches)
    return {"bump": bump, "release_notes": notes,
            "reason": f"Highest matched level: {bump.upper()}. {rules}"}


def write_outputs(values):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key in OUTPUT_KEYS:
            value = values.get(key, "")
            delimiter = "release_" + uuid.uuid4().hex
            output.write(f"{key}<<{delimiter}\n{value}\n{delimiter}\n")


def main():
    repo = os.environ["GH_REPO"]
    branch = os.environ["GITHUB_REF_NAME"]
    target = os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"[0-9a-f]{40}", target):
        raise ValueError("Push target must be a full commit SHA.")
    if command("git", "rev-parse", "HEAD").strip() != target:
        raise ValueError("Checkout does not match the pushed commit.")
    releases = inventory(repo, "releases")
    tag, base = latest_stable(releases)
    command("git", "fetch", "origin", f"refs/tags/{tag}")
    baseline = command("git", "rev-parse", "FETCH_HEAD^{commit}").strip()
    classification_baseline, classification_tag = baseline, tag
    # Queued pushes may start out of order; never publish an older main commit.
    ancestry = subprocess.run(["git", "merge-base", "--is-ancestor", target, baseline],
                               cwd=ROOT)
    if ancestry.returncode not in (0, 1):
        raise RuntimeError("Could not compare the pushed commit to the stable baseline.")
    if ancestry.returncode == 0:
        write_outputs({"publish": "false"})
        print(f"{target} is already included in stable {tag}; skipping release.")
        return
    if branch == "main":
        ancestry = subprocess.run(["git", "merge-base", "--is-ancestor", baseline, target],
                                  cwd=ROOT)
        if ancestry.returncode == 1:
            raise ValueError(f"Stable baseline {tag} is not an ancestor of the main push target.")
        if ancestry.returncode != 0:
            raise RuntimeError("Could not verify the main push target against the stable baseline.")
    changed = command("git", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                      "--name-only", "-z", baseline, target, "--").split("\0")
    if not any(changed):
        write_outputs({"publish": "false"})
        print(f"No changes against stable {tag}; skipping release.")
        return
    if branch != "main":
        beta_tag, beta_commit = latest_beta_ancestor(releases, base, target)
        if beta_tag:
            classification_baseline, classification_tag = beta_commit, beta_tag
    decision = plan_commits(read_commits(classification_baseline, target))
    summary = f"Baseline: {tag}\n"
    if classification_tag != tag:
        summary += f"Classification baseline: {classification_tag}\n"
    summary += f"Commit: {target}\nBranch: {branch}\n\n{decision['reason']}\n"
    if decision["bump"] != "none":
        existing = {r["tag_name"] for r in releases} | {t["name"] for t in inventory(repo, "tags")}
        version = next_version(base, branch, decision["bump"], existing)
        write_outputs({"publish": "true", "version": version,
                       "release_notes": decision["release_notes"], "commit_sha": target})
        summary += f"\nVersion: {version}\n\n{decision['release_notes']}\n"
    else:
        write_outputs({"publish": "false"})
        summary += "\nNo releasable changes; skipping build and publication.\n"
    print(summary)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
        output.write(summary)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release planning failed: {error}", file=sys.stderr)
        sys.exit(1)
