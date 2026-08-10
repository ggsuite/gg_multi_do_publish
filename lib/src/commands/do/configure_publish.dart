// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
// ignore: lines_longer_than_80_chars
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_publish/gg_publish.dart' show PublishedVersion;
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/gg_multi_core.dart';

/// Interactively builds the `.gg/gg-publish.json` publish configuration for
/// the current ticket, asking for the version increment and merge message of
/// every repo that needs a release.
///
/// The questions belong to `gg do review` — it asks them for exactly the repos
/// it opens a pull request for, and stores the answers here. This command is
/// the way to (re-)write that configuration by hand; `do publish` falls back to
/// it when no configuration exists at all.
///
/// A repo `PublishSkipCheck` finds unchanged is **not** asked: it is not
/// released, so an increment and a merge message for it would be answers to a
/// question nobody asks.
///
/// `--message` pre-fills every repo's merge-message prompt and is used for a
/// prompt that is left empty. `--merge-only` configures a
/// `gg do publish --merge-only` run: no version increment is asked for,
/// because a merge releases nothing.
class DoConfigurePublishCommand extends DirCommand<void> {
  /// Constructor
  DoConfigurePublishCommand({
    required super.ggLog,
    super.name = 'configure-publish',
    super.description = 'Create the publish configuration of the ticket',
    SortedProcessingList? sortedProcessingList,
    PublishedVersion? publishedVersion,
    gg.VersionSelector? versionSelector,
    EditMessage? editMessage,
    PublishSkipCheck? publishSkipCheck,
    PublishPlanner? publishPlanner,
  }) : _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _publishPlanner =
           publishPlanner ??
           PublishPlanner(
             ggLog: ggLog,
             publishedVersion: publishedVersion,
             versionSelector: versionSelector,
             editMessage: editMessage,
             publishSkipCheck: publishSkipCheck,
             // Asking is the whole point of this command, so it never checks
             // the terminal itself. A headless run still fails fast — inside
             // the prompts, whose errors name the very file this command
             // writes.
             hasTerminal: () => true,
           ) {
    _addArgs();
  }

  /// Collects the repos of a ticket in dependency order.
  final SortedProcessingList _sortedProcessingList;

  /// Decides which repos need a release and asks their publish questions.
  final PublishPlanner _publishPlanner;

  /// Returns the `.gg/gg-publish.json` file for [ticketDir] — the file
  /// `gg do review` writes the answers to and `gg do publish` reads them from.
  static File configFileFor(Directory ticketDir) =>
      publishConfigFileFor(ticketDir);

  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    await configure(
      directory: directory,
      ggLog: ggLog,
      defaultMergeMessage: argResults?['message'] as String?,
      mergeOnly: argResults?['merge-only'] as bool? ?? false,
    );
  }

  /// Builds the publish configuration for the ticket containing [directory],
  /// writes it to `<ticket>/.gg/gg-publish.json` and returns it.
  ///
  /// [defaultMergeMessage] (typically from `-m`) is the default merge message:
  /// it pre-fills every repo's merge-message prompt and is the fallback when
  /// the prompt is left empty. It takes precedence over the ticket
  /// description; a generic `Publish <repo>` is used only when both are empty.
  ///
  /// [mergeOnly] configures a `gg do publish --merge-only` run: it releases
  /// nothing, so no version increment is asked for and none is stored.
  ///
  /// Every question is asked afresh — that is what running this command means.
  /// The answers of an existing configuration are therefore *not* reused; a
  /// file still carrying the progress markers of an unfinished publish is the
  /// one thing that stops the run, because rewriting it would discard them.
  Future<gg.PublishConfig> configure({
    required Directory directory,
    required GgLog ggLog,
    String? defaultMergeMessage,
    bool mergeOnly = false,
  }) async {
    final String? ticketPath = WorkspaceUtils.detectTicketPath(
      path.absolute(directory.path),
    );
    if (ticketPath == null) {
      throw Exception(cDetail('Not inside a ticket folder'));
    }

    final ticketDir = Directory(ticketPath);

    // Never clobber the progress of an unfinished publish — rewriting the
    // file would silently discard the per-repo status markers, so a later
    // `--continue` would re-publish repos that already released.
    final existingFile = configFileFor(ticketDir);
    if (existingFile.existsSync()) {
      final existing = gg.PublishConfig.load(
        configArg: existingFile.path,
        fallbackDir: ticketDir.path,
      );
      if (existing.repos.values.any((r) => r.status != null)) {
        throw Exception(
          cError(
            gg.unfinishedPublishMessage(
              path: existingFile.path,
              command: 'gg do publish',
            ),
          ),
        );
      }
    }

    final subs = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );
    if (subs.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
    }

    final plan = await _publishPlanner.plan(
      ticketDir: ticketDir,
      subs: subs,
      ggLog: ggLog,
      mergeOnly: mergeOnly,
      defaultMergeMessage: defaultMergeMessage,
      wording: mergeOnly
          ? PublishPlanWording.merge
          : PublishPlanWording.publish,
    );

    // Whether the ticket is cleaned up is no longer a question: `do publish`
    // always moves the published repos to <root>/.trash and removes the
    // ticket folder, so nothing is asked and nothing is stored here.
    await plan.config.save(file: configFileFor(ticketDir));
    // Where the answers are stored is an implementation detail of the
    // publish — the user just answered the questions and does not need a
    // path back.
    return plan.config;
  }

  /// Adds command line arguments.
  void _addArgs() {
    argParser.addOption(
      'message',
      abbr: 'm',
      help: 'Default merge message for every repo prompt',
    );
    argParser.addFlag(
      'merge-only',
      help: 'Configure a merge-only run, without increments',
      defaultsTo: false,
      negatable: false,
    );
  }
}

/// Mock for [DoConfigurePublishCommand]
class MockDoConfigurePublishCommand extends MockDirCommand<void>
    implements DoConfigurePublishCommand {}
