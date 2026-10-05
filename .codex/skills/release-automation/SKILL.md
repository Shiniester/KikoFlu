---
name: "release-automation"
description: "Use when triggering or discussing KikoFlu GitHub Actions release workflows, including Android Beta releases for small or patch updates and all-platform stable minor and major releases."
metadata:
  short-description: "KikoFlu GitHub Actions 发布流程与版本平台选择。"
---

# Release automation

Resolve the release branch from the current local branch's upstream remote and
branch. If no upstream exists, use `origin` and the same branch name, establishing
that upstream when pushing. If HEAD is detached, ask which branch to use before
pushing or dispatching. Use this remote branch for both repository sync and release
workflow dispatch.

When a release is requested through a GitHub Actions workflow selected below,
and the user explicitly requests the full repository sync:

1. Inspect the working tree and include all current tracked and untracked changes in the requested commit.
2. Commit the changes locally with a concise release-relevant message. For Beta releases, include the resolved remote branch name, for example `release: 4.5.3-beta.1 (branch: feature/player)`.
3. Push only the current local branch to its resolved remote branch using an explicit refspec (`HEAD:refs/heads/<remote-branch>`).
4. Confirm that the remote branch points to the local release commit.
5. Dispatch the workflow in that remote's GitHub repository with an explicit branch ref (`gh workflow run <workflow> --repo <repository> --ref <remote-branch>`) and the requested version and release notes. The workflow checkout and release tag must use the dispatched branch's commit.
6. Confirm that GitHub accepted the dispatch and capture the workflow URL.
7. Report the commit, remote branch, push result, and workflow URL, then finish the local release task.

Do not commit or push merely because a release workflow is being discussed;
those repository mutations require the user's explicit request. Keep the release
on the resolved branch; do not merge into or push `main` unless it is that branch.

GitHub Actions runs asynchronously after dispatch. Treat the accepted dispatch as the completion boundary for the local task. Do not wait for, poll, watch, or inspect the workflow's later build and release result unless the user explicitly asks for monitoring or verification.

When reporting an accepted dispatch, state that the workflow was started and link to the run; for Beta releases, include the resolved remote branch name. Do not state that the release was published until a later verification is explicitly requested and completed.

## Platform selection by release size

- Small or patch updates (小版本发布) default to Android Beta releases using **Build Android Beta and Pre-release** (`build_android_beta.yml`). Explicit Beta requests also use this workflow.
- Before choosing a Beta version, query the repository's latest published stable GitHub release, excluding drafts and pre-releases. Keep its MAJOR and MINOR components and increment PATCH by one: stable `4.5.2` produces the Beta base `4.5.3`. Derive this base from the current stable release each time; example versions are not fixed defaults.
- Use `MAJOR.MINOR.PATCH-beta.N`, where N starts at 1 and increases beyond the highest existing Beta number for that base across tags and releases, including drafts. For example, stable `4.5.2` with an existing `4.5.3-beta.2` produces `4.5.3-beta.3`; after stable `4.5.3` is published, the next base becomes `4.5.4`. Verify an explicitly supplied version against this rule and report any mismatch before dispatching.
- Beta releases publish the Android universal and arm64 APKs as a GitHub **Pre-release**, with `latest=false`. They use the separate `com.meteor.kikoeruflutter.beta` application ID and **KikoFlu Beta** name so they can coexist with the stable app.
- Minor and major releases, where the MINOR or MAJOR component changes, use **Build and Release** (`build.yml`). This workflow builds and publishes all supported platform packages.
- Use **Build Android and Release** (`build_android.yml`) for an Android-only stable patch release only when the user explicitly requests that stable release.

Before dispatching the selected workflow, verify that the version matches its release channel and that the corresponding tag and release do not already exist. If the user specifies an existing Beta version, report the conflict rather than reusing it. Dispatch Beta releases with the `version` and `release_notes` inputs.
