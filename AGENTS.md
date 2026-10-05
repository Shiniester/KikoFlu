## Agent skills

### Issue tracker

Issues are tracked in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

The default five-role triage label vocabulary is used. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context domain documentation layout. See `docs/agents/domain.md`.

### Scope limits

Before proposing fixes, running verification, reviewing work, or writing deliverables, follow `docs/agents/scope-limits.md`.

### Commit messages

Use Conventional Commits: `fix: ...` for fixes, `feat: ...` for features, and
`!` or a `BREAKING CHANGE:` footer for breaking changes. Push releases derive
PATCH/MINOR/MAJOR directly from these messages; other types do not publish unless
marked as breaking.

Before finishing repository changes that the turn auto-commit hook will commit,
set local Git configuration `codex.<CODEX_THREAD_ID>.turnCommitMessage` to the
complete Conventional Commit message. The hook consumes this chat-specific value
after a successful commit. Prepare a message for each changed turn; use `chore`,
`docs`, `test`, `ci` or another appropriate type for changes without release impact.
