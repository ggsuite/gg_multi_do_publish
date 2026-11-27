<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Use ReadSettings from gg_multi_core

## Motivation

- `do publish` reads `~/.gg_rc` to decide whether the ticket cleanup
  question is asked at all (`do.publish.askTicketCleanup`). The reader is
  injected, so tests never touch the real file.
- For that argument the package declared its own function type in
  `lib/src/commands/do/publish.dart`:
  `typedef ReadSettings = GgRc Function({required GgLog ggLog});`
- The library exports that file, so the type was part of the public API.
  Another package declared the identical type under the same name. To
  Dart these are two different declarations, and a library that exported
  both no longer compiled:
  `'ReadSettings' is exported from both …`
- The type describes how `GgRc` is loaded, so it belongs to gg_multi_core,
  where `GgRc` lives.

## Strategy

- Use the `ReadSettings` gg_multi_core declares now, next to `GgRc`
- Delete the own declaration
- Keep the name available to the users of this package: the library
  re-exports the one of gg_multi_core
- Change no behavior

## Implementation 1: the type

- `publish.dart` lost its typedef. It already imports
  `package:gg_multi_core/gg_multi_core.dart`, which provides the type, so
  `DoPublishCommand(readSettings: …)` and the field `_readSettings` keep
  their type
- The tests import gg_multi_core already and needed no change

## Implementation 2: the export

- `lib/gg_multi_do_publish.dart` re-exports the type:

  ```dart
  // Moved to gg_multi_core; still exported for the users of this package.
  export 'package:gg_multi_core/gg_multi_core.dart' show ReadSettings;
  ```

- Code that imports `ReadSettings` from this package keeps compiling
- A library that exports this package together with another one that
  re-exports the same type compiles too: both names now point to the same
  declaration

## Dependency updates

- gg_multi_core `^4.18.0`: the first version that declares `ReadSettings`
- `gg_process` `^1.4.1` and `dna_ggsuite` `^1.0.2`, tightened by the
  regular dependency upgrade

## Result

- Same behavior, same public names, one declaration of the type
- Released as a patch version

## Open Points

- None
