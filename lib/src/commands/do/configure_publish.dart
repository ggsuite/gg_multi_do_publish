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
import 'package:gg_publish/gg_publish.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

import 'package:gg_multi_core/gg_multi_core.dart';

/// Typedef for editing a merge message interactively.
typedef EditMessage = Future<String?> Function(String initialMessage);

/// Interactively builds the `.gg/gg-publish.json` publish configuration for
/// the current ticket, asking for the version increment and merge message of
/// every repo up front. `do publish` runs this automatically when no
/// configuration is supplied, so all decisions are made before the long
/// (unattended) publish starts.
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
  }) : _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _publishedVersion = publishedVersion ?? PublishedVersion(ggLog: ggLog),
       _versionSelector = versionSelector ?? gg.VersionSelector(),
       _editMessage = editMessage ?? _defaultEditMessage {
    _addArgs();
  }

  /// Collects the repos of a ticket in dependency order.
  final SortedProcessingList _sortedProcessingList;

  /// Reads the version a repo last published to its registry.
  final PublishedVersion _publishedVersion;

  /// Lets the user pick the version increment (patch/minor/major) per repo.
  final gg.VersionSelector _versionSelector;

  /// Opens an interactive editor for a repo's merge message.
  final EditMessage _editMessage;

  /// Returns the `.gg/gg-publish.json` file for [ticketDir].
  static File configFileFor(Directory ticketDir) =>
      File(path.join(ticketDir.path, '.gg', 'gg-publish.json'));

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

    final ticketDescription = readTicketDescription(ticketDir);

    // The merge-message seed: an explicit `-m` wins, otherwise the ticket
    // description. It pre-fills the per-repo prompt and is the fallback when
    // the user clears it (the config model rejects an empty merge message).
    final trimmedDefault = defaultMergeMessage?.trim();
    final seedMessage = (trimmedDefault != null && trimmedDefault.isNotEmpty)
        ? trimmedDefault
        : (ticketDescription ?? '');

    final subs = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );
    if (subs.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
    }

    final repos = <String, gg.RepoOverride>{};
    for (final repo in subs) {
      final repoDir = repo.directory;
      final repoName = path.basename(repoDir.path);
      ggLog('\n${cH1(repoName)}');

      // A merge-only run releases nothing — no version bump, no changelog
      // heading, no tag. Asking for an increment would offer a version that
      // is never created, so the prompt is skipped and none is stored.
      final increment = mergeOnly
          ? null
          : await _versionSelector.selectIncrement(
              currentVersion: await _currentVersion(repoDir),
            );
      // A merge message must never be empty (the config model rejects it), so
      // fall back to the seed (-m or ticket description) and finally a generic
      // default.
      var message = (await _editMessage(seedMessage) ?? '').trim();
      if (message.isEmpty) {
        message = seedMessage;
      }
      if (message.isEmpty) {
        message = 'Publish $repoName';
      }

      repos[repoName] = gg.RepoOverride(
        versionIncrement: increment?.name,
        mergeMessage: message,
      );
    }

    // Whether the ticket is cleaned up is no longer a question: `do publish`
    // always moves the published repos to <root>/.trash and removes the
    // ticket folder, so nothing is asked and nothing is stored here.
    final config = gg.PublishConfig(repos: repos);
    final file = configFileFor(ticketDir);
    await config.save(file: file);
    // Where the answers are stored is an implementation detail of the
    // publish — the user just answered the questions and does not need a
    // path back.
    return config;
  }

  /// Returns the baseline the increment preview is calculated from: the
  /// version [repoDir] last published to its registry (pub.dev / npm), with
  /// the git version tag as fallback for private and manifest-less repos.
  ///
  /// The manifest is deliberately *not* used. `gg do publish` bumps from the
  /// published version, so a `pubspec.yaml` that lags behind the registry —
  /// which is the normal state after a publish, since only main carries the
  /// released version — would preview a version the publish never creates.
  ///
  /// Defaults to 0.0.0 when nothing can be determined (e.g. a repo without a
  /// version). Only the chosen increment is stored, so the baseline is used
  /// just for the preview.
  /// A failing lookup (e.g. the registry is unreachable) is reported instead of
  /// being swallowed, so a network hiccup does not silently look like a repo
  /// that was never published.
  Future<Version> _currentVersion(Directory repoDir) async {
    try {
      return await _publishedVersion.get(directory: repoDir, ggLog: ggLog);
    } on Exception catch (e) {
      ggLog(
        cWarn(
          '⚠️ Could not determine the published version, assuming 0.0.0: $e',
        ),
      );
      return Version(0, 0, 0);
    }
  }

  /// Opens the shared message editor for the merge message.
  // coverage:ignore-start
  static Future<String?> _defaultEditMessage(String initialMessage) =>
      editMessage(
        initialMessage,
        prompt: 'Edit merge message:',
        subject: 'the merge message prompt',
        hint: 'pass -m <message> or provide a config file via --config',
      );
  // coverage:ignore-end

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
