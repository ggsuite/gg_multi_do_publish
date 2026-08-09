// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_publish/gg_publish.dart';
import 'package:mocktail/mocktail.dart';

/// Typedef for reading one line from stdin (for injection & tests).
typedef ReadLineFromStdIn = String? Function();

/// Makes sure at least one version of a repo's package is available on its
/// registry (pub.dev for Dart/Flutter, npm for TypeScript) before the repo
/// is published.
///
/// A first-time publish has to be done manually by the user: it settles
/// authentication, access rights and the package creation directly with the
/// registry. When the package was never published, the shell commands to
/// execute are shown and the publish continues once the user confirmed and
/// the package became visible on the registry. Repos without a public
/// registry (`publish_to: none`, `private: true` or no manifest at all) are
/// skipped.
class EnsureInRegistry {
  /// Constructor.
  EnsureInRegistry({
    required GgLog ggLog,
    IsInRegistry? isInRegistry,
    LanguageCatalog? catalog,
    ReadLineFromStdIn? readLineFromStdIn,
    gg.HasTerminal? hasTerminal,
  }) : _isInRegistry = isInRegistry ?? IsInRegistry(ggLog: ggLog),
       _catalog = catalog,
       _readLineFromStdIn = readLineFromStdIn ?? stdin.readLineSync,
       _hasTerminal = hasTerminal ?? gg.defaultHasTerminal;

  /// Checks whether the package has at least one version on its registry.
  final IsInRegistry _isInRegistry;

  /// The language catalog used to read the manifest. Defaults to the
  /// bundled gg_lang catalog when null.
  final LanguageCatalog? _catalog;

  /// Reads the user's confirmation from stdin.
  final ReadLineFromStdIn _readLineFromStdIn;

  /// Whether stdin is attached to a terminal.
  final gg.HasTerminal _hasTerminal;

  // ...........................................................................
  /// Makes sure the repo in [directory] has at least one version on its
  /// registry. When it has not, the user is asked to publish the first
  /// version manually directly out of [directory]; the method returns once
  /// the package became visible on the registry. Throws when the user
  /// aborts or when no terminal is attached.
  Future<void> ensure({
    required Directory directory,
    required GgLog ggLog,
  }) async {
    final missing = await _isInRegistry.missingTargets(directory: directory);

    // Repos without a public registry (null) need no first version; repos
    // whose registries all carry a version (empty) neither.
    if (missing == null || missing.isEmpty) {
      return;
    }

    // The first publish is an interactive decision of the user — fail fast
    // in headless runs instead of hanging on the prompt.
    gg.throwWhenNotATerminal(
      'the first-publish prompt',
      'publish the first version of the package manually before running '
          '"gg multi do publish"',
      hasTerminal: _hasTerminal,
    );

    // Each registry is asked about separately: a hybrid that already lives on
    // npm but was never released to pub.dev needs exactly one prompt, naming
    // the pub.dev package and the »dart pub publish« command.
    for (final target in missing.ordered) {
      await _promptFor(directory: directory, ggLog: ggLog, target: target);
    }
  }

  // ...........................................................................
  /// Asks the user to publish the first version to [target] manually and
  /// returns once it became visible there.
  Future<void> _promptFor({
    required Directory directory,
    required GgLog ggLog,
    required PublishTarget target,
  }) async {
    final name = await _packageName(directory, target);

    ggLog(
      cWarn(
        '»$name« has no version published on ${target.id} yet.\n'
        'Please publish the first version manually directly out of the '
        'current working folder:',
      ),
    );
    ggLog(cCmd('  cd ${directory.absolute.path}'));
    ggLog(cCmd('  ${await _publishCommand(directory, target)}'));

    while (true) {
      ggLog(
        cAction('Press ⏎ once the package is published, »q« + ⏎ to abort.'),
      );
      final answer = (_readLineFromStdIn() ?? '').trim().toLowerCase();
      if (answer == 'q') {
        throw Exception(
          cError('Publishing aborted: »$name« has no version on ${target.id}.'),
        );
      }

      final missingNow = await _isInRegistry.missingTargets(
        directory: directory,
      );
      if (missingNow == null || !missingNow.contains(target)) {
        ggLog(cDetail('»$name« is now available on ${target.id}. Continuing.'));
        return;
      }

      ggLog(
        cWarn(
          '»$name« is not yet visible on ${target.id}. A fresh publish can '
          'take a few minutes to appear. Please try again.',
        ),
      );
    }
  }

  // ######################
  // Private
  // ######################

  // ...........................................................................
  /// The shell command the user executes to publish the repo in [directory]
  /// to [target] manually. pub.dev uses the catalog's publish command, npm
  /// uses pnpm.
  Future<String> _publishCommand(
    Directory directory,
    PublishTarget target,
  ) async {
    final catalog = _catalog ?? await LanguageCatalog.load();
    if (target == PublishTarget.pubDev) {
      return target.specIn(directory, catalog).command('publish').label;
    }

    // A scoped package is private by default on npm — the first publish is
    // rejected without »--access public«. »--no-git-checks« is needed
    // because the repo sits on its ticket feature branch.
    final name = await _packageName(directory, target);
    final access = name.startsWith('@') ? ' --access public' : '';
    return 'pnpm publish --no-git-checks$access';
  }

  // ...........................................................................
  /// The name the package of [directory] carries on [target] — `foo` on
  /// pub.dev, the possibly scoped `@org/foo` on npm. Naming the wrong one in a
  /// prompt is how a user ends up pasting the wrong command.
  Future<String> _packageName(Directory directory, PublishTarget target) async {
    final catalog = _catalog ?? await LanguageCatalog.load();
    return target.manifestIn(directory, catalog).readName();
  }
}

/// Mock for [EnsureInRegistry]
class MockEnsureInRegistry extends Mock implements EnsureInRegistry {}
