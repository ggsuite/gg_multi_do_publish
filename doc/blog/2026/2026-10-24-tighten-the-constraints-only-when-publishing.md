<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Tighten the constraints only when publishing

## Motivation

- `do publish` releases every repo of a ticket in dependency order
- Per repo it unlocalizes the references, propagates the versions
  published earlier in the run, upgrades the dependencies and re-verifies
  with `can commit` before the repo is published
- A release has to ship tightened constraints: the ones it was resolved
  and tested with
- The per-repo upgrade relied on `do upgrade deps` always tightening, but
  that no longer holds: inside a ticket, where `pubspec_overrides.yaml`
  points at local checkouts, pub crashed on `--tighten`
- The daily ticket flows now upgrade without tightening, so the publish
  has to ask for it, or a ticket would be released with loose lower bounds
- Besides, two tests failed in a shell with `NO_COLOR` set

## Strategy

- Tighten at the one point of the ticket where it is safe: per repo,
  after the references point at the registry again
- Pass the choice explicitly instead of relying on a default
- Document it as the only place a ticket's constraints are tightened
- Turn the colors on in tests that compare escape sequences

## Implementation 1: Tighten in the per-repo publish

- The per-repo upgrade now calls `do upgrade deps` with `tighten: true`,
  which runs `dart pub upgrade --major-versions --tighten`
- It runs after the unlocalization removed the overrides, so pub resolves
  against the registry, including the siblings published earlier in the
  same run
- The lower bounds are raised to published versions, so no impossible
  range can come up
- The repo's publish is still delegated with `upgrade: false`, so every
  repo is upgraded and tightened exactly once
- A resumed repo with publish progress skips the upgrade, as before
- README.md, CLAUDE.md and the code comment name this step as the only one
  of the ticket flow that tightens
- The upgrade mocks in the tests expect `tighten: true`

## Implementation 2: Check the colored messages under `NO_COLOR`

- `gg_console_colors` returns plain text when `NO_COLOR` is set or `TERM`
  is `dumb`
- Two tests compare escape sequences: the blue shell commands of
  `ensureInRegistry` and the output of a failed publish of one repo
- Both set `ggColorsEnabled = true` and reset it with `addTearDown`
- The tests now pass whether or not the shell disables colors

## Dependency updates

- `gg_one_commit`, through `gg_one`: `do upgrade deps` tightens only on
  request, with the new parameter `tighten`; its mock takes it, too
- `gg_multi_commit`: `do push`, `do review` and `do upgrade deps` upgrade
  without `--tighten`, so no constraint is tightened before the publish
- `dna_ggsuite` ^1.0.0 regenerated the guides, skills and `CLAUDE.md`
  block: a `/gg-review` skill, the rules to describe every repo in its own
  terms and to keep every repo in its scope and its `index.jsonc` current,
  and hooks that keep the prompts in the project management repo
- The routine upgrade raised `gg_multi_core`, `gg_one` and
  `pubspec_parse` to their current releases

## Result

- Tickets are released with tightened constraints, as before
- The tightening happens once per repo, against the registry

## Open Points

- The tightened constraints land in a `#gg:` commit after the review, so
  no reviewer sees them
- A problem the tightening brings in shows up only during the publish, in
  the `can commit` right after the upgrade, not in the daily flows
