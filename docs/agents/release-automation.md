# Release automation

When a release is requested through the GitHub Actions **Build and Release** workflow:

1. Prepare and push the requested release source.
2. Dispatch the workflow with the requested version and release notes.
3. Confirm that GitHub accepted the dispatch and capture the workflow URL.
4. Report the workflow URL and finish the local release task.

GitHub Actions runs asynchronously after dispatch. Treat the accepted dispatch as the completion boundary for the local task. Do not wait for, poll, watch, or inspect the workflow's later build and release result unless the user explicitly asks for monitoring or verification.

When reporting an accepted dispatch, state that the workflow was started and link to the run; do not state that the release was published until a later verification is explicitly requested and completed.

## Platform selection by release size

- Patch releases, where only the PATCH component changes (for example, `4.4.0` to `4.4.1`), use **Build Android and Release** (`build_android.yml`). This workflow builds and publishes only the Android universal and arm64 APKs.
- Minor and major releases, where the MINOR or MAJOR component changes, use **Build and Release** (`build.yml`). This workflow builds and publishes all supported platform packages.

Before dispatching either workflow, confirm that the requested version matches the release size and that the corresponding tag and release do not already exist.
