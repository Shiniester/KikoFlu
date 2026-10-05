# Push releases

`.github/workflows/release_on_push.yml` runs once per branch push. A push containing
several commits produces one release plan for the pushed tip. Tag pushes and branch
deletions do not publish releases.

- `main`: full-platform stable release through `build.yml`.
- Other branches: Android Beta pre-release through `build_android_beta.yml`.
- Existing manual release workflows remain available, including Android-only stable.

## Commit-based version selection

Actions parses [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
from the latest published stable release's actual tag commit to the pushed commit
for stable releases. For Beta releases, it excludes commits reachable from every
published Beta tag on the pushed commit's ancestry with the current stable-derived
version base, as well as commits reachable from the stable release tag. This excludes
changes already published from every merged Beta history. If no matching Beta tag is
an ancestor, only the stable release tag is used. The planner resolves each Beta tag
to its commit; the release's target branch metadata does not determine ancestry. New
reachable commits are considered, including commits brought in by a merge. For a
squash merge, the resulting squash commit message determines the level.

| Commit message | Release trigger |
| --- | --- |
| `fix: ...` or `fix(scope): ...` | PATCH |
| `feat: ...` or `feat(scope): ...` | MINOR |
| `type!: ...`, `type(scope)!: ...` or a `BREAKING CHANGE: ...` footer | MAJOR |
| Other types or messages outside the convention | No update |

Types are case-insensitive. `BREAKING CHANGE:` and `BREAKING-CHANGE:` footer labels
are uppercase and require an explanation. A breaking marker applies to any
valid conventional type, including `chore` or `refactor`. Examples:

```text
fix(reader): restore playback after interruption
feat(comics): add offline chapter downloads
refactor(storage)!: replace the cache format
```

```text
feat(player): simplify the playback interface

BREAKING CHANGE: remove the old playback configuration format
```

The highest level wins: MAJOR > MINOR > PATCH. Commits such as `docs`, `test`, `ci`
and `chore` have no release impact unless marked as breaking. A history containing
only non-releasing commits, or no tree changes, skips publication. No AI service,
API key, skill or release record is used to determine the version.

Beta keeps the latest stable version's next PATCH base and increments `beta.N`
beyond all existing tags and releases, including drafts. The conventional level
determines whether to publish a Beta, without changing its version-base rule.
Release notes contain the subjects of commits that trigger an update.

## Codex turn auto-commit messages

The turn auto-commit hook accepts a one-time message from local Git configuration
`codex.<CODEX_THREAD_ID>.turnCommitMessage`. Set it before finishing a changed turn:

```powershell
git config --local "codex.$env:CODEX_THREAD_ID.turnCommitMessage" "fix(reader): restore playback after interruption"
```

The hook validates the conventional header, uses the full configured message and
clears it after a successful commit. A new turn clears stale messages for that
chat. Messages for other chats are unaffected. Without a configured message the
hook uses `chore: save turn changes`, which has no release impact. Normal manual
commits use `git commit` with a conventional message directly.

## Publication and queue

Publication uses the built-in `GITHUB_TOKEN`, or `RELEASE_TOKEN` when configured.
For targets changing `.github/workflows/` relative to the default branch, set
`RELEASE_TOKEN` to a fine-grained PAT limited to this repository with **Contents:
Read and write** and **Workflows: Read and write**. It is used only in publication
steps. See [GitHub's permission rules](https://docs.github.com/en/rest/releases/releases#create-a-release).

Automatic and manual runs share the `kikoflu-release` concurrency queue. Each
automatic run holds its place until publication finishes, so the next planner
uses the published version. The queue holds up to 100 pending runs and waiting
order can differ from push order. An older `main` push already included in the
stable release is skipped. Missing baselines and occupied versions stop the run
for human action. Checkout, builds and release tags use the exact pushed SHA.

The project post-commit hook is removed. Commits remain local until pushed.

## Check

Run `python scripts/test_plan_push_release.py` for the offline check. The planning
summary shows the baseline, selected level, version and release notes. A successful
plan selects the build; publication completes only when the release workflow succeeds.
