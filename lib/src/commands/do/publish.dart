// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_git/gg_git.dart';
import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_lang/gg_lang.dart' as gg_lang;
// ignore: lines_longer_than_80_chars
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_localize_refs/gg_localize_refs.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_publish/gg_publish.dart' show PublishedVersion;
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_do_publish/src/backend/ensure_in_registry.dart';
import 'package:gg_multi_do_publish/src/backend/npm_registry_checker.dart';
import 'package:gg_multi_do_publish/src/backend/pub_dev_checker.dart';
import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_multi_do_publish/src/commands/can/publish.dart';
import 'package:gg_multi_commit/gg_multi_commit.dart';
import 'package:gg_multi_do_publish/src/commands/do/configure_publish.dart'
    show DoConfigurePublishCommand;

/// Snapshot of a repository's state taken before its publish starts.
class _RepoPublishSnapshot {
  _RepoPublishSnapshot({
    required this.directory,
    required this.branch,
    required this.head,
    required this.status,
    required this.version,
    required this.mainBranch,
    required this.mainHead,
    required this.remoteMainHead,
    required this.remoteFeatureHead,
    required this.tags,
    this.stash,
  });

  /// The repository directory.
  final Directory directory;

  /// The branch the repository was on (usually the ticket feature branch).
  final String branch;

  /// The commit hash HEAD pointed to.
  final String head;

  /// The `git status --porcelain` output at snapshot time.
  final String status;

  /// The package version at snapshot time (null when unreadable).
  final String? version;

  /// The name of the default branch (`main`/`master`), null when absent.
  final String? mainBranch;

  /// The local commit hash of [mainBranch], null when absent.
  final String? mainHead;

  /// The remote commit hash of [mainBranch], null when unreachable/absent.
  final String? remoteMainHead;

  /// The remote commit hash of the feature branch, null when the snapshot was
  /// taken in detached HEAD or the branch is absent/unreachable. Used to skip
  /// resetting a feature branch whose commit already reached the remote.
  final String? remoteFeatureHead;

  /// All local tags at snapshot time.
  final Set<String> tags;

  /// Commit created via `git stash create` holding uncommitted changes,
  /// or null when there were none to preserve.
  final String? stash;
}

/// Command to publish all repos in the ticket.
///
/// With `--merge-only` ([mergeOnly]) the exact same flow runs, minus the two
/// steps that release the packages: nothing is uploaded to a package registry
/// and no version tags are created. Because the merged state is therefore
/// never resolvable against a registry, that mode refuses to run while any
/// repository of the ticket still redirects a dependency to a local working
/// copy (a `pubspec_overrides.yaml` with a `path:` override); such a ticket
/// has to be published. `--force` merges anyway.
///
/// Since a merge leaves no tag behind, the work it puts on the main branch is
/// unreleased. `PublishSkipCheck` therefore compares against the last **tag**,
/// not against the main branch — so the next `gg do publish` still sees those
/// commits instead of mistaking the repository for unchanged.
///
/// There is no `gg do merge` command anymore — it was folded into this one, so
/// there is exactly one flow.
/// Flags, in more detail than their one-line help texts carry:
/// - `--message` is the default merge message and only takes effect when the
///   configuration is written interactively (a fresh run or `--restart`); it
///   takes precedence over the ticket description and is ignored once a
///   configuration exists or was supplied via `--config`.
/// - `--config` is resolved as given (relative to the CWD), then below the
///   ticket folder. The file is only read — progress is written to the
///   runtime `.gg/gg-publish.json`.
/// - `--no-delete-remote-branch` keeps the remote feature branches; the local
///   folders are moved to the trash either way, because the ticket folder is
///   removed regardless.
/// - `--no-pr` performs a local merge instead of waiting for the provider.
/// - `--continue` reuses `.gg/gg-publish.json` and skips the repos already
///   published.
/// - `--publish-unchanged` releases every repo; by default a repo without
///   manual changes and without an out-of-range dependency bump is skipped.
/// - `--restart` discards the saved configuration *and* the recorded
///   progress, so the publish starts from the beginning.
class DoPublishCommand extends DirCommand<void> {
  /// Constructor
  DoPublishCommand({
    required super.ggLog,
    super.name = 'publish',
    super.description = 'Publish all repos of the current ticket',
    this.mergeOnly = false,
    gg.GgSystemCommit? systemCommit,
    gg.DoUpgradeDeps? ggDoUpgradeDeps,
    gg.CanCommit? ggCanCommit,
    ChangeRefsToPubDev? unlocalizeRefs,
    ChangeRefsToLocal? localizeRefs,
    RestorePublishTo? restorePublishTo,
    gg.DoPush? ggDoPush,
    gg.DoPublish? ggDoPublish,
    SortedProcessingList? sortedProcessingList,
    ProcessRunner? processRunner,
    CanPublishCommand? canPublishCommand,
    DidReviewCommand? didReviewCommand,
    GetVersion? getVersionCommand,
    SetRefVersion? setRefVersionCommand,
    GetRefVersion? getRefVersionCommand,
    PubDevChecker? pubDevChecker,
    NpmRegistryChecker? npmChecker,
    PublishSkipCheck? publishSkipCheck,
    PublishedVersion? publishedVersion,
    PublishPlanner? publishPlanner,
    gg.EnsurePublishConfigIgnored? ensureIgnored,
    EnsureInRegistry? ensureInRegistry,
    TicketState? ticketState,
    gg.InteractAdapter? interactAdapter,
    gg.HasTerminal? hasTerminal,
  }) : _systemCommit = systemCommit ?? gg.GgSystemCommit(ggLog: ggLog),
       _ggDoUpgradeDeps = ggDoUpgradeDeps ?? gg.DoUpgradeDeps(ggLog: ggLog),
       _ggCanCommit = ggCanCommit ?? gg.CanCommit(ggLog: ggLog),
       _unlocalizeRefs = unlocalizeRefs ?? ChangeRefsToPubDev(ggLog: ggLog),
       _localizeRefs = localizeRefs ?? ChangeRefsToLocal(ggLog: ggLog),
       _restorePublishTo = restorePublishTo ?? RestorePublishTo(ggLog: ggLog),
       _ggDoPush = ggDoPush ?? gg.DoPush(ggLog: ggLog),
       _ggDoPublish = ggDoPublish ?? gg.DoPublish(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _canPublishCommand =
           canPublishCommand ?? CanPublishCommand(ggLog: ggLog),
       _didReviewCommand = didReviewCommand ?? DidReviewCommand(ggLog: ggLog),
       _getVersion = getVersionCommand ?? GetVersion(ggLog: ggLog),
       _setRefVersion = setRefVersionCommand ?? SetRefVersion(ggLog: ggLog),
       _getRefVersion = getRefVersionCommand ?? GetRefVersion(ggLog: ggLog),
       _pubDevChecker = pubDevChecker ?? PubDevChecker(),
       _npmChecker = npmChecker ?? NpmRegistryChecker(),
       _publishPlanner =
           publishPlanner ??
           PublishPlanner(
             ggLog: ggLog,
             publishSkipCheck: publishSkipCheck,
             publishedVersion: publishedVersion,
             hasTerminal: hasTerminal,
           ),
       _ensureIgnored =
           ensureIgnored ?? gg.EnsurePublishConfigIgnored(ggLog: ggLog),
       _ensureInRegistry = ensureInRegistry ?? EnsureInRegistry(ggLog: ggLog),
       _ticketState = ticketState ?? TicketState(ggLog: ggLog),
       // coverage:ignore-start
       _interactAdapter = interactAdapter ?? gg.DefaultInteractAdapter(),
       // coverage:ignore-end
       _hasTerminal = hasTerminal ?? gg.defaultHasTerminal,
       _processRunner = processRunner ?? defaultProcessRunner {
    _addArgs();
  }

  /// Whether the run merges without releasing: no registry upload, no tags.
  ///
  /// Set by `--merge-only` (resolved in [get] before the flow starts) or by
  /// the constructor for programmatic callers; false for a regular publish.
  bool mergeOnly;

  /// The command name used in user-facing hints (`gg do publish` /
  /// `gg do publish --merge-only`).
  String get _command =>
      mergeOnly ? 'gg do publish --merge-only' : 'gg do publish';

  /// The past participle used in user-facing messages.
  String get _done => mergeOnly ? 'merged' : 'published';

  /// The noun used in user-facing messages.
  String get _action => mergeOnly ? 'merge' : 'publish';

  /// Writes gg's bookkeeping commits — pathspec-limited to gg-owned files,
  /// with any pending user work saved in its own commit first.
  final gg.GgSystemCommit _systemCommit;

  /// Upgrades the dependencies of a repo right before it is published.
  final gg.DoUpgradeDeps _ggDoUpgradeDeps;

  /// Re-verifies a repo after references were unlocalized and its
  /// dependencies were upgraded — gg_one's `can publish` runs no
  /// analyze/format/tests, so this closes that gap.
  final gg.CanCommit _ggCanCommit;

  /// Instance of UnlocalizeRefs
  final ChangeRefsToPubDev _unlocalizeRefs;

  /// Re-localizes a repo after its publish: `pubspec_overrides.yaml` path
  /// overrides for Dart, `link:` overrides in `pnpm-workspace.yaml` for
  /// pnpm-managed TypeScript — so the repo keeps resolving against the
  /// sibling checkouts.
  final ChangeRefsToLocal _localizeRefs;

  /// Restores the original `publish_to` value captured by `do add`.
  final RestorePublishTo _restorePublishTo;

  /// Instance of gg DoPush
  final gg.DoPush _ggDoPush;

  /// Instance of gg DoPublish
  final gg.DoPublish _ggDoPublish;

  /// Instance of SortedProcessingList
  final SortedProcessingList _sortedProcessingList;

  /// Instance of CanPublishCommand
  final CanPublishCommand _canPublishCommand;

  /// Answers whether the current ticket state was reviewed (`didReview`).
  final DidReviewCommand _didReviewCommand;

  /// Reads the current package version from pubspec.yaml
  final GetVersion _getVersion;

  /// Sets the version/spec of a dependency in pubspec.yaml
  final SetRefVersion _setRefVersion;

  /// Reads the version/spec of a dependency from pubspec.yaml
  final GetRefVersion _getRefVersion;

  /// Checks whether versions are visible on pub.dev.
  final PubDevChecker _pubDevChecker;

  /// Checks whether versions are visible on npm (TypeScript packages).
  final NpmRegistryChecker _npmChecker;

  /// Decides which repos need a release and collects the answers the run
  /// needs — the pass `gg do review` runs too, so a reviewed ticket publishes
  /// without asking anything again.
  final PublishPlanner _publishPlanner;

  /// Adds the repo-level `.gg/gg-publish.json` to each repo's `.gitignore`
  /// before the pre-publish commit, so gg_one's runtime file rides along.
  final gg.EnsurePublishConfigIgnored _ensureIgnored;

  /// Makes sure a repo has at least one version on its registry before it
  /// is published — a first-time publish is done manually by the user.
  final EnsureInRegistry _ensureInRegistry;

  /// Ticket-level state (`<ticket>/.gg.json`) — re-blesses `didReview`
  /// after a successful run, whose commits are gg bookkeeping only.
  final TicketState _ticketState;

  /// Interactive selection for the cleanup offer at the end of a run in
  /// which every repo was already published.
  final gg.InteractAdapter _interactAdapter;

  /// Whether stdin is a terminal — without one the cleanup offer is skipped
  /// and the ticket is kept.
  final gg.HasTerminal _hasTerminal;

  /// Runs shell commands such as branch deletion.
  final ProcessRunner _processRunner;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
    bool? deleteRemoteBranch,
    bool? mergeOnly,
    Map<String, dynamic> options = const {},
  }) => get(
    directory: directory,
    ggLog: ggLog,
    verbose: verbose,
    deleteRemoteBranch: deleteRemoteBranch,
    mergeOnly: mergeOnly,
    pana: options[gg.panaOption] as bool?,
  );

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
    bool? deleteRemoteBranch,
    bool? mergeOnly,
    bool? pana,
  }) async {
    ggLog(cH1('Publishing ...'));

    // »--merge-only« replaces the former »gg do merge« command. The resolved
    // value drives every merge-only branch of the flow below, so it is
    // settled before anything else runs.
    this.mergeOnly =
        mergeOnly ??
        (this.mergeOnly || (argResults?['merge-only'] as bool? ?? false));
    final bool isMergeOnly = this.mergeOnly;
    verbose ??= argResults?['verbose'] as bool? ?? false;
    final continueRun = argResults?['continue'] as bool? ?? false;
    final restart = argResults?['restart'] as bool? ?? false;
    final publishUnchanged = argResults?['publish-unchanged'] as bool? ?? false;
    // Turns the pana analysis of every »can publish« off — the ticket wide
    // one, the per-repo gate and the one inside gg_one's »do publish«.
    final usePana = pana ?? (argResults?[gg.panaOption] as bool? ?? true);
    final force = this.mergeOnly && (argResults?['force'] as bool? ?? false);
    final String? configArg = argResults?['config'] as String?;
    final String? messageArg = argResults?['message'] as String?;
    deleteRemoteBranch ??= argResults?['delete-remote-branch'] as bool? ?? true;

    // Only an explicitly passed --pr/--no-pr is forwarded to the repos; when
    // absent, each repo's persisted .gg/gg-publish.json (on resume) or the
    // default (pr = true) decides.
    final bool? prArg = (argResults?.wasParsed('pr') ?? false)
        ? (argResults?['pr'] as bool?)
        : null;

    final GgLog taskLog = verbose ? ggLog : <String>[].add;

    // Step 1: Detect ticket folder
    final String? ticketPath = WorkspaceUtils.detectTicketPath(
      path.absolute(directory.path),
    );
    if (ticketPath == null) {
      throw Exception(cDetail('Not inside a ticket folder'));
    }

    final ticketDir = Directory(ticketPath);
    final runtimeFile = DoConfigurePublishCommand.configFileFor(ticketDir);

    // Step 2: Get sorted repos.
    final subs = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );

    if (subs.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
      return;
    }

    // A merge brings the ticket onto the main branches without releasing it.
    // A repository that still redirects a dependency to a local working copy
    // would therefore land on main referencing something nobody can resolve —
    // that ticket has to be published, not merged. Checked before the review
    // gate: no review can fix it, so its message must win.
    if (isMergeOnly && !force) {
      _throwOnLocalizedRefs(subs);
    }

    // Step 3: Load the configuration from the files that may supply it.
    // This stays up front: the runtime file is the resume anchor, and a
    // leftover one carrying progress markers must be reported before anything
    // else happens. Only the *interactive* branch moves behind the checks.
    final loaded = await _loadExistingPublishConfig(
      ticketDir: ticketDir,
      runtimeFile: runtimeFile,
      configArg: configArg,
      continueRun: continueRun,
      restart: restart,
    );
    gg.PublishConfig? loadedConfig = loaded.config;
    final String configSourcePath = loaded.sourcePath;

    // --restart discards not only the ticket-level config but also the
    // repo-level step progress gg_one recorded in an earlier run.
    if (restart) {
      for (final repo in subs) {
        final repoRuntime = gg.DoConfigurePublish.configFileFor(repo.directory);
        if (repoRuntime.existsSync()) {
          repoRuntime.deleteSync();
        }
      }
    }

    // Step 4: The review gate and the ticket wide validation. The per-repo
    // `gg can publish` gate is NOT part of this — it runs inside
    // _publishRepo, right before the repo is published (see there).
    // Skipped when genuinely resuming a run that already made irreversible
    // progress: a repo finished ('published'), or a repo's own
    // .gg/gg-publish.json records completed publish steps — e.g. the FIRST
    // repo failed after its registry publish or merge. Re-running the ticket
    // wide checks — whose push step merges main into the feature branches —
    // on such a partially merged ticket would fail and permanently block the
    // resume; the mid-publish commits would also fail the `did review` hash.
    // A `--continue` after a failure without progress still runs both, so an
    // unreviewed state is never published. gg_one re-checks `did commit` per
    // repo on resume, so raw commits added after the failure are still caught.
    final resumingMidPublish =
        continueRun &&
        ((loadedConfig?.repos.values.any((r) => r.status == 'published') ??
                false) ||
            subs.any((repo) => repoHasPublishStepProgress(repo.directory)));
    if (!resumingMidPublish) {
      await _throwUnlessReviewed(ticketDir: ticketDir, ggLog: ggLog);

      try {
        await _canPublishCommand.checkTicket(
          directory: ticketDir,
          ggLog: ggLog,
          pana: usePana,
          includeCanPublish: false,
        );
      } on MergeConflictException {
        // Conflicts are resolved by the user; the report the push threw
        // carries the actionable instructions, so do not bury it in a
        // publish error.
        rethrow;
      } catch (e) {
        ggLog([cError(rmControls('$e'))].join('\n'));
        ggLog(cAction('\nPlease fix the issues above.\n'));

        throw Exception(cDetail('Cannot publish.'));
      }
    }

    // Step 5: Plan the run. Only now is the state up to date — »do push« has
    // merged the main branches in and refreshed the dependencies — so only
    // now can the skip check be trusted. The pass decides per repo whether it
    // needs a release and asks the version/message questions for exactly the
    // repos that do.
    final plan = await _publishPlanner.plan(
      ticketDir: ticketDir,
      subs: subs,
      ggLog: ggLog,
      config: loadedConfig,
      continueRun: continueRun,
      publishUnchanged: publishUnchanged,
      mergeOnly: isMergeOnly,
      defaultMergeMessage: messageArg,
      wording: isMergeOnly
          ? PublishPlanWording.merge
          : PublishPlanWording.publish,
    );
    final gg.PublishConfig planned = plan.config;
    gg.PublishConfig publishConfig = planned;

    // The answers the pass collected are the resume anchor of this run.
    if (plan.anyPublishes || loadedConfig != null) {
      await planned.save(file: runtimeFile);
    }

    // A run that neither publishes anything nor finishes a partly published
    // ticket is a no-op: the ticket carries nothing but gg's own bookkeeping.
    final anyAlreadyPublished =
        continueRun && planned.repos.values.any((r) => r.status == 'published');
    final isNoOpRun = !plan.anyPublishes && !anyAlreadyPublished;

    // Step 6: The last interactive question — what happens to the ticket once
    // everything is published. Asked here so no prompt sits between the
    // irreversible publish steps or at the very end of a long unattended run.
    // A no-op run is not asked at all: the user expected a release, nothing
    // happened, and offering to trash the ticket would be a surprising side
    // effect of doing nothing.
    //
    // The answer is persisted in the runtime file, so a `--continue` after a
    // failure resumes with the decision the user already made. A no-op run
    // answers »keep« without recording it — that is the absence of a decision,
    // not one, and a later real run must still get to ask.
    final bool closeTicketWhenDone;
    if (publishConfig.deleteTicket != null) {
      closeTicketWhenDone = publishConfig.deleteTicket!;
    } else if (isNoOpRun) {
      closeTicketWhenDone = false;
    } else {
      closeTicketWhenDone = await _offerTicketCleanup(
        ticketName: path.basename(ticketDir.path),
      );
      publishConfig = publishConfig.withDeleteTicket(closeTicketWhenDone);
      await publishConfig.save(file: runtimeFile);
    }

    final publishedPackages = <String, _PublishedPackageState>{};
    final confirmedPubDevVersions = <String>{};

    // Map of reference name to version captured from repos processed so far.
    final refVersions = <String, String>{};

    // Whether this run released (or merged) anything at all. A run in which
    // every repo was skipped must not claim otherwise — the ticket carries
    // nothing but gg's own bookkeeping and everything is already out there.
    var anythingProcessed = false;

    // Step 6: Iterate over each repository and publish (or resume).
    for (final repo in subs) {
      final repoDir = repo.directory;
      final repoName = path.basename(repoDir.path);

      final alreadyPublished =
          continueRun && publishConfig.statusForRepo(repoName) == 'published';

      // A repo without manual changes whose dependencies all stay inside
      // their published constraints needs no release. The decision is made
      // fresh on every run — also on --continue, where a repo marked
      // 'skipped' earlier is re-evaluated instead of trusted, so commits
      // added after a failed run are never lost to a stale marker.
      // The planning pass already decided and — for a publishing repo — has
      // the answers. It may only be tightened, never loosened: it asked the
      // questions for everything it marked as publishing, so a repo that
      // meanwhile turned skippable is published anyway rather than leaving
      // those answers unused.
      final skip = !alreadyPublished && !plan.publishes.contains(repoName);

      if (alreadyPublished) {
        ggLog('\n${cH1(repoName)} already $_done — skipping.');
      } else if (skip) {
        // The planning pass already reported the verdict per repo.
        publishConfig = publishConfig.withRepoStatus(repoName, 'skipped');
        await publishConfig.save(file: runtimeFile);
      } else {
        await _waitForPublishedDependenciesIfNeeded(
          currentRepo: repo,
          publishedPackages: publishedPackages,
          confirmedPubDevVersions: confirmedPubDevVersions,
          ggLog: ggLog,
        );

        ggLog('\n${cH1(repoName)}');

        // Save the repo state so a failed publish can restore it.
        final snapshot = await _saveRepoState(repoDir: repoDir, ggLog: taskLog);

        try {
          await _publishRepo(
            repoDir: repoDir,
            repoName: repoName,
            refVersions: refVersions,
            publishConfig: publishConfig,
            configPath: configSourcePath,
            resume: continueRun,
            pr: prArg,
            force: force,
            pana: usePana,
            verbose: verbose,
            ggLog: ggLog,
            taskLog: taskLog,
          );
        } catch (e) {
          // Record the failure so `--continue` resumes here, report why,
          // restore the repo towards its pre-publish state, then surface the
          // failure.
          publishConfig = publishConfig.withRepoStatus(repoName, 'failed');
          await publishConfig.save(file: runtimeFile);
          _logPublishFailure(repoName: repoName, error: e, ggLog: ggLog);
          await _restoreRepoStateOnFailure(
            snapshot: snapshot,
            ggLog: ggLog,
            taskLog: taskLog,
          );
          rethrow;
        }

        // Record success *now*, before the network-dependent version capture
        // below — so a transient failure there cannot lose the marker and
        // re-run this already-published repo on a later `--continue`.
        anythingProcessed = true;
        publishConfig = publishConfig.withRepoStatus(repoName, 'published');
        await publishConfig.save(file: runtimeFile);
        taskLog(cDetail('✓ $repoName: $_done successfully.'));

        // The release is irreversible and complete — bring the repo back
        // into its workable workspace state: feature branch, restored
        // references.
        await _restoreWorkspaceState(
          repoDir: repoDir,
          repoName: repoName,
          snapshot: snapshot,
          ggLog: ggLog,
          taskLog: taskLog,
        );
      }

      // Capture the published version + registry visibility so later repos
      // that depend on this one get the right ref and wait for pub.dev/npm.
      // Runs for skipped repos too. The registry lookup is best-effort: it
      // must not abort a run whose repo already published irreversibly.
      try {
        final version = await _getVersion.get(directory: repoDir);
        if (version != null && version.isNotEmpty) {
          // A hybrid is known under two names — »base_dna« to its Dart
          // dependents and »@tssuite/base-dna« to its npm ones. Registering
          // only one of them left the other ecosystem's constraint at the old
          // version.
          final names = await _publishPlanner.publishedNames(repoDir, repoName);
          for (final name in names.values) {
            refVersions[name] = version;
          }

          try {
            // Git-only repos (no manifest) have no registry to wait for. A
            // merge uploads nothing either, so the fresh version never becomes
            // visible on a registry — recording it here would make every
            // dependent repo wait for a release that is not coming.
            if (!isMergeOnly) {
              for (final entry in names.entries) {
                final target = entry.key;
                final packageName = entry.value;
                final publishInfo = target == gg_lang.PublishTarget.npm
                    ? await _npmChecker.getPackagePublishInfo(
                        packageName: packageName,
                        workingDirectory: repoDir.path,
                      )
                    : await _pubDevChecker.getPackagePublishInfo(
                        packageName: packageName,
                      );
                publishedPackages[packageName] = _PublishedPackageState(
                  packageName: packageName,
                  version: version,
                  waitsForPubDev: publishInfo.waitsForPubDev,
                  target: target,
                  repoDirPath: repoDir.path,
                );
              }
            }
          } catch (e) {
            ggLog(
              cWarn(
                'Could not check registry visibility of '
                '${names.values.join(', ')} ($e); dependent repos will not '
                'wait for it. Publish is unaffected.',
              ),
            );
          }
        }
      } catch (e) {
        throw Exception(cError('Failed to get version of $repoName: $e'));
      }
    }

    // Repos the run left unpublished on purpose are reported per repo while
    // they are skipped — a summary line adds nothing and reads like a
    // failure.

    // Step 7: All repos processed — the resume anchor is no longer needed.
    if (runtimeFile.existsSync()) {
      runtimeFile.deleteSync();
      taskLog(
        cDetail(
          '✓ Removed ${path.basename(runtimeFile.path)} after the $_action.',
        ),
      );
    }

    // Step 8: Re-bless the review state. Every commit this run added to the
    // ticket is gg bookkeeping — version bumps, changelog releases, restored
    // references, state markers. The content the reviewer approved is
    // unchanged, so the next publish must not demand a new review for it.
    try {
      await _ticketState.writeSuccess(
        ticketDir: ticketDir,
        subs: subs,
        key: DidReviewCommand.stateKey,
      );
    } catch (e) {
      ggLog(cWarn('Could not refresh the didReview state: $e'));
    }

    ggLog(
      anythingProcessed
          ? '\nAll repos $_done\n'
          : '\nNothing to $_action — every repo is already $_done\n',
    );

    // A no-op run leaves the ticket exactly as it was; the hint below already
    // says so, and there is nothing to clean up.

    // Step 9: Carry out what the user decided up front (Step 4b). Every
    // repo is $_done at this point — the ones released just now are back on
    // their feature branches with restored references, the skipped ones
    // never left that state — so the ticket can either be closed (whole
    // folder to the trash, remote branches deleted) or kept for further
    // work and another publish from the same branch.
    if (closeTicketWhenDone) {
      await cleanUpTicket(
        ticketDir: ticketDir,
        repoDirs: [for (final repo in subs) repo.directory],
        deleteRemoteBranch: deleteRemoteBranch,
        ggLog: ggLog,
        taskLog: taskLog,
        processRunner: _processRunner,
      );
      return;
    }

    _logTicketKeptHint(ggLog, path.basename(ticketDir.path));
  }

  /// Asks up front what should happen to the ticket once the publish is
  /// through, and returns whether it should be closed then.
  ///
  /// Uses the same cursor-key prompt as the version-increment selection, and
  /// is asked in the same phase: every interactive decision of a run is made
  /// before the first irreversible step. Returns false without asking when
  /// stdin is no terminal — a headless run must never trash a ticket on its
  /// own.
  Future<bool> _offerTicketCleanup({required String ticketName}) async {
    if (!_hasTerminal()) {
      return false;
    }

    final index = await _interactAdapter.choose(
      // The blank line separates the question from the publish log above it.
      // The question is a heading, the options are what the user acts on. The
      // command sits at the very end of its option, so wrapping it in cCmd
      // resets no color that still has text to cover.
      message: '\n${cH1('What should happen to the ticket when ready?')}',
      options: <String>[
        cAction('Move to .trash and delete the remote branches'),
        '${cAction('Remove it manually with ')}'
            '${cCmd('»gg do rm ticket $ticketName«')}',
      ],
    );
    return index == 0;
  }

  /// Tells the user that the ticket stays workable and how to close it.
  void _logTicketKeptHint(GgLog ggLog, String ticketName) {
    ggLog(
      cAction(
        'The ticket stays in place — every repo is back on its feature '
        'branch with local references restored.\n'
        'Continue working and publish again, or close the ticket with:',
      ),
    );
    ggLog(cCmd('  gg do rm ticket $ticketName'));
  }

  /// Resolves the publish configuration for the ticket in [ticketDir] and
  /// makes sure a runtime copy lives at [runtimeFile] (the resume anchor).
  ///
  /// Precedence: on `--continue` the runtime file must already exist; else an
  /// explicit `--config` file, then the runtime file, then the legacy
  /// `<ticket>/.gg-publish.json`, and finally an interactive
  /// `do configure-publish`. `--restart` skips the two implicit files so
  /// the user is asked again. User-supplied `--config` / legacy files are only
  /// read — the mutable runtime copy is what receives the progress markers.
  /// [messageArg] (from `-m`) is forwarded to `do configure-publish` as the
  /// default merge message and only matters when the config is written
  /// interactively — it is ignored for `--config`, legacy and runtime files.
  /// [config] is the resolved configuration; [sourcePath] is the file it came
  /// from (the user's `--config`/legacy file, or the runtime copy) — used so a
  /// missing-field error points at the file the user actually authored.
  Future<({gg.PublishConfig? config, String sourcePath})>
  _loadExistingPublishConfig({
    required Directory ticketDir,
    required File runtimeFile,
    required String? configArg,
    required bool continueRun,
    required bool restart,
  }) async {
    if (continueRun && (configArg != null || restart)) {
      throw Exception(cError(gg.continueConflictMessage));
    }

    if (continueRun) {
      if (!runtimeFile.existsSync()) {
        throw Exception(
          cError(
            'Nothing to continue: ${runtimeFile.path} does not exist. Start a '
            'normal "$_command" first.',
          ),
        );
      }
      return (
        config: gg.PublishConfig.load(
          configArg: runtimeFile.path,
          fallbackDir: ticketDir.path,
        ),
        sourcePath: runtimeFile.path,
      );
    }

    if (restart && runtimeFile.existsSync()) {
      // Explicit user choice: discard the previous config and progress.
      runtimeFile.deleteSync();
    }

    if (configArg != null) {
      // A fresh --config run must not clobber the progress markers of an
      // unfinished publish (same guard as the implicit runtime-file path).
      _throwOnLeftoverTicketProgress(
        runtimeFile: runtimeFile,
        ticketDir: ticketDir,
      );
      final config = gg.PublishConfig.load(
        configArg: configArg,
        fallbackDir: ticketDir.path,
      );
      await config.save(file: runtimeFile);
      return (config: config, sourcePath: configArg);
    }

    if (!restart && runtimeFile.existsSync()) {
      final config = gg.PublishConfig.load(
        configArg: runtimeFile.path,
        fallbackDir: ticketDir.path,
      );
      // A runtime file carrying progress markers is the leftover of an
      // unfinished run — do not silently reuse it as plain config.
      if (config.repos.values.any((r) => r.status != null)) {
        throw Exception(
          cError(
            gg.unfinishedPublishMessage(
              path: runtimeFile.path,
              command: _command,
            ),
          ),
        );
      }
      return (config: config, sourcePath: runtimeFile.path);
    }

    final legacyFile = File(path.join(ticketDir.path, '.gg-publish.json'));
    if (!restart && legacyFile.existsSync()) {
      final config = gg.PublishConfig.load(
        configArg: legacyFile.path,
        fallbackDir: ticketDir.path,
      );
      await config.save(file: runtimeFile);
      return (config: config, sourcePath: legacyFile.path);
    }

    // Only the interactive path is left. It runs later — after the ticket
    // wide checks decided the run may proceed at all, and after the planning
    // pass decided which repos actually need a release, so nobody answers a
    // version question for a repo that is then skipped.
    return (config: null, sourcePath: runtimeFile.path);
  }

  /// Throws when the *current* ticket state was not reviewed.
  ///
  /// Publishing does not review the ticket itself — it demands that the
  /// state went through `gg do review` (the hash-based `didReview` state,
  /// so a commit made after the review requires a new review before it can
  /// be published). Delegates to `gg did review`, which checks the chain
  /// `did commit` → `did push` → `did review` — so the most fundamental
  /// missing step is what the user is told about (e.g. »Please run
  /// gg do commit« instead of a generic »not reviewed«).
  Future<void> _throwUnlessReviewed({
    required Directory ticketDir,
    required GgLog ggLog,
  }) => _didReviewCommand.exec(directory: ticketDir, ggLog: ggLog);

  /// Whether [runtimeFile] still carries per-repo progress markers of an
  /// unfinished run.
  bool _ticketHasLeftoverProgress({
    required File runtimeFile,
    required Directory ticketDir,
  }) {
    if (!runtimeFile.existsSync()) {
      return false;
    }
    final existing = gg.PublishConfig.load(
      configArg: runtimeFile.path,
      fallbackDir: ticketDir.path,
    );
    return existing.repos.values.any((r) => r.status != null);
  }

  /// Throws when [runtimeFile] still carries per-repo progress markers of an
  /// unfinished run — a fresh config source must not clobber them.
  void _throwOnLeftoverTicketProgress({
    required File runtimeFile,
    required Directory ticketDir,
  }) {
    if (_ticketHasLeftoverProgress(
      runtimeFile: runtimeFile,
      ticketDir: ticketDir,
    )) {
      throw Exception(
        cError(
          gg.unfinishedPublishMessage(
            path: runtimeFile.path,
            command: _command,
          ),
        ),
      );
    }
  }

  /// Performs the per-repo publish steps: unlocalize refs, restore
  /// publish_to, propagate reference versions, refresh dependencies, commit,
  /// check that this repo can be published, push and finally `gg do publish`.
  Future<void> _publishRepo({
    required Directory repoDir,
    required String repoName,
    required Map<String, String> refVersions,
    required gg.PublishConfig publishConfig,
    required String configPath,
    required bool resume,
    required bool? pr,
    required bool force,
    required bool pana,
    required bool verbose,
    required GgLog ggLog,
    required GgLog taskLog,
  }) async {
    // Make sure the repo-level runtime file gg_one writes is gitignored —
    // the entry rides along the force-commit below, no extra commit needed.
    await _ensureIgnored.ensure(directory: repoDir, commit: false);

    // Save the pubspec_overrides.yaml before the unlocalization below
    // deletes it — _restoreWorkspaceState puts it back once the repo is
    // merged, so the workspace wiring survives the publish. On a resume the
    // file is usually gone already; the backup of the first attempt is then
    // left untouched.
    if (gg.backupPubspecOverrides(repoDir)) {
      taskLog(
        cDetail(
          '✓ $repoName: saved pubspec_overrides.yaml to '
          '${gg.pubspecOverridesBackupPath}.',
        ),
      );
    }

    // A repo that already carries gg_one step progress is past the point
    // where validation is meaningful — its version is bumped and possibly
    // uploaded, so upgrading or re-checking it would touch a mid-publish
    // state. The gate below skips for the same reason.
    final skipValidation = resume && repoHasPublishStepProgress(repoDir);

    await _changeRefsToPubDev(
      repoDir: repoDir,
      repoName: repoName,
      refVersions: refVersions,
      taskLog: taskLog,
      // On the normal path the upgrade below runs »dart pub upgrade« anyway
      // — refreshing the Dart side here as well would resolve every repo
      // twice. Only the resume path, which skips the upgrade, still needs
      // the Dart refresh.
      refreshDart: skipValidation,
    );

    // Upgrade the dependencies and re-verify with `gg can commit` before
    // anything is published. The refs point at the registry again, so
    // »dart pub upgrade --tighten« resolves against the sibling versions
    // published earlier in this run. gg_one's `can publish` runs no
    // analyze/format/tests — without this step the post-upgrade state
    // would never be validated. Output stays visible.
    if (!skipValidation) {
      await _ggDoUpgradeDeps.exec(directory: repoDir, ggLog: ggLog);
      await _ggCanCommit.exec(directory: repoDir, ggLog: ggLog);
    }

    // Commit — sweeps the reference changes and the upgrade changes into
    // one bookkeeping commit.
    // A system commit: the ref and upgrade changes are gg's own. Anything
    // else the tree carries is the user's and gets its own, prefix-less
    // commit first, so the release history says who wrote what.
    await _systemCommit.commit(
      directory: repoDir,
      ggLog: taskLog,
      message: '${gg.ggCommitPrefix}changed references to pub.dev',
      userCommitMessage: gg.readTicketDescriptionForRepo,
      // The unlocalization above rewrote the manifests, which is exactly
      // what the recorded »everything is committed« hash covers — the gate
      // right below reads it through `did commit`. Without recording it
      // anew, every repo with a sibling dependency fails with a spurious
      // »Not committed yet« the moment that sibling's version moves.
      stateKey: gg.GgState.doCommitKey,
    );

    // Can this repo be published? Only NOW is the question answerable: the
    // refs point at the registry again and every dependency published
    // earlier in this run is already there, so pana — which analyses the
    // package exactly as it would be published — can resolve it. Asking this
    // ticket wide up front fails for every repo that depends on a sibling
    // version this run has not uploaded yet.
    //
    // Two invariants hold the position:
    //   * AFTER the force-commit — gg can publish contains `did commit`, and
    //     _changeRefsToPubDev leaves the manifests dirty.
    //   * BEFORE the push — nothing irreversible has happened yet, so a
    //     rejected repo takes the full-restore path in _restoreRepoState and
    //     ends up exactly as it started. Moving this below the push would
    //     downgrade a fully recoverable failure to a cleanup restore.
    //
    // A repo that already carries gg_one step progress is past the point
    // where the gate is meaningful — its version is bumped and possibly
    // uploaded, which is precisely what pana and `is feature branch` would
    // now trip over — so a resume skips it and gg_one continues at its own
    // first open step.
    // A hybrid whose two manifests disagree is reconciled inside gg_one's
    // publish, and the reconciled version has no CHANGELOG.md section yet —
    // which pana rejects. gg_one turns pana off for such a run; the gate here
    // runs *before* that, so it has to reach the same conclusion itself.
    final repoPana = pana && !await gg_lang.hybridVersionsDiffer(repoDir);
    if (pana && !repoPana) {
      taskLog(
        cWarn(
          '$repoName: the manifests disagree on the version — publishing '
          'without pana.',
        ),
      );
    }

    if (!skipValidation) {
      await _canPublishCommand.checkRepo(
        directory: repoDir,
        ggLog: ggLog,
        pana: repoPana,
      );
    }

    // Push
    await _ggDoPush.exec(directory: repoDir, ggLog: taskLog);

    taskLog(cDetail('✓ $repoName: updated with new references.'));

    // At least one version must already be on the registry. A package that
    // was never published is published manually by the user first — right
    // now, while the refs are unlocalized and the publish target is
    // restored, so the current folder is publishable as-is. A merge-only
    // run releases nothing to a registry, so there is nothing to ensure.
    if (!mergeOnly) {
      await _ensureInRegistry.ensure(directory: repoDir, ggLog: ggLog);
    }

    // The publish configuration is always resolved up front, so every repo
    // has an explicit merge message and version increment here.
    final resolved = publishConfig.forRepo(
      repoName: repoName,
      configPath: configPath,
      // A merge-only run bumps no version, so a config written for it carries
      // no increment — demanding one would reject the very file it wrote.
      requireVersionIncrement: !mergeOnly,
    );
    final publishMessage = resolved.mergeMessage;
    final publishVersionIncrement = resolved.versionIncrement;
    final publishChannel = publishConfig.channelForRepo(repoName);

    // gg do publish; multi flow is non-interactive (no confirm prompt).
    // On --continue, gg_one resumes at the first step its repo-level
    // .gg/gg-publish.json marks as not done yet.
    await _ggDoPublish.exec(
      directory: repoDir,
      ggLog: ggLog,
      message: publishMessage,
      deleteFeatureBranch: false,
      verbose: verbose,
      versionIncrement: publishVersionIncrement,
      channel: publishChannel,
      askBeforePublishing: false,
      resume: resume,
      pr: pr,
      mergeOnly: mergeOnly,
      force: force,
      options: <String, dynamic>{gg.panaOption: repoPana},
    );
  }

  /// Brings a freshly published repo back into a workable workspace state:
  /// gg_one's flow left it on the default branch with the localized
  /// references gone.
  ///
  /// Steps, and why each one exists:
  ///   1. Check the feature branch out again — work continues there.
  ///   2. Merge the default branch back into it. Right after the publish
  ///      both branches hold identical content, so the merge is trivially
  ///      clean — but it makes the release the common ancestor of every
  ///      future merge. Without it, the next `do push` (which merges main
  ///      into the feature branch) would see the squash commit and the
  ///      feature branch as two competing edits of the same lines and
  ///      conflict — for TypeScript repos on every single publish.
  ///   3. Restore the workspace wiring files (`pubspec_overrides.yaml`,
  ///      `pnpm-workspace.yaml`) from the backups taken in [_publishRepo],
  ///      then re-localize (`ChangeRefsToLocal`): Dart repos get their path
  ///      overrides back, pnpm-managed TypeScript repos their `link:`
  ///      overrides in `pnpm-workspace.yaml` — recomputed on top of the
  ///      restored files, so the freshly published versions also land in
  ///      the `gg_localize_refs` backups.
  ///   4. Refresh the dependencies so lock files and `node_modules` follow
  ///      the restored references.
  ///   5. Commit everything as one gg bookkeeping commit and — for a real
  ///      publish, not a merge. No »published« marker is recorded any more:
  ///      `gg did publish` reads the tags, which cannot go stale.
  ///   6. Push, so the remote feature branch matches and shared workspaces
  ///      stay in sync.
  ///
  /// Failures are reported as warnings and never fail the publish: the
  /// release itself is irreversible and complete at this point.
  Future<void> _restoreWorkspaceState({
    required Directory repoDir,
    required String repoName,
    required _RepoPublishSnapshot snapshot,
    required GgLog ggLog,
    required GgLog taskLog,
  }) async {
    try {
      final branch = snapshot.branch;
      await _runGit(<String>['checkout', branch], repoDir: repoDir);

      final mainBranch = snapshot.mainBranch;
      if (mainBranch != null) {
        try {
          await _runGit(<String>[
            'merge',
            '-m',
            '${gg.ggMergeBackPrefix}$mainBranch back into $branch',
            mainBranch,
          ], repoDir: repoDir);
        } catch (e) {
          await _runGit(
            <String>['merge', '--abort'],
            repoDir: repoDir,
            allowFailure: true,
          );
          ggLog(
            cWarn(
              '⚠️ Could not merge $mainBranch back into $branch of '
              '$repoName: $e\n'
              'Merge it manually before the next publish.',
            ),
          );
        }
      }

      if (gg.restorePubspecOverrides(repoDir)) {
        taskLog(cDetail('✓ $repoName: restored pubspec_overrides.yaml.'));
      }

      await _localizeRefs.get(directory: repoDir, ggLog: taskLog);

      await _refreshDependencies(
        repoDir: repoDir,
        repoName: repoName,
        ggLog: taskLog,
      );

      await _systemCommit.commit(
        directory: repoDir,
        ggLog: taskLog,
        message: '${gg.ggCommitPrefix}restored local workspace references',
        userCommitMessage: gg.readTicketDescriptionForRepo,
        // Re-localizing rewrites the manifests again — record the state so
        // the push below and the next command in the ticket do not see a
        // repo that looks uncommitted.
        stateKey: gg.GgState.doCommitKey,
      );

      await _ggDoPush.exec(directory: repoDir, ggLog: taskLog);

      ggLog(
        cDetail('✓ $repoName: back on $branch — local references restored.'),
      );
    } catch (e) {
      ggLog(
        cWarn(
          '⚠️ $repoName is $_done, but its workspace state could not be '
          'restored: $e\n'
          'Restore it manually: check the feature branch out and run '
          '${cCmd('gg do add ${path.basename(repoDir.path)}')} in the '
          'ticket to re-localize the references.',
        ),
      );
    }
  }

  /// Points every reference of [repoDir] at the registry again: the localized
  /// refs are unlocalized, the original `publish_to` is restored, every known
  /// [refVersions] entry is written as the dependency's version and the
  /// dependencies are refreshed so the lock file follows.
  ///
  /// While the ticket is worked on, `gg_localize_refs` redirects the
  /// workspace dependencies through `pubspec_overrides.yaml` to the sibling
  /// checkouts. A publish must resolve against the registry instead —
  /// [_restoreWorkspaceState] brings the workspace wiring back once the
  /// release is through.
  Future<void> _changeRefsToPubDev({
    required Directory repoDir,
    required String repoName,
    required Map<String, String> refVersions,
    required GgLog taskLog,
    bool refreshDart = true,
  }) async {
    try {
      await _unlocalizeRefs.get(directory: repoDir, ggLog: taskLog);
      taskLog(cDetail('✓ $repoName: unlocalized refs.'));
    } catch (e) {
      throw Exception(cError('Failed to unlocalize refs for $repoName: $e'));
    }

    try {
      await _restorePublishTo.exec(directory: repoDir, ggLog: taskLog);
    } catch (e) {
      throw Exception(cError('Failed to restore publish_to for $repoName: $e'));
    }

    // Apply all known reference versions to this repo if it depends on them
    for (final entry in refVersions.entries) {
      final refName = entry.key;
      final refVersion = entry.value;
      try {
        final spec = await _getRefVersion.get(directory: repoDir, ref: refName);
        if (spec != null) {
          // Pass the bare published version. set-ref-version preserves the
          // operator (`^`, `~`, or none/exact) the dependency is currently
          // declared with — the refs were just unlocalized back to their
          // original spec — so the user's chosen constraint style survives.
          await _setRefVersion.get(
            directory: repoDir,
            ref: refName,
            version: refVersion,
          );
        }
      } catch (e) {
        throw Exception(
          cError(
            'Failed to update version of $refName '
            'in $repoName: $e',
          ),
        );
      }
    }

    // Refresh deps after manifest edits (refs, publish_to, versions).
    await _refreshDependencies(
      repoDir: repoDir,
      repoName: repoName,
      ggLog: taskLog,
      includeDart: refreshDart,
    );
  }

  /// Throws when one of [repos] still redirects a dependency to a local
  /// working copy — a `pubspec_overrides.yaml` with a `path:` override
  /// (Dart) or a `pnpm-workspace.yaml` with a `link:` override (TypeScript).
  ///
  /// Only a `--merge-only` run calls this: it brings the ticket onto the main
  /// branches *without* releasing anything, so a reference that exists only as
  /// a working copy on this machine would never become resolvable for anybody
  /// else. Such a ticket has to be published. `--force` skips the check.
  void _throwOnLocalizedRefs(List<Node> repos) {
    final localized = repos
        .where(
          (repo) =>
              gg.NoPubspecOverrides.hasLocalizedRefs(repo.directory) ||
              PnpmWorkspaceIo.hasLocalizedRefs(repo.directory),
        )
        .map((repo) => path.basename(repo.directory.path))
        .toList();

    if (localized.isEmpty) {
      return;
    }

    throw Exception(
      cError(
        [
          'These projects depend on other local projects: '
              '${localized.join(', ')}.',
          'Just merging is not possible.',
          '  - Either run ${cCmd('gg do publish')} ',
          '  - Or merge anyway adding ${cCmd('--force')} option.',
        ].join('\n'),
      ),
    );
  }

  /// Runs git with [args] in [repoDir] and returns the trimmed stdout.
  /// Delegates to the shared [runGit] so `do push` and
  /// `do publish` use one git runner. See there for [allowFailure].
  Future<String> _runGit(
    List<String> args, {
    required Directory repoDir,
    bool allowFailure = false,
  }) => runGit(
    _processRunner,
    args,
    repoDir: repoDir,
    allowFailure: allowFailure,
  );

  /// Returns the commit hash of the local branch [branch] in [repoDir],
  /// or null when the branch does not exist.
  Future<String?> _localBranchHead(Directory repoDir, String branch) async {
    final out = await _runGit(
      <String>['rev-parse', '--verify', '--quiet', 'refs/heads/$branch'],
      repoDir: repoDir,
      allowFailure: true,
    );
    return out.isEmpty ? null : out;
  }

  /// Returns the commit hash of `origin/<branch>` for [repoDir], or null
  /// when the remote branch does not exist or cannot be queried.
  Future<String?> _remoteBranchHead(Directory repoDir, String branch) async {
    final result = await _processRunner('git', <String>[
      'ls-remote',
      'origin',
      'refs/heads/$branch',
    ], workingDirectory: repoDir.path);
    if (result.exitCode != 0) {
      return null;
    }
    final out = (result.stdout?.toString() ?? '').trim();
    if (out.isEmpty) {
      return null;
    }
    return out.split(RegExp(r'\s+')).first;
  }

  /// Captures the uncommitted changes of [repoDir] in a dangling stash commit,
  /// leaving the working tree unchanged. Delegates to the shared
  /// [captureUncommitted]; returns the stash hash or null.
  Future<String?> _captureUncommitted({
    required Directory repoDir,
    required String status,
  }) => captureUncommitted(_processRunner, repoDir: repoDir, status: status);

  /// Whether [status] (a `git status --porcelain` output) shows an uncommitted
  /// change to the version-bearing manifest. Used to tell a *committed* version
  /// bump apart from an uncommitted half-written one left by a failed publish.
  bool _manifestDirty(String status) =>
      status.contains('pubspec.yaml') || status.contains('package.json');

  /// Records branch, HEAD, working tree, package version, default-branch
  /// position (local + remote), feature-branch remote head and tags of
  /// [repoDir], so a failed publish can be rolled back by [_restoreRepoState].
  Future<_RepoPublishSnapshot> _saveRepoState({
    required Directory repoDir,
    required GgLog ggLog,
  }) async {
    final repoName = path.basename(repoDir.path);
    try {
      final head = await _runGit(<String>[
        'rev-parse',
        'HEAD',
      ], repoDir: repoDir);
      final rawBranch = await _runGit(<String>[
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ], repoDir: repoDir);
      final detached = rawBranch == 'HEAD';
      // Detached HEAD: `rev-parse --abbrev-ref` prints the literal "HEAD".
      // Store the commit so restore re-detaches at it instead of running the
      // no-op `git checkout HEAD`.
      final branch = detached ? head : rawBranch;
      final status = await _runGit(<String>[
        'status',
        '--porcelain',
      ], repoDir: repoDir);
      final stash = await _captureUncommitted(repoDir: repoDir, status: status);
      // The version is compared again on restore to detect a committed
      // version bump. Not every repo has a readable version — tolerate that.
      String? version;
      try {
        version = await _getVersion.get(directory: repoDir);
      } catch (_) {
        version = null;
      }
      String? mainBranch = 'main';
      String? mainHead = await _localBranchHead(repoDir, 'main');
      if (mainHead == null) {
        mainBranch = 'master';
        mainHead = await _localBranchHead(repoDir, 'master');
        if (mainHead == null) {
          mainBranch = null;
        }
      }
      final remoteMainHead = mainBranch == null
          ? null
          : await _remoteBranchHead(repoDir, mainBranch);
      final remoteFeatureHead = detached
          ? null
          : await _remoteBranchHead(repoDir, rawBranch);
      final tags = (await _runGit(
        <String>['tag', '--list'],
        repoDir: repoDir,
      )).split('\n').map((t) => t.trim()).where((t) => t.isNotEmpty).toSet();
      ggLog(cDetail('✓ Saved state of $repoName'));
      return _RepoPublishSnapshot(
        directory: repoDir,
        branch: branch,
        head: head,
        status: status,
        version: version,
        mainBranch: mainBranch,
        mainHead: mainHead,
        remoteMainHead: remoteMainHead,
        remoteFeatureHead: remoteFeatureHead,
        tags: tags,
        stash: stash,
      );
    } catch (e) {
      throw Exception(
        cError(
          'Failed to save the state of $repoName before publishing — $repoName '
          'was not changed (repositories published earlier in this run stay '
          'published): $e',
        ),
      );
    }
  }

  /// Prints why publishing [repoName] failed, right where `failed` is recorded
  /// in the ticket's `.gg/gg-publish.json`. Without it the reason only shows
  /// up at the very end of the run, below the rollback output — and the
  /// per-repo detail gg_one logs is swallowed entirely without `--verbose`.
  /// The human-readable part of [error].
  ///
  /// Most failures are `Exception`s carrying a `message`, but not all: a
  /// `TypeError` has none, and reading it blindly used to replace the real
  /// cause with a `NoSuchMethodError`.
  static String _reasonOf(Object error) {
    try {
      final dynamic candidate = error;
      final message = candidate.message;
      if (message != null) {
        return message.toString();
      }
      // Every failure of the publish flows carries a message; the fallback
      // exists so an unexpected error type is reported instead of replacing
      // the real cause with a NoSuchMethodError.
      // coverage:ignore-start
    } catch (_) {
      // No »message« — fall through to toString().
    }
    return error.toString();
    // coverage:ignore-end
  }

  void _logPublishFailure({
    required String repoName,
    required Object error,
    required GgLog ggLog,
  }) {
    final reason = rmControls(_reasonOf(error)).trim();
    ggLog(
      [
        cDetail('✗ ${mergeOnly ? 'Merging' : 'Publishing'} $repoName failed'),
        if (reason.isNotEmpty) cError(reason),
      ].join('\n'),
    );
    ggLog(
      cAction(
        [
          'Fix the problem and resume with:',
          '  ${cCmd('$_command --continue')}',
          '  ${cCmd('$_command --restart')}',
        ].join('\n'),
      ),
    );
  }

  /// Restores the repository after a failed publish. Never throws — the
  /// publish failure that triggered the restore must stay the primary error.
  Future<void> _restoreRepoStateOnFailure({
    required _RepoPublishSnapshot snapshot,
    required GgLog ggLog,
    required GgLog taskLog,
  }) async {
    final repoName = path.basename(snapshot.directory.path);
    try {
      await GgStatusPrinter<void>(
        message: 'Restoring $repoName after the failed publish',
        ggLog: ggLog,
      ).run(
        () async => _restoreRepoState(
          snapshot: snapshot,
          ggLog: ggLog,
          taskLog: taskLog,
        ),
      );
    } catch (e) {
      final manual = StringBuffer(
        '"git checkout ${snapshot.branch}" + '
        '"git reset --hard ${snapshot.head}"',
      );
      if (snapshot.stash != null) {
        manual.write(' + "git stash apply --index ${snapshot.stash}"');
      }
      ggLog(
        cError(
          'Restoring $repoName after the failed publish failed — restore it '
          'manually ($manual): $e',
        ),
      );
    }
  }

  /// Brings the repository back to its snapshot after a failed publish.
  ///
  /// Two modes, because a publish has effects that must not be undone: when the
  /// failed run already *committed* a version bump (the registry release may
  /// exist — pub.dev/npm cannot be unpublished), already moved `origin/main`,
  /// or already pushed the feature branch, only half-done merges/rebases are
  /// ended and the original branch is checked out again; all commits are kept
  /// so a re-run of `gg do publish` resumes. Otherwise nothing irreversible
  /// happened and the full snapshot is restored: HEAD, default-branch
  /// position, tags and stashed changes (with the original staged/unstaged
  /// split).
  Future<void> _restoreRepoState({
    required _RepoPublishSnapshot snapshot,
    required GgLog ggLog,
    required GgLog taskLog,
  }) async {
    final s = snapshot;
    final repoDir = s.directory;
    final repoName = path.basename(repoDir.path);

    final headNow = await _runGit(<String>[
      'rev-parse',
      'HEAD',
    ], repoDir: repoDir);
    final statusNow = await _runGit(<String>[
      'status',
      '--porcelain',
    ], repoDir: repoDir);
    final branchNowFirst = await _runGit(<String>[
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ], repoDir: repoDir);
    if (headNow == s.head &&
        statusNow == s.status &&
        branchNowFirst == s.branch) {
      taskLog('Unchanged: $repoName');
      return;
    }

    // End half-done merges/rebases the failed publish may have left behind.
    await _runGit(
      <String>['merge', '--abort'],
      repoDir: repoDir,
      allowFailure: true,
    );
    await _runGit(
      <String>['rebase', '--abort'],
      repoDir: repoDir,
      allowFailure: true,
    );

    // Back to the original (feature) branch.
    final branchNow = await _runGit(<String>[
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ], repoDir: repoDir);
    if (branchNow != s.branch) {
      await _runGit(<String>['checkout', s.branch], repoDir: repoDir);
    }

    // Detect irreversible effects of the failed run. Read the state *after*
    // checking out the feature branch so the manifest-dirty check reflects it.
    final statusForDecision = await _runGit(<String>[
      'status',
      '--porcelain',
    ], repoDir: repoDir);
    String? versionNow;
    try {
      versionNow = await _getVersion.get(directory: repoDir);
    } catch (_) {
      versionNow = null;
    }
    final remoteMainNow = s.mainBranch == null
        ? null
        : await _remoteBranchHead(repoDir, s.mainBranch!);
    // Detached snapshots store the commit hash in `branch`; there is no
    // feature branch name to query then.
    final remoteFeatureNow = s.branch == s.head
        ? null
        : await _remoteBranchHead(repoDir, s.branch);

    // A version bump only counts as irreversible when it was *committed*
    // (gg_one commits the bump before touching the registry). An uncommitted
    // half-written bump left by a failed commit still shows in the working
    // tree — that is recoverable, so restore fully.
    final versionBumped =
        versionNow != s.version && !_manifestDirty(statusForDecision);
    // Only conclude the remote moved when we actually read a differing hash.
    // A failed/unreachable `git ls-remote` (often the very cause of the
    // rollback) returns null and must not masquerade as "already released".
    final remoteMainMoved =
        remoteMainNow != null && remoteMainNow != s.remoteMainHead;
    // The feature-branch commit already reached the remote; resetting local
    // behind it would desync the two and make the next run rebase onto it.
    final featurePushed =
        remoteFeatureNow != null && remoteFeatureNow != s.remoteFeatureHead;

    if (versionBumped || remoteMainMoved || featurePushed) {
      final String reason;
      if (versionBumped) {
        reason =
            'version ${versionNow ?? '?'} is already prepared and may '
            'already be published to the registry';
      } else if (remoteMainMoved) {
        reason = 'origin/${s.mainBranch} already received the release';
      } else {
        reason = 'the feature branch was already pushed to origin';
      }
      ggLog(
        cWarn(
          '$repoName: back on ${s.branch}, but all commits were kept '
          'because $reason. Re-running "$_command" resumes the $_action.',
        ),
      );
      return;
    }

    // Nothing irreversible happened — restore the full snapshot.
    await _runGit(<String>['reset', '--hard', s.head], repoDir: repoDir);

    // gg_one's runtime .gg/gg-publish.json is gitignored and survives the
    // reset — but its step markers describe commits that were just rolled
    // back, so they must not seed a later resume. Drop the file; the
    // keep-commits path above keeps it because there the steps stay real.
    final repoRuntimeFile = gg.DoConfigurePublish.configFileFor(repoDir);
    if (repoRuntimeFile.existsSync()) {
      repoRuntimeFile.deleteSync();
    }

    if (s.mainBranch != null &&
        s.mainBranch != s.branch &&
        s.mainHead != null) {
      final mainHeadNow = await _localBranchHead(repoDir, s.mainBranch!);
      if (mainHeadNow != null && mainHeadNow != s.mainHead) {
        await _runGit(<String>[
          'branch',
          '-f',
          s.mainBranch!,
          s.mainHead!,
        ], repoDir: repoDir);
      }
    }

    // Remove tags the failed run created.
    final tagsNow = (await _runGit(
      <String>['tag', '--list'],
      repoDir: repoDir,
    )).split('\n').map((t) => t.trim()).where((t) => t.isNotEmpty);
    for (final tag in tagsNow) {
      if (!s.tags.contains(tag)) {
        await _runGit(<String>['tag', '-d', tag], repoDir: repoDir);
      }
    }

    if (s.stash != null) {
      await _runGit(<String>[
        'stash',
        'apply',
        '--index',
        s.stash!,
      ], repoDir: repoDir);
    }

    taskLog(cDetail('✓ Restored the state before the publish in $repoName'));
    ggLog(
      cWarn(
        '$repoName: pushes to origin are not rolled back; the next run '
        'integrates them.',
      ),
    );
  }

  /// Waits for already published dependencies of [currentRepo] on pub.dev.
  Future<void> _waitForPublishedDependenciesIfNeeded({
    required Node currentRepo,
    required Map<String, _PublishedPackageState> publishedPackages,
    required Set<String> confirmedPubDevVersions,
    required GgLog ggLog,
  }) async {
    if (publishedPackages.isEmpty) {
      return;
    }

    final waitingStates = publishedPackages.values.where(
      (state) => state.waitsForPubDev,
    );

    for (final state in waitingStates) {
      final cacheKey = '${state.packageName}@${state.version}';
      if (confirmedPubDevVersions.contains(cacheKey)) {
        continue;
      }

      // The checkers announce the wait themselves (incl. the registry's
      // status page url), report progress while polling and fail with a
      // bounded timeout instead of hanging.
      await (state.target == gg_lang.PublishTarget.npm
          ? _npmChecker.waitUntilVersionAvailable(
              packageName: state.packageName,
              version: state.version,
              ggLog: ggLog,
              workingDirectory: state.repoDirPath,
            )
          : _pubDevChecker.waitUntilVersionAvailable(
              packageName: state.packageName,
              version: state.version,
              ggLog: ggLog,
            ));

      confirmedPubDevVersions.add(cacheKey);
    }
  }

  /// Refreshes dependencies for [repoDir] based on the detected project
  /// type. Runs `dart pub upgrade` for Dart/Flutter packages and the
  /// equivalent install command for TypeScript packages (npm/yarn/pnpm).
  Future<void> _refreshDependencies({
    required Directory repoDir,
    required String repoName,
    required GgLog ggLog,
    bool includeDart = true,
  }) async {
    // Bridge repos refresh via their TypeScript package manager
    // (checkProjectType: bridge → TS).
    final projectType = gg.checkProjectType(repoDir);

    final String executable;
    final List<String> args;
    switch (projectType) {
      case gg.ProjectType.dart:
      case gg.ProjectType.flutter:
        // The caller's upgrade step (»gg do upgrade deps«) resolves the
        // Dart side itself — skip the duplicate resolution here.
        if (!includeDart) {
          return;
        }
        executable = 'dart';
        args = <String>['pub', 'upgrade'];
      case gg.ProjectType.typescript:
        final pm = gg.detectTypeScriptPackageManager(repoDir);
        executable = pm.executable;
        args = <String>['install'];
      case gg.ProjectType.none:
        // Repos without a manifest have no dependencies to refresh.
        return;
    }

    // pnpm 11 blockExoticSubdeps must be off (env-var-only) for git chains.
    final Map<String, String>? envOverride =
        projectType == gg.ProjectType.typescript
        ? <String, String>{
            ...Platform.environment,
            'PNPM_CONFIG_BLOCK_EXOTIC_SUBDEPS': 'false',
          }
        : null;

    Future<void> runStep(
      String exe,
      List<String> stepArgs,
      Map<String, String>? env,
    ) async {
      final result = await _processRunner(
        exe,
        stepArgs,
        workingDirectory: repoDir.path,
        environment: env,
      );
      final cmd = '$exe ${stepArgs.join(' ')}';
      if (result.exitCode == 0) {
        ggLog(cDetail('✓ Executed $cmd in $repoName.'));
      } else {
        throw Exception(
          cError('Failed to execute $cmd in $repoName: ${result.stderr}'),
        );
      }
    }

    await runStep(executable, args, envOverride);

    // A cross-language bridge also carries a Dart manifest. checkProjectType
    // reports it as TypeScript, so the switch above only refreshed the
    // TypeScript package manager — refresh the Dart side too, so the rewritten
    // references are reflected in pubspec.lock as well. (The pnpm env override
    // is irrelevant to `dart pub upgrade`.)
    if (gg.isBridgeProject(repoDir) && includeDart) {
      await runStep('dart', <String>['pub', 'upgrade'], null);
    }
  }

  // Adds command line arguments
  void _addArgs() {
    argParser.addOption(
      'message',
      abbr: 'm',
      help: 'Default merge message of an interactive config',
    );
    argParser.addOption(
      'config',
      help: 'Path to a .gg-publish.json to publish with',
    );
    argParser.addFlag(
      'delete-remote-branch',
      help: 'Delete the remote feature branches (default)',
      defaultsTo: true,
      negatable: true,
    );
    argParser.addFlag(
      gg.panaOption,
      help: 'Run »dart run pana« as part of »can publish«.',
      defaultsTo: true,
      negatable: true,
    );
    argParser.addFlag(
      'pr',
      help: 'Merge via auto-merge pull request (default)',
      defaultsTo: true,
      negatable: true,
    );
    argParser.addFlag(
      'continue',
      help: 'Resume a failed publish where it stopped',
      defaultsTo: false,
      negatable: false,
    );
    argParser.addFlag(
      'publish-unchanged',
      help: 'Publish every repo, even an unchanged one',
      defaultsTo: false,
      negatable: false,
    );
    argParser.addFlag(
      'merge-only',
      help: 'Merge the ticket without releasing it',
      defaultsTo: false,
      negatable: false,
    );
    argParser.addFlag(
      'force',
      help: 'With --merge-only: merge despite local refs',
      defaultsTo: false,
      negatable: false,
    );
    argParser.addFlag(
      'restart',
      help: 'Discard the saved config and configure again',
      defaultsTo: false,
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

/// Stores publish state for already processed repositories.
class _PublishedPackageState {
  /// Creates a new published package state.
  const _PublishedPackageState({
    required this.packageName,
    required this.version,
    required this.waitsForPubDev,
    required this.target,
    required this.repoDirPath,
  });

  /// The public package name.
  final String packageName;

  /// The published version.
  final String version;

  /// Whether the next packages must wait for registry visibility.
  final bool waitsForPubDev;

  /// The registry this entry belongs to. A hybrid contributes one entry per
  /// registry, so a Dart dependent waits on pub.dev while an npm dependent
  /// waits on npm.
  final gg_lang.PublishTarget target;

  /// The repo directory — npm lookups run there so the project-level
  /// `.npmrc` (scoped/private registries) is honored.
  final String repoDirPath;
}

/// Mock for [DoPublishCommand]
class MockDoPublishCommand extends MockDirCommand<void>
    implements DoPublishCommand {}
