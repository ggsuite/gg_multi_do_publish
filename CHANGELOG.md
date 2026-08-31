# Changelog

## Unreleased

### Fixed

- Fix Windows-specific test failures that blocked the review

## 4.1.1 - 2026-08-18

### Changed

- Use ggwsm in pipelines

### Fixed

- Fix issues in gg

## 4.1.0 - 2026-08-14

### Changed

- Rework copyright headers

### Fixed

- Cleanup copy right headers. Update to dart 3.13. Auto fixes.
- Cleanup copy right headers. Update to dart 3.13. Auto fixes. Setup quick-check pipeline.

## 4.0.0 - 2026-08-13

## 3.1.1 - 2026-08-11

### Changed

- Provide gg via npm
- Fix shell changes

## 3.1.0 - 2026-08-10

### Changed

- The publish state is kept per repository (`.gg/publish_state.json`); the ticket-wide `gg-publish.json` is only read for migration
- Refactor commit messages, version increment

## 3.0.1 - 2026-08-10

### Changed

- `do publish` turns gg_one's new dependency upgrade off (`upgrade: false`): the
ticket-wide flow already upgrades every repo in dependency order
- Make sure »dart pub upgrade --tighten --major-versions« is called before publishing

## 3.0.0 - 2026-08-10

## 2.4.2 - 2026-08-10

### Fixed

- Various log and color fixes across the gg command output
- Various fixes

## 2.4.1 - 2026-08-10

### Fixed

- Fix »gg do rm« issues

## 2.4.0 - 2026-08-10

### Changed

- Don't review skipped packages
- Merge origin/main

## 2.3.1 - 2026-08-10

### Removed

- Merge .ticket with ticket.json. Remove usage of .ticket

## 2.3.0 - 2026-08-09

### Changed

- Improve commit behavior
- Move gg commit conventions from gg_git to gg_one_core
- Answer gg did publish from git tags instead of a marker
- Move the git and process plumbing to gg_git
- Record the doCommit state in system commits again

## 2.2.0 - 2026-08-09

### Changed

- A hybrid is registered under **both** of its names when its version is
propagated — `base_dna` for its Dart dependents and `@tssuite/base-dna` for its
npm ones. Only one of them was recorded, so the other ecosystem's constraint
stayed at the old version.
- A dependent waits for the sibling on **its own** registry. The wait
dispatched on the project type, which reports any hybrid as TypeScript — so a
Dart dependent waited on npm and then resolved a version pub.dev had not seen
yet.
- The first-publish gate asks **per registry**, naming that registry's package
and publish command. A hybrid that is on npm but was never released to pub.dev
used to sail past the gate and die inside `dart pub publish`.
- The per-repo gate turns pana off for a repository whose two manifests
disagree on the version, matching what gg_one does after it reconciles them.
- The npm wait prints the status page of the **resolved** registry instead of
an npmjs.com link that is wrong for every scoped package on a private feed.
- Allow to publish hybrid packages

### Fixed

- A failure that is not an `Exception` is reported instead of being replaced by
a `NoSuchMethodError` — reading `.message` off a `TypeError` hid the real cause.

## 2.1.0 - 2026-08-08

### Added

- `--no-pana` for `can publish` and `do publish`: skips the pana analysis. It
travels through the `options` map of `DirCommand.exec` (`panaOption`).

## 2.0.0 - 2026-08-08

### Changed

- Allow to pass custom options to exec of dir commands.

## 1.0.1 - 2026-08-05

### Changed

- Make pana work: 1.0.0 changelog headings, examples, shorter description

## 1.0.0 - 2026-08-05

### Added

- Initial boilerplate.

### Changed

- Split gg_multi into multiple packages
