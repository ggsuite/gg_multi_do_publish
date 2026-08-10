# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`gg_multi_do_publish` is the multi-repo publish orchestrator of the gg_multi tool family. It publishes all repos of a ticket in dependency order, with up-front configuration, per-repo gates, skip checks for unchanged repos, resume after failures and a restore that keeps the ticket workable. The workspace model (ticket state, git snapshot, `PublishSkipCheck`, `cleanUpTicket`) lives in `gg_multi_core`; the `do push` / `did review` flows it builds on in `gg_multi_commit`; the single-repo publish it delegates to in gg_one.

All commands extend `DirCommand<T>` from `gg_args`; the primary logic lives in `get()`, and `exec()` delegates to it. `ggLog` is constructor-injected everywhere.

## Where the version question lives

**In `gg do review`** (gg_multi_commit), not here. The review plans the release — which repos the ticket actually publishes — and asks the version increment and merge message for exactly those, storing them in `<ticket>/.gg/gg-publish.json`. `do publish` then finds every answer in place and asks nothing. Asking at publish time asked for repos the publish then skipped, and the same repos were getting pull requests nobody needed.

The planning pass itself is **`PublishPlanner`** in gg_multi_core, shared by both commands — see its docs there for the decision order, the »ask only what the configuration does not answer« rule and the version prediction. `do publish` still runs it (repos may have to be asked when no review wrote the configuration, or when `--restart` discarded it), and it is still the authority on what the run publishes.

## `do configure-publish` — no CLI command any more

`DoConfigurePublishCommand` (in `lib/src/commands/do/configure_publish.dart`) is **not registered as a subcommand**. It is the way to (re-)write the publish configuration by hand; `do publish` falls back to it when none exists. It walks the repos in dependency order through `PublishPlanner` and asks, per repo that **needs a release**, for the version increment (gg_one's `VersionSelector`, injectable `InteractAdapter`) and the merge message. With `--merge-only` (or `mergeOnly: true`) the increment question is **skipped entirely** and no `version_increment` is written.

Every question is asked afresh — that is what running this command means, so the answers of an existing configuration are deliberately *not* reused. The one thing that stops it is a file still carrying the **progress markers of an unfinished publish**: rewriting it would discard them, so it throws `unfinishedPublishMessage` instead. `configFileFor(ticketDir)` returns the canonical `.gg/gg-publish.json` path (it delegates to core's `publishConfigFileFor`); the merge-message default is `-m`/`--message` if given, else the ticket description, else `Publish <repo>`.

## `do publish`

`DoPublishCommand` (in `lib/src/commands/do/publish.dart`) publishes all ticket repos in dependency order.

**The order of `get()`** — and why it is this order: (1) **load** whatever configuration the files supply (`_loadExistingPublishConfig`: `--continue` → `--config` → the runtime `.gg/gg-publish.json` → the legacy file; `--restart` discards the implicit ones). This stays up front because the runtime file is the resume anchor and a leftover one carrying progress markers has to be reported before anything else happens. (2) The **review gate** (`did review`, which chains `did commit` → `did push` → the hash-based review state) and the ticket-wide half of `can publish` (uncommitted changes, `did commit`, `do push` with `upgrade: false`, `can merge`, npm login) — both skipped when a resume already made irreversible progress. (3) The **planning pass** (`_planPublish`). (4) The ticket-cleanup question. (5) The per-repo publish loop.

Only the *interactive* branch of the configuration moved behind the checks; every file-based one stayed. That is the whole point: `do push` merges the main branches in and refreshes the dependencies, so **before it the skip check cannot be trusted** — `origin/main` may not even be fetched. Asking version questions before that means asking them for repos the run then skips, and for runs `can merge` rejects a moment later.

**The planning pass** is gg_multi_core's `PublishPlanner` — the very pass `gg do review` runs, so a reviewed ticket arrives here fully answered and nothing is asked at all. It walks the repos once, in dependency order, deciding per repo whether it needs a release, asking only what the configuration does not already answer, and predicting the version later repos resolve against; see the gg_multi_core CLAUDE.md for the details. `do publish` passes `requireAnswers: true`: without a terminal, a repo that still needs an answer fails with a message naming the repo, `gg do configure-publish` and `--config` — instead of hanging on a prompt nobody can answer. The answers it collected are saved to the runtime file right after the pass, which is what makes them the resume anchor of the run.

The loop keeps its own `PublishSkipCheck` call as the authority, but the plan may only be **tightened, never loosened**: a repo the plan marked as publishing is published even if it now looks skippable, because the questions for it were already answered.

**The invariant about interactive decisions** changed with this order and now reads: *every interactive decision falls after every gate that can still reject the run, and before the first irreversible release step.* `do push` runs before the questions — it only moves the feature branch the review gate already demands to be pushed; nothing reaches a registry, nothing lands on `main`, no tag is created.

**A run that publishes nothing** reports `Nothing to publish — every repo is already published` (`merge`/`merged` in merge-only mode) and is **not** asked what should happen to the ticket: the user expected a release, nothing happened, and offering to move the ticket to the trash would be a surprising side effect of doing nothing. `didPublish` per repo and the ticket-level `didReview` re-blessing still happen — `do push` just wrote `#gg` commits, and without the re-blessing the next run would demand a review for a state nobody changed.

Per repo the flow is: unlocalize refs, restore `publish_to`, propagate published dependency versions, refresh deps, **upgrade the dependencies and re-verify with `gg can commit`** (only now do the refs resolve against the sibling versions published earlier in the run), commit (a `#gg:` system commit — pathspec-limited to gg-owned files, with any pending user work saved in its own prefix-less commit first, and recording `GgState.doCommitKey`: the unlocalization rewrote the manifests, and the gate right after answers »is everything committed?« from that hash), **check that this repo can be published**, push, delegate to gg_one's `gg do publish` (with `upgrade: false` — gg_one upgrades before every publish of its own, and this loop already did it for this repo, in dependency order) and finally **restore the workspace state**. The pull request `do review` opened is **reused** — publishing is where the auto-merge flag is finally set. The repo's `pubspec_overrides.yaml` is saved to `.gg/pubspec_overrides_backup.yaml` before the unlocalization.

**Per-repo publish gate** (`CanPublishCommand.checkRepo`, in `lib/src/commands/can/publish.dart`): gg_one's `can publish` runs `Pana(publishedOnly: true)`, which cannot resolve a dependency constraint naming a sibling version that is not on pub.dev yet. The check therefore runs **per repo, inside `_publishRepo`** — after the refs were unlocalized, the versions propagated and the result force-committed, and **before** the push. By then every dependency published earlier in the same run is on its registry and pana resolves. Both positions are load-bearing: **after the commit** because gg_one's `can publish` contains `did commit` and the ref changes leave the manifests dirty; **before the push** because nothing irreversible has happened yet, so a rejected repo takes the **full restore** path. The steps that stay ticket-wide are the ones that cannot be per-repo: `do push` merges main into the branches and must not run mid-publish; `did commit`/the npm-login sweep are ticket-wide by nature. The **npm sweep** stays up front because discovering a missing login after three packages already went to a registry is the worst failure this command has. The accepted trade-off: repo A can already be published when repo B is rejected — A keeps its `published` marker, B is `failed`, `--continue` resumes at B.

**`--no-pana`**: `gg_multi can publish` and `do publish` both carry the flag
(pana runs by default). `do publish` resolves it once and passes it to
`CanPublishCommand.checkTicket`/`checkRepo` and, as
`options: {gg.panaOption: <value>}`, to gg_one's `do publish`; `CanPublishCommand`
forwards it the same way into gg_one's `can publish`. The `options` map of
`DirCommand.exec` is the carrier throughout — see the gg_one_do_publish
CLAUDE.md for why the skip sits in a wrapper around `Pana`.

**First-publish gate** (`EnsureInRegistry`, `lib/src/backend/ensure_in_registry.dart`): right before a repo's `gg do publish`, the gate checks (via gg_publish's `IsInRegistry`) that at least one version of the package is on its registry. A package that was never published has to be published manually by the user first: the gate prints the shell commands in blue (`cd <repo>` + `dart pub publish` / `pnpm publish --no-git-checks [--access public]`), waits for ⏎ on stdin (`q` aborts, headless runs fail fast via `throwWhenNotATerminal`), re-checks and continues. Repos without a public registry are skipped.

**Skipping unchanged repos**: `PublishSkipCheck` (gg_multi_core) decides whether a release is needed — see its docs. A skipped repo is logged, marked `skipped` in the ticket file, and its _current_ version is still captured so dependents resolve. Everything undecidable errs toward publishing. `--publish-unchanged` restores publish-everything. On `--continue` a `skipped` repo is **re-evaluated instead of trusted** (`published` markers are trusted).

**Config resolution** is split in two. `_loadExistingPublishConfig` (up front) covers every *file* source, in this precedence: `--continue` reuses the runtime `.gg/.gg-publish.json` (errors if absent) → an explicit `--config <path>` → the runtime `.gg/.gg-publish.json` → the legacy `<ticket>/.gg-publish.json`. `--restart` skips the two implicit files. When only the interactive path is left it returns `null`, and the planning pass collects the answers later — per repo, and only for the repos that publish. `--config`/legacy files are only _read_; the mutable runtime copy receives progress and is deleted on full success. Merge message + version increment per repo come from `PublishConfig.forRepo` (per-repo override → top-level default). `-m`/`--message` only matters on the interactive/`--restart` path.

**Progress + `--continue`**: after each repo, its status is written into the ticket-level `.gg/.gg-publish.json` (`published`/`failed`/`skipped`). `--continue` skips repos marked `published` (still capturing their version) and resumes the rest, forwarding `resume: true` to gg_one's `do publish` — which resumes at the first open step of its own repo-level `<repo>/.gg/gg-publish.json`. Two levels, one file family: ticket file = repo status, repo file = step progress. `_publishRepo` ensures `.gg/.gg-publish.json` is gitignored (gg_one's `EnsurePublishConfigIgnored`, `commit: false`). The review gate + ticket-wide `can publish` steps are skipped on `--continue` **when irreversible progress exists** (some repo `published`, or some repo's step file records `done_steps`); a `--continue` after a failure without progress still runs both. The per-repo gate re-runs for every repo the resume publishes — except one that already carries gg_one step progress (its version is bumped and possibly uploaded, exactly what pana and `is feature branch` would trip over). An explicit `--config` refuses to clobber a runtime file that still holds progress; `--restart` discards ticket **and** repo-level files.

**Keeping the repos workable** (`_restoreWorkspaceState`): right after gg_one's publish returns the restore runs. (Since gg_one made its merge checkout-free, the repo already sits on the feature branch when it returns — the checkout below is a no-op that stays as a guard.) (1) check the feature branch out again, (2) merge the released default branch back into it (trivially clean — but it makes the release the common ancestor, so the next `do push` main-merge cannot conflict; without it every TypeScript repo would conflict on `package.json`), (3) restore the overrides backups and re-localize via `ChangeRefsToLocal` — Dart gets its path overrides back, pnpm-managed TypeScript its `link:` overrides — and the `gg_localize_refs` backups are rewritten with the freshly published versions, (4) refresh the dependencies, (5) commit everything as `#gg: restored local workspace references` — a system commit, so »gg-owned files only« is now enforced by the pathspec instead of merely intended, and one carrying `stateKey: GgState.doCommitKey`, because re-localizing rewrites the manifests and the recorded »everything is committed« hash covers them, (6) push. A repo the skip check leaves unpublished keeps its localized refs. Restore failures are yellow warnings, never publish failures. At the end of every successful run the ticket-level `didReview` is re-blessed (`TicketState.writeSuccess`).

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

## Hybrid packages

A hybrid publishes to pub.dev **and** npm, which the multi-repo flow feels in
four places:

- **`refVersions` carries both names.** A hybrid is `base_dna` to its Dart
  dependents and `@tssuite/base-dna` to its npm ones; registering one left the
  other ecosystem's constraint at the old version. `_publishedNames` returns one
  name per active registry (and falls back to the manifest — or directory — name
  for a repository without any registry, whose version still has to reach the
  dependents).
- **The sibling wait is per registry.** `_PublishedPackageState` carries a
  `PublishTarget` instead of a project type; a hybrid contributes one entry per
  registry, so a Dart dependent waits on pub.dev while an npm dependent waits on
  npm. Dispatching on the project type made a Dart dependent wait on npm and
  then resolve a version pub.dev had not seen yet.
- **`EnsureInRegistry` prompts per registry**, naming that registry's package
  and publish command. A hybrid that is on npm but was never released to pub.dev
  used to pass the gate and die inside `dart pub publish`.
- **The per-repo gate turns pana off** for a repository whose manifests
  disagree on the version, matching what gg_one does after it reconciles them
  (`gg_lang.hybridVersionsDiffer`).

`NpmRegistryChecker` resolves its status page from the merged `.npmrc`, so a
scoped package on a private feed no longer gets an npmjs.com link that 404s.
