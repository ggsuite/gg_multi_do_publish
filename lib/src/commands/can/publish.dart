// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_multi_commit/gg_multi_commit.dart';

/// Command to check if all repos in the ticket can be published.
class CanPublishCommand extends DirCommand<void> {
  /// Constructor
  CanPublishCommand({
    required super.ggLog,
    super.name = 'publish',
    super.description = 'Check if all ticket repos can be published',
    gg.CanCommit? ggCanCommit,
    gg.CanMerge? ggCanMerge,
    gg.CanPublish? ggCanPublish,
    gg.NpmLoggedIn? ggNpmLoggedIn,
    gg.PubGetOffline? ggPubGetOffline,
    SortedProcessingList? sortedProcessingList,
    ProcessRunner? processRunner,
    DidCommitCommand? didCommitCommand,
    DoPushCommand? doPushCommand,
  }) : _ggCanMerge = ggCanMerge ?? gg.CanMerge(ggLog: ggLog),
       _ggCanPublish = ggCanPublish ?? gg.CanPublish(ggLog: ggLog),
       _ggNpmLoggedIn = ggNpmLoggedIn ?? gg.NpmLoggedIn(ggLog: ggLog),
       _ggPubGetOffline = ggPubGetOffline ?? gg.PubGetOffline(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _processRunner = processRunner ?? defaultProcessRunner,
       _didCommitCommand = didCommitCommand ?? DidCommitCommand(ggLog: ggLog),
       _doPushCommand = doPushCommand ?? DoPushCommand(ggLog: ggLog) {
    _addArgs();
  }

  /// Instance of gg CanMerge
  final gg.CanMerge _ggCanMerge;

  /// Instance of gg CanPublish (per-repo publish readiness, incl. npm auth)
  final gg.CanPublish _ggCanPublish;

  /// Instance of gg NpmLoggedIn (ticket wide npm authentication check)
  final gg.NpmLoggedIn _ggNpmLoggedIn;

  /// Instance of gg PubGetOffline (syncs the lock file with the manifest)
  final gg.PubGetOffline _ggPubGetOffline;

  /// Instance of SortedProcessingList
  final SortedProcessingList _sortedProcessingList;

  /// The process runner
  final ProcessRunner _processRunner;

  /// Instance of DidCommitCommand
  final DidCommitCommand _didCommitCommand;

  /// Instance of DoPushCommand
  final DoPushCommand _doPushCommand;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
    Map<String, dynamic> options = const {},
  }) => get(
    directory: directory,
    ggLog: ggLog,
    verbose: verbose,
    pana: options[gg.panaOption] as bool?,
  );

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
    bool? pana,
  }) => checkTicket(
    directory: directory,
    ggLog: ggLog,
    verbose: verbose,
    pana: pana,
  );

  /// Runs the ticket wide publish readiness checks for [directory].
  ///
  /// [includeCanPublish] controls the last step, `gg can publish` per repo.
  /// `gg can publish` runs it — that is the default. `gg do publish` passes
  /// `false` and calls [checkRepo] per repo instead: only there are the refs
  /// unlocalized and the dependencies published earlier in the same run
  /// already on their registry, so pana can resolve them.
  ///
  /// [pana] turns the pana analysis inside `gg can publish` off; it defaults to
  /// `--[no-]pana` from the command line, which in turn defaults to running it.
  Future<void> checkTicket({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
    bool? pana,
    bool includeCanPublish = true,
  }) async {
    verbose ??= argResults?['verbose'] as bool? ?? false;
    pana ??= _panaFromArgs;

    // Step 1: Detect ticket folder -----------------------------------------
    final String? ticketPath = WorkspaceUtils.detectTicketPath(
      path.absolute(directory.path),
    );
    if (ticketPath == null) {
      ggLog(cAction('Please run this command inside a ticket folder.'));
      throw Exception(cDetail('Not inside a ticket folder'));
    }

    final ticketDir = Directory(ticketPath);

    // Get sorted repos ------------------------------------------------------
    final subs = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );

    if (subs.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
      return;
    }

    // Only show task logs when verbose is enabled ---------------------------
    final GgLog taskLog = verbose ? ggLog : <String>[].add;

    // Step 2: Sync the lock files with their manifests so the next check does
    // not trip over a lockfile that is merely out of date -------------------
    await GgStatusPrinter<void>(
      message: 'dart pub get --offline',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _pubGetOffline(subs: subs, ggLog: taskLog));

    // Step 3: Check for uncommitted changes ---------------------------------
    await GgStatusPrinter<void>(
      message: 'Uncommitted changes?',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _checkUncommittedChanges(subs: subs, ggLog: taskLog));

    // Step 4: Run gg_multi did commit ------------------------------------
    await GgStatusPrinter<void>(
      message: 'Did commit?',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _runDidCommit(ticketDir: ticketDir, ggLog: taskLog));

    // Step 5: Run gg_multi do push ------------------------------------------
    // The push merges the main branches into the feature branches and brings
    // every repo onto the remote — there is no separate merge step anymore.
    await GgStatusPrinter<void>(
      message: 'Running do push',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _runDoPush(ticketDir: ticketDir, ggLog: taskLog));

    // Step 6: Run gg can merge per repo -------------------------------------
    await GgStatusPrinter<void>(
      message: 'Can merge?',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _checkCanMerge(subs: subs, ggLog: taskLog));

    // Step 7: Check the npm authentication ----------------------------------
    // This is the one publish blocker that has nothing to do with dependency
    // resolution, so it stays ticket wide even when step 8 is deferred to
    // `do publish`'s per-repo gate: finding out about a missing npm login
    // after the first packages went to a registry is the worst failure mode
    // this command has. Repos not publishing to npm are skipped by gg_one.
    await GgStatusPrinter<void>(
      message: 'Logged in to npm?',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _checkNpmLoggedIn(subs: subs, ggLog: taskLog));

    // Step 8: Run gg can publish per repo -----------------------------------
    // Verifies each repo's publish readiness (feature branch, CHANGELOG,
    // pana, npm authentication).
    if (includeCanPublish) {
      await GgStatusPrinter<void>(
        message: 'Can publish?',
        ggLog: ggLog,
        dark: true,
      ).run(
        () async => _checkCanPublish(subs: subs, ggLog: taskLog, pana: pana!),
      );
    }

    // All successful --------------------------------------------------------
    ggLog('\nAll repos can be published\n');
  }

  /// Checks whether the single repository [directory] can be published.
  ///
  /// Covers the same ground as the ticket wide `Can publish?` step — feature
  /// branch, no path overrides, CHANGELOG format, committed changes, pana and
  /// npm authentication — for one repo, and throws the same
  /// `Cannot publish: <repo> (<reason>)` exception.
  ///
  /// [directory] is a repository, not a ticket folder. The caller decides how
  /// verbose the output is: `gg do publish` passes its own `ggLog`, because a
  /// rejection here is what makes the run fail.
  Future<void> checkRepo({
    required Directory directory,
    required GgLog ggLog,
    bool? pana,
  }) async {
    final failure = await _canPublishFailure(
      repoDir: directory,
      ggLog: ggLog,
      pana: pana ?? _panaFromArgs,
    );
    if (failure != null) {
      throw Exception(_failureMessage('Cannot publish.', [failure]));
    }
  }

  /// Runs `dart pub get --offline` (or the Flutter equivalent) in all repos so
  /// that each lock file matches its manifest before the uncommitted-changes
  /// check runs.
  ///
  /// [gg.PubGetOffline] self-gates on the presence of a `pubspec.yaml`: pure
  /// TypeScript repos are skipped, while bridge repos (pubspec.yaml +
  /// package.json) do carry a Dart `pubspec.lock` that must be kept in sync.
  /// So run it for every repo and let it self-gate — the same way `can review`
  /// does.
  Future<void> _pubGetOffline({
    required List<Node> subs,
    required GgLog ggLog,
  }) async {
    for (final repo in subs) {
      await _ggPubGetOffline.exec(directory: repo.directory, ggLog: ggLog);
    }
  }

  /// Checks for uncommitted changes in all repos.
  ///
  /// A repo whose *only* dirty files are lock files is not reported: lock
  /// files are tracked but derived, and a `pub get` running in the background
  /// — the Dart VS Code extension fires one whenever a manifest is written —
  /// rewrites them without anybody editing anything. Refusing to publish over
  /// that was the whole problem. The drift is committed instead, which is what
  /// the later `IsCommitted` of `gg do push` needs to see.
  Future<void> _checkUncommittedChanges({
    required List<Node> subs,
    required GgLog ggLog,
  }) async {
    final uncommitted = <String>[];
    for (final repo in subs) {
      final repoDir = repo.directory;
      final result = await _processRunner('git', [
        'status',
        '--porcelain',
      ], workingDirectory: repoDir.path);
      final status = result.stdout.toString().trim();
      if (status.isEmpty) {
        continue;
      }

      if (gg.isLockFileOnlyDrift(status)) {
        await _commitLockFileDrift(
          repoDir: repoDir,
          lockFiles: gg.lockFilesInStatus(status),
          ggLog: ggLog,
        );
        continue;
      }

      uncommitted.add(path.basename(repoDir.path));
    }
    if (uncommitted.isNotEmpty) {
      ggLog(cWarn('Uncommitted changes in'));
      for (final name in uncommitted) {
        ggLog(cDetail(' - $name'));
      }
      throw Exception(cDetail('Uncommitted changes found.'));
    }
  }

  /// Stages and commits [lockFiles] of [repoDir] as `#gg: Update <files>`.
  ///
  /// The `#gg: ` prefix keeps `PublishSkipCheck` treating the commit as
  /// generated, and lock files are part of its gg-owned allowlist, so this
  /// never makes an otherwise unchanged repo look like it needs a release.
  /// The recorded check results survive as well: `GgState.ignoreFiles` holds
  /// the lock files, so the state hash is the same before and after.
  Future<void> _commitLockFileDrift({
    required Directory repoDir,
    required List<String> lockFiles,
    required GgLog ggLog,
  }) async {
    final repoName = path.basename(repoDir.path);
    final files = lockFiles.join(', ');

    await _processRunner('git', [
      'add',
      '--',
      ...lockFiles,
    ], workingDirectory: repoDir.path);
    final result = await _processRunner('git', [
      'commit',
      '-m',
      '${gg.ggCommitPrefix}Update $files',
      // The pathspec belongs on the commit as well, not only on the »add«:
      // without it the commit takes whatever else the index already holds.
      '--',
      ...lockFiles,
    ], workingDirectory: repoDir.path);

    if (result.exitCode != 0) {
      throw Exception(
        cError('Could not commit $files in $repoName: ${result.stderr}'),
      );
    }

    ggLog(cDetail('Committed lock file drift in $repoName: $files'));
  }

  /// Executes gg_multi did commit for the ticket.
  Future<void> _runDidCommit({
    required Directory ticketDir,
    required GgLog ggLog,
  }) async {
    try {
      await _didCommitCommand.exec(directory: ticketDir, ggLog: ggLog);
    } catch (e) {
      ggLog([cDetail('✗ Not committed'), cError(rmControls('$e'))].join('\n'));
      throw Exception(cDetail('Not committed.'));
    }
  }

  /// Executes gg_multi do push for the ticket — it merges the main branches
  /// into the feature branches and pushes every repo.
  Future<void> _runDoPush({
    required Directory ticketDir,
    required GgLog ggLog,
  }) async {
    try {
      // upgrade: false — `do publish` upgrades every repo again right before
      // it is published, after its refs point at the registry. Upgrading
      // here as well would only run »dart pub upgrade« twice per repo.
      await _doPushCommand.exec(
        directory: ticketDir,
        ggLog: ggLog,
        upgrade: false,
      );
    } on MergeConflictException {
      // The exception carries the actionable conflict report and the
      // half-merged working tree must survive — pass it through unwrapped.
      rethrow;
    } catch (e) {
      ggLog([cDetail('✗ Failed to push'), cError(rmControls('$e'))].join('\n'));
      throw Exception(cDetail('Failed to push.'));
    }
  }

  /// Runs gg can publish for the repository [repoDir].
  ///
  /// Returns `null` when the repo is publish-ready, otherwise the
  /// `<repo> (<error>)` description the failure is reported with. One code
  /// path for the ticket wide check and for [checkRepo], so the two cannot
  /// report the same problem differently.
  Future<String?> _canPublishFailure({
    required Directory repoDir,
    required GgLog ggLog,
    required bool pana,
  }) async {
    final repoName = path.basename(repoDir.path);
    ggLog('\n${cH1(repoName)}');
    try {
      await _ggCanPublish.exec(
        directory: repoDir,
        ggLog: ggLog,
        options: <String, dynamic>{gg.panaOption: pana},
      );
      return null;
    } catch (e) {
      // The reason is printed once, right under the repo it belongs to —
      // but that log is silent without --verbose, so it travels on with the
      // repo name as well.
      ggLog([cDetail('✗ Cannot publish'), cError(rmControls('$e'))].join('\n'));
      return '$repoName: ${_reasonOf(e)}';
    }
  }

  /// Runs gg can publish for every repository in the ticket, collecting the
  /// repos that are not publish-ready (e.g. not logged in to npm).
  Future<void> _checkCanPublish({
    required List<Node> subs,
    required GgLog ggLog,
    required bool pana,
  }) async {
    final failedRepos = <String>[];
    for (final repo in subs) {
      final failure = await _canPublishFailure(
        repoDir: repo.directory,
        ggLog: ggLog,
        pana: pana,
      );
      if (failure != null) {
        failedRepos.add(failure);
      }
    }
    if (failedRepos.isNotEmpty) {
      ggLog(cAction('\nPlease fix the issues above.\n'));
      throw Exception(_failureMessage('Cannot publish.', failedRepos));
    }
  }

  // ...........................................................................
  /// The summary line plus one indented line per failing repo, all in
  /// [cDetail].
  ///
  /// The per-repo detail is logged to the task log, which is silent without
  /// `--verbose` — so the reason has to travel in the exception too, or the
  /// user is left with a bare »Cannot merge.« and no way to act on it.
  static String _failureMessage(String summary, List<String> failures) =>
      cDetail([summary, ...failures.map((f) => '  - $f')].join('\n'));

  // ...........................................................................
  /// The human-readable part of [error] — an `Exception`'s message, with the
  /// color codes and the »Exception: « prefix removed.
  static String _reasonOf(Object error) {
    var reason = rmControls('$error').trim();
    const prefix = 'Exception: ';
    if (reason.startsWith(prefix)) {
      reason = reason.substring(prefix.length).trim();
    }
    return reason;
  }

  /// Checks the npm authentication of every repository in the ticket.
  ///
  /// gg_one skips every repository that does not publish to npm, so only the
  /// ones that really need the credentials can fail here. Which those are has
  /// to be in the exception: a ticket mixes pub.dev, npm and registry-less
  /// repos, and a bare »Not logged in to npm.« reads like the check fired for
  /// a package that publishes nowhere near npm — the per-repo reason below
  /// goes to the task log, which is silent without `--verbose`.
  Future<void> _checkNpmLoggedIn({
    required List<Node> subs,
    required GgLog ggLog,
  }) async {
    final failedRepos = <String>[];
    for (final repo in subs) {
      final repoDir = repo.directory;
      final repoName = path.basename(repoDir.path);
      ggLog('\n${cH1(repoName)}');
      try {
        await _ggNpmLoggedIn.exec(directory: repoDir, ggLog: ggLog);
      } catch (e) {
        ggLog(
          [
            cDetail('✗ Not logged in to npm'),
            cError(rmControls('$e')),
          ].join('\n'),
        );
        failedRepos.add('$repoName: ${_reasonOf(e)}');
      }
    }
    if (failedRepos.isNotEmpty) {
      ggLog(cAction('\nPlease fix the issues above.\n'));
      throw Exception(_failureMessage('Not logged in to npm.', failedRepos));
    }
  }

  /// Runs gg can merge for every repository in the ticket.
  Future<void> _checkCanMerge({
    required List<Node> subs,
    required GgLog ggLog,
  }) async {
    final failures = <String>[];
    for (final repo in subs) {
      final repoDir = repo.directory;
      final repoName = path.basename(repoDir.path);
      ggLog('\n${cH1(repoName)}');
      try {
        await _ggCanMerge.exec(directory: repoDir, ggLog: ggLog);
      } catch (e) {
        ggLog([cDetail('✗ Cannot merge'), cError(rmControls('$e'))].join('\n'));
        failures.add('$repoName: ${_reasonOf(e)}');
      }
    }
    if (failures.isNotEmpty) {
      ggLog(cAction('\nPlease fix the issues above.\n'));
      throw Exception(_failureMessage('Cannot merge.', failures));
    }
  }

  /// Whether `--[no-]pana` was given; pana runs unless it was turned off.
  bool get _panaFromArgs => argResults?[gg.panaOption] as bool? ?? true;

  // Adds command line arguments
  void _addArgs() {
    argParser.addFlag(
      gg.panaOption,
      help: 'Run »dart run pana« as part of »gg can publish«.',
      defaultsTo: true,
      negatable: true,
    );

    argParser.addFlag(
      'verbose',
      abbr: 'v',
      help: 'Show detailed log output.',
      defaultsTo: false,
      negatable: true,
    );
  }
}

/// Mock for [CanPublishCommand]
class MockCanPublishCommand extends MockDirCommand<void>
    implements CanPublishCommand {}
