# gg_multi_do_publish

The multi-repo publish orchestrator of the gg_multi tool family -
publishing all ticket repos in dependency order with skip checks,
resume and rollback.

`gg_multi` manages multi-package workspaces and orchestrates editing,
reviewing and publishing across all repos of a ticket. This package
holds the publish flow; the workspace model lives in `gg_multi_core`
and the daily flows it builds on in `gg_multi_commit`.

## What it provides

- **`do publish`** — publishes every publishable repo of a ticket in
  dependency order: review gate (`did review`), up-front interactive
  configuration, ticket-wide checks, then per repo unlocalize refs,
  propagate published versions, upgrade + re-verify, publish via
  gg_one (version bump → registry upload → auto-merge pull request →
  tag), and restore the workspace state so the ticket stays workable.
- **`do publish --merge-only`** — the same flow with every release
  step left out: no version bump, no registry upload, no tag. There is
  no separate `do merge` command.
- **`do configure-publish`** (`DoConfigurePublishCommand`, called
  automatically when no configuration exists) — asks per repo for the
  version increment and merge message up front and writes
  `<ticket>/.gg/.gg-publish.json`; no prompt ever sits between two
  publishes.
- **`can publish`** — the ticket-wide preflight (uncommitted changes,
  `did commit`, `do push`, `can merge`, npm login) plus the per-repo
  gate `do publish` runs right before each repo's release.
- **Skip checks** — unchanged repos are not published:
  `PublishSkipCheck` (gg_multi_core) decides, `--publish-unchanged`
  overrides.
- **First-publish gate** (`EnsureInRegistry`) — a package that was
  never published must be published manually once; the gate prints the
  commands, waits, re-checks and continues.
- **Progress & resume** — each repo's status is recorded in
  `.gg/.gg-publish.json`; `--continue` resumes after a failure,
  `--restart` discards the recorded progress.
- **Registry checkers** (`pub_dev_checker.dart`,
  `npm_registry_checker.dart`) — published-version lookups for pub.dev
  and npm.

## License

`gg_multi_do_publish` is licensed under the terms specified in the
`LICENSE` file.
