# Release automation

When a release is requested through the GitHub Actions **Build and Release** workflow:

1. Prepare and push the requested release source.
2. Dispatch the workflow with the requested version and release notes.
3. Confirm that GitHub accepted the dispatch and capture the workflow URL.
4. Report the workflow URL and finish the local release task.

GitHub Actions runs asynchronously after dispatch. Treat the accepted dispatch as the completion boundary for the local task. Do not wait for, poll, watch, or inspect the workflow's later build and release result unless the user explicitly asks for monitoring or verification.

When reporting an accepted dispatch, state that the workflow was started and link to the run; do not state that the release was published until a later verification is explicitly requested and completed.
