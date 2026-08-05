# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`gg_multi_do_publish` is the multi-repo publish orchestrator of the gg_multi tool family. It publishes all repos of a ticket in dependency order, with up-front configuration, per-repo gates, skip checks for unchanged repos, resume after failures and a restore that keeps the ticket workable. The workspace model (ticket state, git snapshot, `PublishSkipCheck`, `cleanUpTicket`) lives in `gg_multi_core`; the `do push` / `did review` flows it builds on in `gg_multi_commit`; the single-repo publish it delegates to in gg_one.

All commands extend `DirCommand<T>` from `gg_args`; the primary logic lives in `get()`, and `exec()` delegates to it. `ggLog` is constructor-injected everywhere.

## `do configure-publish` — no CLI command any more

`DoConfigurePublishCommand` (in `lib/src/commands/do/configure_publish.dart`) is **not registered as a subcommand**. `do publish` calls it automatically whenever no configuration exists. It interactively builds the publish configuration for the current ticket and writes it to `<ticket>/.gg/.gg-publish.json`. It walks the repos in dependency order and asks, per repo, for the version increment (via gg_one's `VersionSelector`, with an injectable `InteractAdapter` for tests) and the merge message. With `--merge-only` (or `mergeOnly: true`) the increment question is **skipped entirely** and no `version_increment` is written.

**Increment-preview baseline**: the `Patch (x -> y)` options are calculated from the version the repo last **published to its registry** (gg_publish's `PublishedVersion` — pub.dev/npm, git version tag for private and manifest-less repos, 0.0.0 when nothing resolves), _not_ from the manifest — only `main` carries the released version, so a feature branch's manifest normally lags behind the registry. The merge-message default is `-m`/`--message` if given, else the ticket description, else `Publish <repo>`. `configFileFor(ticketDir)` returns the canonical `.gg/.gg-publish.json` path used everywhere.

## `do publish`

`DoPublishCommand` (in `lib/src/commands/do/publish.dart`) publishes all ticket repos in dependency order. It first — unless resuming — checks the **review gate** (delegating to `did review`, which chains `did commit` → `did push` → the hash-based review state, so the most fundamental missing step is reported; the gate runs *before* the configuration is resolved), then **resolves the publish configuration**, then runs the ticket-wide half of `can publish` (uncommitted changes, `did commit`, `do push` — with `upgrade: false` —, `can merge`, npm login), then per repo: unlocalize refs, restore `publish_to`, propagate published dependency versions, refresh deps, **upgrade the dependencies and re-verify with `gg can commit`** (only now do the refs resolve against the sibling versions published earlier in the run), commit (the force-commit sweeps ref *and* upgrade changes into one `#gg:` bookkeeping commit), **check that this repo can be published**, push, delegate to gg_one's `gg do publish` (version bump → registry publish → merge to main via auto-merge squash pull request → tag → push) and finally **restore the workspace state**. The pull request `do review` opened is **reused** — publishing is where the auto-merge flag is finally set. The repo's `pubspec_overrides.yaml` is saved to `.gg/pubspec_overrides_backup.yaml` before the unlocalization.

**Per-repo publish gate** (`CanPublishCommand.checkRepo`, in `lib/src/commands/can/publish.dart`): gg_one's `can publish` runs `Pana(publishedOnly: true)`, which cannot resolve a dependency constraint naming a sibling version that is not on pub.dev yet. The check therefore runs **per repo, inside `_publishRepo`** — after the refs were unlocalized, the versions propagated and the result force-committed, and **before** the push. By then every dependency published earlier in the same run is on its registry and pana resolves. Both positions are load-bearing: **after the commit** because gg_one's `can publish` contains `did commit` and the ref changes leave the manifests dirty; **before the push** because nothing irreversible has happened yet, so a rejected repo takes the **full restore** path. The steps that stay ticket-wide are the ones that cannot be per-repo: `do push` merges main into the branches and must not run mid-publish; `did commit`/the npm-login sweep are ticket-wide by nature. The **npm sweep** stays up front because discovering a missing login after three packages already went to a registry is the worst failure this command has. The accepted trade-off: repo A can already be published when repo B is rejected — A keeps its `published` marker, B is `failed`, `--continue` resumes at B.

**First-publish gate** (`EnsureInRegistry`, `lib/src/backend/ensure_in_registry.dart`): right before a repo's `gg do publish`, the gate checks (via gg_publish's `IsInRegistry`) that at least one version of the package is on its registry. A package that was never published has to be published manually by the user first: the gate prints the shell commands in blue (`cd <repo>` + `dart pub publish` / `pnpm publish --no-git-checks [--access public]`), waits for ⏎ on stdin (`q` aborts, headless runs fail fast via `throwWhenNotATerminal`), re-checks and continues. Repos without a public registry are skipped.

**Skipping unchanged repos**: `PublishSkipCheck` (gg_multi_core) decides whether a release is needed — see its docs. A skipped repo is logged, marked `skipped` in the ticket file, and its _current_ version is still captured so dependents resolve. Everything undecidable errs toward publishing. `--publish-unchanged` restores publish-everything. On `--continue` a `skipped` repo is **re-evaluated instead of trusted** (`published` markers are trusted).

**Config resolution** (`_resolvePublishConfig`, precedence): `--continue` reuses the runtime `.gg/.gg-publish.json` (errors if absent) → an explicit `--config <path>` → the runtime `.gg/.gg-publish.json` → the legacy `<ticket>/.gg-publish.json` → an interactive `do configure-publish`. `--restart` skips the two implicit files. `--config`/legacy files are only _read_; the mutable runtime copy receives progress and is deleted on full success. Merge message + version increment per repo come from `PublishConfig.forRepo` (per-repo override → top-level default). `-m`/`--message` only matters on the interactive/`--restart` path.

**Progress + `--continue`**: after each repo, its status is written into the ticket-level `.gg/.gg-publish.json` (`published`/`failed`/`skipped`). `--continue` skips repos marked `published` (still capturing their version) and resumes the rest, forwarding `resume: true` to gg_one's `do publish` — which resumes at the first open step of its own repo-level `<repo>/.gg/gg-publish.json`. Two levels, one file family: ticket file = repo status, repo file = step progress. `_publishRepo` ensures `.gg/.gg-publish.json` is gitignored (gg_one's `EnsurePublishConfigIgnored`, `commit: false`). The review gate + ticket-wide `can publish` steps are skipped on `--continue` **when irreversible progress exists** (some repo `published`, or some repo's step file records `done_steps`); a `--continue` after a failure without progress still runs both. The per-repo gate re-runs for every repo the resume publishes — except one that already carries gg_one step progress (its version is bumped and possibly uploaded, exactly what pana and `is feature branch` would trip over). An explicit `--config` refuses to clobber a runtime file that still holds progress; `--restart` discards ticket **and** repo-level files.

**Keeping the repos workable** (`_restoreWorkspaceState`): right after gg_one's publish returns — the repo sits on the default branch — the restore runs: (1) check the feature branch out again, (2) merge the released default branch back into it (trivially clean — but it makes the release the common ancestor, so the next `do push` main-merge cannot conflict; without it every TypeScript repo would conflict on `package.json`), (3) restore the overrides backups and re-localize via `ChangeRefsToLocal` — Dart gets its path overrides back, pnpm-managed TypeScript its `link:` overrides — and the `gg_localize_refs` backups are rewritten with the freshly published versions, (4) refresh the dependencies, (5) commit everything as `#gg: restored local workspace references` (gg-owned files only, so `PublishSkipCheck` still reports the repo unchanged), (6) record **`didPublish`** in `.gg/gg.json` (not in merge-only mode) — written only now, so the hash covers the state the user continues working on, (7) push. A repo the skip check leaves unpublished keeps its localized refs and only gets the `didPublish` marker. Restore failures are yellow warnings, never publish failures. At the end of every successful run the ticket-level `didReview` is re-blessed (`TicketState.writeSuccess`).

**What happens to the ticket — asked up front, applied at the end** (merge-only included): right after the version increments are resolved (`_offerTicketCleanup`) the run asks its **last** interactive question, via the same cursor-key `Select` as the version increment:

```
What should happen to the ticket when ready?
❯ Move to .trash and delete the remote branches
  Remove it manually with »gg do rm ticket <ticket>«
```

Every interactive decision is made before the first irreversible step. The answer is applied after the last repo is through. Declining prints the hint that the ticket stays workable. Accepting runs `cleanUpTicket` (gg_multi_core): per repo the remote feature branch is deleted (a failed deletion **aborts the cleanup and keeps the ticket in place**; `--no-delete-remote-branch` keeps the branches), then the whole ticket folder moves to `<root>/.trash/<ticket>` in one `Trash.moveTicketToTrash` call, followed by the `cd <workspace root>` command in blue. Without a terminal the question is skipped and the ticket is kept.

**Reporting a failure**: the moment `failed` is written, `_logPublishFailure` prints why — mode-specific wording + repo name + exception text in red, followed by a yellow resume hint with `gg do publish --continue` in blue. A repo rejected by the per-repo gate lands here as well. It runs _before_ the rollback and unconditionally (per-repo detail goes to `taskLog`, a no-op without `--verbose`); the exception is still rethrown.

**Rollback**: each repo is snapshotted before its publish (branch/HEAD, `status`/stash via `git_snapshot.captureUncommitted`, package version, main positions local + remote, the feature branch's remote head, tags). **When a repo's publish fails, only that repo is restored — previously published repos stay published.** Two modes, because gg_one publishes to the registry _before_ merging and pub.dev/npm cannot be unpublished:

- **Full restore** — only when provably nothing irreversible happened: end merges/rebases, back to the feature branch, `reset --hard`, restore the local main position, delete tags the run created, re-apply stashed changes with `--index`. Also deletes the repo-level step file (gitignored, survives `reset --hard`, but its markers would describe removed commits).
- **Cleanup restore** — otherwise, **keep all commits** so `--continue` resumes via gg_one's step file. Entered on any of: a _committed_ version bump (an uncommitted version change is recoverable and full-restores), `origin/main` having moved, or the feature branch already pushed. Remote comparisons only conclude "moved" from a concrete differing hash — an unreachable `git ls-remote` is treated as _unknown_, never as "already released".

The publish failure always stays the primary error; restore problems are logged with a manual-recovery hint (checkout/reset commands and the stash hash).

## `do publish --merge-only`

There is **no `do merge` command** — it was folded into `do publish --merge-only`, so there is exactly one flow. The flag puts `DoPublishCommand` into merge mode (resolved in `get()`; `mergeOnly: true` in the constructor for programmatic callers) — the _same_ flow with every release step left out inside gg_one: **no version bump, no `CHANGELOG.md` release heading, no registry upload and no version tag**. Each repo's main branch keeps its released version and its `## Unreleased` entries; the next `gg do publish` releases them. The run also skips the registry-visibility capture. **No version increment is asked for.** All user-facing wording follows the mode (`merged` instead of `published`); the runtime file, the `status` markers and `--continue`/`--restart`/`--publish-unchanged` are unchanged.

**Precondition**: the merge is refused while any repo still redirects a dependency to a local working copy — a `pubspec_overrides.yaml` with a `path:` override (gg_one's `NoPubspecOverrides.hasLocalizedRefs`) or a `pnpm-workspace.yaml` with a `link:` override (gg_localize_refs' `PnpmWorkspaceIo.hasLocalizedRefs`); an unparsable file is treated as localized. Merging such a ticket would put references onto main that nobody can resolve, so it has to be _published_. The guard runs **before the ticket-wide checks push or merge anything**. `--force` skips it and is forwarded to gg_one.

## Registry checkers

- `lib/src/backend/pub_dev_checker.dart` — checks published versions on pub.dev (`PackagePublishInfo`).
- `lib/src/backend/npm_registry_checker.dart` — the npm counterpart.

## Code Standards

- **Line length**: 80 characters maximum.
- **Quotes**: Single quotes (`prefer_single_quotes`).
- **Trailing commas**: Required in all parameter/argument lists.
- **Return types**: Always declared explicitly.
- **Public API docs**: All public members require dartdoc comments.
- **Strict analyzer**: `strict-casts`, `strict-inference`, `strict-raw-types` enabled.
- **Test coverage**: 100% required. Every file under `lib/src/` must have a matching test at the same relative path under `test/`.
- **Mocks**: Mock classes live in the same file as the class they mock, extending `MockDirCommand`.
- **Commits/pushes**: Always go through `gg do commit` / `gg do push`, never raw `git commit` / `git push`.
