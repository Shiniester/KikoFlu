"""Offline check for Conventional Commit release planning and commit targeting."""

import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

import plan_push_release as planner


TARGET = "a" * 40
BASELINE = "b" * 40
RELEASES = [
    {"tag_name": "v4.8.1", "published_at": "2026-10-01T00:00:00Z", "draft": False, "prerelease": False},
    {"tag_name": "v4.8.2-beta.7", "published_at": "2026-10-02T00:00:00Z", "draft": False, "prerelease": True},
    {"tag_name": "v4.8.2-beta.8", "published_at": None, "draft": True, "prerelease": True},
]


def git_log(*messages):
    return "".join(f"{message.rstrip()}\n\0\n" for message in messages)


def output_values(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    values = {}
    index = 0
    while index < len(lines):
        key, delimiter = lines[index].split("<<", 1)
        index += 1
        content = []
        while lines[index] != delimiter:
            content.append(lines[index])
            index += 1
        values[key] = "\n".join(content)
        index += 1
    return values


def run_main(*, branch="main", head=TARGET, changed="README.md\0", logs="",
             old_target=False, baseline_ancestor=True, releases=None, tags=None):
    calls = []
    releases = RELEASES if releases is None else releases
    tags = tags or []

    def command(*args):
        calls.append(args)
        if args == ("git", "rev-parse", "HEAD"):
            return head
        if args[:2] == ("git", "fetch"):
            return ""
        if args == ("git", "rev-parse", "FETCH_HEAD^{commit}"):
            return BASELINE
        if args[:2] == ("git", "diff") and "--name-only" in args:
            return changed
        if args[:2] == ("git", "log"):
            return logs
        raise AssertionError(f"Unexpected command: {args}")

    def run(args, cwd):
        args = tuple(args)
        if args == ("git", "merge-base", "--is-ancestor", TARGET, BASELINE):
            return SimpleNamespace(returncode=0 if old_target else 1)
        if args == ("git", "merge-base", "--is-ancestor", BASELINE, TARGET):
            return SimpleNamespace(returncode=0 if baseline_ancestor else 1)
        raise AssertionError(f"Unexpected subprocess: {args}")

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        output, summary = root / "output", root / "summary"
        env = {"GH_REPO": "owner/repo", "GITHUB_REF_NAME": branch,
               "GITHUB_SHA": TARGET, "GITHUB_OUTPUT": str(output),
               "GITHUB_STEP_SUMMARY": str(summary)}
        with patch.dict(os.environ, env, clear=True), \
                patch.object(planner, "ROOT", root), \
                patch.object(planner, "command", command), \
                patch.object(planner, "inventory",
                             side_effect=lambda repo, resource: releases if resource == "releases" else tags), \
                patch.object(planner.subprocess, "run", side_effect=run):
            planner.main()
        return output_values(output), summary.read_text(encoding="utf-8") if summary.exists() else "", calls


def check():
    tag, base = planner.latest_stable(RELEASES)
    assert tag == "v4.8.1" and base == (4, 8, 1)
    for bump, version in [("patch", "4.8.2"), ("minor", "4.9.0"), ("major", "5.0.0")]:
        assert planner.next_version(base, "main", bump, set()) == version
    beta_existing = {release["tag_name"] for release in RELEASES} | {"v4.8.2-beta.9"}
    assert planner.next_version(base, "feature/player", "major", beta_existing) == "4.8.2-beta.10"
    try:
        planner.next_version(base, "main", "patch", {"v4.8.2"})
    except ValueError:
        pass
    else:
        raise AssertionError("An occupied stable version must stop publication")

    messages = [
        "fix(core): repair favorites\n\nThis prose mentions BREAKING CHANGE: but is not a footer.",
        "feat(ui): add filters",
        "refactor!: remove old mode",
        "chore: remove old API\n\nBREAKING CHANGE: callers must use the new API",
        "chore: rename token\n\nBREAKING-CHANGE: consumers must update",
        "chore: update API\n\nRefs: #123\nBREAKING CHANGE: old API removed",
        "fix(api): adjust migration\n\nReviewed-by: Alex\n  verifies migration in client\n  and checks old API\nBREAKING-CHANGE: callers must update",
        "fix(api): remove legacy API\n\nCloses #123\nBREAKING CHANGE: use replacement API",
        "FEAT(scope): add settings",
        "FIX: correct title",
        "chore: lowercase note\n\nbreaking change: lowercase does not trigger",
        "chore: inline note\nBREAKING CHANGE: missing blank separator",
        "docs: mention footer\n\nThe body mentions BREAKING CHANGE: as prose.",
        "perf: tune renderer",
        "chore: update docs",
        "docs: update docs",
        "not a conventional commit",
        "feat(scope)!:missing required space",
    ]
    decision = planner.plan_commits(messages)
    subjects = [
        "fix(core): repair favorites",
        "feat(ui): add filters",
        "refactor!: remove old mode",
        "chore: remove old API",
        "chore: rename token",
        "chore: update API",
        "fix(api): adjust migration",
        "fix(api): remove legacy API",
        "FEAT(scope): add settings",
        "FIX: correct title",
    ]
    assert decision["bump"] == "major"
    assert decision["release_notes"] == "\n".join(f"- {subject}" for subject in subjects)
    assert "Highest matched level: MAJOR" in decision["reason"]
    assert "PATCH via fix type" in decision["reason"]
    assert "MINOR via feat type" in decision["reason"]
    assert "MAJOR via ! marker" in decision["reason"]
    assert "MAJOR via BREAKING CHANGE footer" in decision["reason"]
    assert "MAJOR via BREAKING-CHANGE footer" in decision["reason"]
    assert "MAJOR via BREAKING CHANGE footer: chore: update API" in decision["reason"]
    assert "MAJOR via BREAKING-CHANGE footer: fix(api): adjust migration" in decision["reason"]
    assert "perf: tune renderer" not in decision["release_notes"]
    assert "chore: lowercase note" not in decision["release_notes"]
    assert "chore: inline note" not in decision["release_notes"]

    values, summary, calls = run_main(
        changed="lib/file.dart\0",
        logs=git_log(*messages),
    )
    assert values == {"publish": "true", "version": "5.0.0",
                      "release_notes": decision["release_notes"], "commit_sha": TARGET}
    assert "Highest matched level: MAJOR" in summary
    assert ("git", "log", "--format=%B%x00", "--encoding=UTF-8", "--reverse",
            f"{BASELINE}..{TARGET}", "--") in calls

    values, summary, _ = run_main(
        changed="lib/file.dart\0",
        logs=git_log("chore: update docs", "docs: correct typo", "perf: tune renderer"),
    )
    assert values == {"publish": "false", "version": "", "release_notes": "", "commit_sha": ""}
    assert "No commit matched" in summary

    values, _, calls = run_main(
        branch="feature/player",
        changed="lib/file.dart\0",
        logs=git_log("fix(player): prevent crash"),
        tags=[{"name": "v4.8.2-beta.9"}],
    )
    assert values == {"publish": "true", "version": "4.8.2-beta.10",
                      "release_notes": "- fix(player): prevent crash", "commit_sha": TARGET}
    assert ("git", "log", "--format=%B%x00", "--encoding=UTF-8", "--reverse",
            f"{BASELINE}..{TARGET}", "--") in calls

    values, _, calls = run_main(changed="")
    assert values == {"publish": "false", "version": "", "release_notes": "", "commit_sha": ""}
    assert not any(args[:2] == ("git", "log") for args in calls)

    values, _, calls = run_main(old_target=True)
    assert values == {"publish": "false", "version": "", "release_notes": "", "commit_sha": ""}
    assert not any(args[:2] == ("git", "diff") or args[:2] == ("git", "log") for args in calls)

    try:
        run_main(head="c" * 40)
    except ValueError as error:
        assert "Checkout does not match" in str(error)
    else:
        raise AssertionError("A checkout at another commit must stop planning")

    try:
        run_main(baseline_ancestor=False)
    except ValueError as error:
        assert "not an ancestor" in str(error)
    else:
        raise AssertionError("A main target outside the stable baseline history must stop planning")

    print("Push release planner checks passed.")


if __name__ == "__main__":
    check()
