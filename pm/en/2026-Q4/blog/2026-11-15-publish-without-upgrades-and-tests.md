<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Publish without upgrades and without tests

## Motivation

- `gg do publish` releases every repo of a ticket. Per repo it upgraded all
  dependencies (`dart pub upgrade --major-versions --tighten`) and then ran
  `gg can commit` again — analyze, format and the whole test suite
- Both cost most of the time of a publish, and both did work the publish
  did not need: the tests passed at the commit, and the upgrade changed
  dependencies the ticket never touched
- An upgrade at publish time also mixed versions nobody asked for into the
  release of a ticket — including major versions
- A publish should do only what has to happen at that moment: write the
  versions of the repos the run published, resolve, check that the code
  still compiles, merge, upload and tag

## Strategy

- Leave the upgrade out of `_publishRepo`; resolve with `dart pub get` or
  `<package manager> install` instead
- Replace `gg can commit` by gg_one_core's `Analyze`
- Keep everything else: the system commit, the per-repo `can publish` gate
  with pana, the push and gg_one's publish
- Prove with tests that no upgrade runs and get runs where upgrade ran

## Resolve instead of upgrading

- `_changeRefsToPubDev` points the references at the registry again and
  writes the versions this run published, then `_refreshDependencies`
  resolves — now with `dart pub get` (also the Dart side of a bridge repo)
- `dart pub get` keeps every locked version whose constraint still holds;
  only the constraints the run wrote make it move
- The resume path and the normal path resolve the same way now, so the
  parameters `refreshDart` and `includeDart` are gone
- The workspace restore after a release resolves with get as well
- gg_one's publish is still called with `upgrade: false`

## Analyze instead of testing again

- The sibling versions this run publishes are the very commits that were
  tested through the local references; what can still break is the
  resolution against the registry
- `Analyze` checks exactly that: the code compiles against the published
  versions. In a TypeScript repo it runs the lint script of `package.json`
- It runs in the `checks` slots of `_PublishLocks`, like the tests did
- The system commit still records `GgState.doCommitKey`, which is the hash
  `did commit` and the quick check on GitHub read
- The constructor takes `ggAnalyze` instead of `ggDoUpgradeDeps` and
  `ggCanCommit`

## Tests

- A failing `dart pub get` and a failing analysis fail the repo before
  anything irreversible happens, like a rejected gate
- A run resolves every repo twice — before the release and in the restore —
  and starts no process with `upgrade`
- The order within a repo is unlocalize, analyze, commit, gate, push,
  publish
- A resume skips the analysis of a repo with step progress, but resolves it

## Dependency updates

- No dependency changes the behavior here. gg_one's `do publish` no longer
  upgrades by default; this repo passes `upgrade: false` anyway

## Open Points

- No real ticket was published with this flow yet; the time it saves is
  still to be measured
- A test that compares the manifests of a real publish before and after is
  still open
