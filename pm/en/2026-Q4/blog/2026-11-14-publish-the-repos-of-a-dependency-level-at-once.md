<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Publish the repos of a dependency level at once

## Motivation

- `gg do publish` released the repos of a ticket strictly one after the
  other, in dependency order
- Most of a release is waiting: for the push, for the pull request and its
  merge, for the pipeline, for the registry
- A registry takes minutes to show a fresh upload. That wait was paid after
  every published repo, plus a flat 10 s settle delay, also for repos
  nothing later in the run resolves against
- The ticket-wide checks of `gg can publish` walked the repos one by one
- The tests asked registries for real. One of them took 29 of its 30
  seconds for an npm lookup

## Strategy

- Group the repos into dependency levels and publish the repos of a level
  at the same time: they need nothing from one another. A level starts when
  the one before is through
- Allow four releases at once, whatever the machine
- Put a lock around every step that repos side by side would spoil for each
  other
- Wait for a registry only where a later repo needs the upload, and wait
  for everything else once, at the end
- Never abandon a publish half way
- Keep the output as it was: repo by repo

## Level by level

- `_levels` groups the repos, which arrive in dependency order. A repo is
  one level above the highest level among the ticket repos it depends on,
  dev dependencies included, and on the first level when it depends on none
- Example: `b` and `c` depend on `a`, `d` depends on both. Then `a` is
  published first, `b` and `c` at the same time, `d` last
- `get()` runs each level through gg_one_core's `runInParallel`, which
  gg_one hands on
- How many at once is `GgParallelism.publishes`: four. A release pushes,
  opens or merges a pull request, starts a pipeline and uploads, and a host
  or registry limits what one client may do at once
- `GG_PARALLEL=n` lowers the number. `GG_PARALLEL=1` publishes one repo
  after the other, level by level
- The work per repo is the closure `processRepo`: publish, skip or »already
  published«, then the version capture

## What stays one at a time

- `_PublishLocks` holds three kinds of slots
- `workspace`, one slot: unlocalizing the references, `pub upgrade` and the
  whole workspace restore. These steps read and write the repos next to
  them and the package cache
- `terminal`, one slot: the first-publish question of `EnsureInRegistry`
  and the upload, where npm asks for a one-time password. gg_one takes the
  lock as `uploadExclusivelyOption`
- The first-publish question is logged through the log of the run. The log
  of a repo is held back while a repo before it is under way, and a
  question waiting in there would be invisible
- `checks`: `gg can commit` and pana are heavy and share the heavy slots of
  the machine (`TaskSlots.heavy()`). Four releases on a small machine still
  run one test suite at a time
- A repo that is checked on its own gets the whole machine for its tests.
  That is the usual case, most levels hold one repo
- Side by side run the pushes, the pull request with its wait for the
  merge, the wait for the registry and the tag

## A failing repo

- It does not stop the repos of its level that are under way
  (`cancelOnError: false`). They finish and are recorded `published`
- The failed repo is recorded `failed` and restored as before
- No further repo starts, and the failure of the first failed repo ends the
  run before the next level
- `--continue` publishes exactly the repos that are not `published`

## Waiting for the registries only where needed

- The loop asks per repo whether a repo published later in the run depends
  on it, directly or through other ticket repos (`_allDependencies`)
- Only then gg_one's publish waits for the registry
  (`waitUntilPublishedOption: true`). The settle delay follows once for the
  whole level
- For every other repo the option is `false`. Step 6b waits for all
  released versions at once after the last level
  (`_waitForPublishedPackages`)
- A version that does not show up in time fails the run before the ticket
  is closed. Every repo is marked `published` then, and `--continue` only
  waits again
- Before a level starts, the registries have to show the packages its
  publishing repos depend on: every package once, all at the same time

## Ticket-wide checks for all repos at once

- `CanPublishCommand.checkTicket` runs `dart pub get --offline`,
  `git status`, `can merge` and the npm login for all repos at the same
  time
- They are logged repo by repo as before. Every repo is checked even when
  another one fails, and the failures are reported together

## Tests without a real registry

- The tests of `do publish` ask no registry for real any more
- New tests cover several repos of a level: published at the same time, one
  after the other with `GG_PARALLEL=1`, a failing repo, the first-publish
  question, the heavy slots and one upload at a time

## Open Points

- Publishing level by level has unit tests but no real publish behind it
  yet. It was never run against a real host and registry, so there are no
  measured times
- Uploads stay one at a time, because of the one-time password of npm
- Most levels hold one repo. Such a ticket gains from the shorter registry
  waits, not from the levels
