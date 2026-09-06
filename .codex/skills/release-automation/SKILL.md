---
name: "release-automation"
description: "Use when triggering or discussing KikoFlu GitHub Actions release workflows, including choosing Android-only patch releases or all-platform minor and major releases."
metadata:
  short-description: "KikoFlu GitHub Actions 发布流程与版本平台选择。"
---

# Release automation

When a release is requested through either the GitHub Actions **Build and Release** or **Build Android and Release** workflow,
and the user explicitly requests the full repository sync:

1. Inspect the working tree and include all current tracked and untracked changes in the requested commit.
2. Commit the changes locally with a concise release-relevant message.
3. Merge that commit into `main`, preserving any unrelated work already present there.
4. Push the resulting `main` branch to the `origin` remote (`origin/main`).
5. Dispatch the workflow with the requested version and release notes.
6. Confirm that GitHub accepted the dispatch and capture the workflow URL.
7. Report the commit, merge/push result, and workflow URL, then finish the local release task.

Do not commit, merge, or push merely because a release workflow is being discussed;
those repository mutations require the user's explicit request. If `main` is checked
out in another worktree, verify that checkout is clean before merging there.

GitHub Actions runs asynchronously after dispatch. Treat the accepted dispatch as the completion boundary for the local task. Do not wait for, poll, watch, or inspect the workflow's later build and release result unless the user explicitly asks for monitoring or verification.

When reporting an accepted dispatch, state that the workflow was started and link to the run; do not state that the release was published until a later verification is explicitly requested and completed.

## Platform selection by release size

- Patch releases, where only the PATCH component changes (for example, `4.4.0` to `4.4.1`), use **Build Android and Release** (`build_android.yml`). This workflow builds and publishes only the Android universal and arm64 APKs.
- Minor and major releases, where the MINOR or MAJOR component changes, use **Build and Release** (`build.yml`). This workflow builds and publishes all supported platform packages.

Before dispatching either workflow, confirm that the requested version matches the release size and that the corresponding tag and release do not already exist.
