// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights
// Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
// ignore: lines_longer_than_80_chars
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_localize_refs/gg_localize_refs.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_multi_do_publish/src/backend/ensure_in_registry.dart';
import 'package:gg_multi_do_publish/src/backend/npm_registry_checker.dart';
import 'package:gg_multi_do_publish/src/backend/pub_dev_checker.dart';
import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_multi_do_publish/src/commands/can/publish.dart';
import 'package:gg_multi_commit/gg_multi_commit.dart';
import 'package:gg_multi_do_publish/src/commands/do/configure_publish.dart'
    show DoConfigurePublishCommand;
import 'package:gg_multi_do_publish/src/commands/do/publish.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

/// Mock for gg DoPublish
class MockGgDoPublish extends Mock implements gg.DoPublish {}

/// Mock for gg DoCommit
class MockGgDoCommit extends Mock implements gg.DoCommit {}

/// Mock for gg DoUpgradeDeps
class MockGgDoUpgradeDeps extends Mock implements gg.DoUpgradeDeps {}

/// Mock for gg CanCommit
class MockGgCanCommit extends Mock implements gg.CanCommit {}

/// Mock for gg DoPush
class MockGgDoPush extends Mock implements gg.DoPush {}

/// Mock for SortedProcessingList
class MockSortedProcessingList extends Mock implements SortedProcessingList {}

/// Mock for CanPublishCommand
class MockCanPublishCommand extends Mock implements CanPublishCommand {}

/// Mock for DoPushCommand
class MockDoPushCommand extends Mock implements DoPushCommand {}

/// Mock for DoConfigurePublishCommand
class MockConfigurePublishCommand extends Mock
    implements DoConfigurePublishCommand {}

/// Mock for UnlocalizeRefs
class MockUnlocalizeRefs extends Mock implements ChangeRefsToPubDev {}

/// Mock for ChangeRefsToLocal (the post-publish re-localization)
class MockLocalizeRefs extends Mock implements ChangeRefsToLocal {}

/// Mock for gg DidPublish
class MockGgDidPublish extends Mock implements gg.DidPublish {}

/// Mock for TicketState
class MockTicketState extends Mock implements TicketState {}

/// Mock for the cleanup-offer prompt
class MockInteractAdapter extends Mock implements gg.InteractAdapter {}

/// Mock for RestorePublishTo
class MockRestorePublishTo extends Mock implements RestorePublishTo {}

/// Mocks for version/ref helpers
class MockGetVersion extends Mock implements GetVersion {}

class MockSetRefVersion extends Mock implements SetRefVersion {}

class MockGetRefVersion extends Mock implements GetRefVersion {}

class MockPubDevChecker extends Mock implements PubDevChecker {}

/// Mock for [NpmRegistryChecker].
class MockNpmRegistryChecker extends Mock implements NpmRegistryChecker {}

class FakeDirectory extends Fake implements Directory {}

class FakeNode extends Fake implements Node {}

class MockDirectory extends Mock implements Directory {}

void main() {
  late Directory tempDir;
  late Directory ticketsDir;
  late Directory ticketDir;
  late MockEnsureInRegistry mockEnsureInRegistry;
  final messages = <String>[];
  // The same messages with their color codes intact, for tests that assert
  // how a message is highlighted.
  final coloredMessages = <String>[];

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
    registerFallbackValue(<Node>[]);
  });

  // Collects log messages while removing color codes.
  void ggLog(String msg) {
    coloredMessages.add(msg);
    messages.add(rmControls(msg));
  }

  setUp(() {
    messages.clear();
    coloredMessages.clear();
    mockEnsureInRegistry = MockEnsureInRegistry();
    when(
      () => mockEnsureInRegistry.ensure(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {});
    tempDir = Directory.systemTemp.createTempSync('do_publish_ticket_test_');
    ticketsDir = Directory(path.join(tempDir.path, 'tickets'))..createSync();
    ticketDir = Directory(path.join(ticketsDir.path, 'TICKPB'))..createSync();
    Directory(path.join(ticketDir.path, 'A')).createSync();
    Directory(path.join(ticketDir.path, 'B')).createSync();
    File(
      path.join(ticketDir.path, 'A', 'pubspec.yaml'),
    ).writeAsStringSync('name: A\n');
    // B is a Flutter package to cover the Flutter switch in refresh.
    File(
      path.join(ticketDir.path, 'B', 'pubspec.yaml'),
    ).writeAsStringSync('name: B\nflutter:\n');
    // A ready-made runtime publish config so the tests exercise `do publish`
    // non-interactively — it reuses .gg/gg-publish.json when present instead
    // of invoking the interactive `do configure-publish`.
    Directory(path.join(ticketDir.path, '.gg')).createSync();
    File(path.join(ticketDir.path, '.gg', 'gg-publish.json')).writeAsStringSync(
      '''
{
  "version_increment": "patch",
  "merge_message": "test merge"
}
''',
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('DoPublishCommand (ticket-wide)', () {
    test('fails outside any ticket folder', () async {
      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          // No injected collaborators: this run fails before any repo work,
          // so the default-constructed ones (incl. EnsureInRegistry) stay
          // unused — and the default construction is covered.
          makePublishCommand(ggLog: ggLog),
        );
      await expectLater(
        () async => await runner.run(['publish', '--input', tempDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            'Exception: Not inside a ticket folder',
          ),
        ),
      );
    });

    test('logs when there are no repositories', () async {
      final emptyTicket = Directory(path.join(ticketsDir.path, 'EMPTY'))
        ..createSync();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockConfigure = MockConfigurePublishCommand();

      // The empty ticket has no config file, so `do publish` configures it;
      // the mock returns an empty config without any interactive prompt.
      when(
        () => mockConfigure.configure(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => gg.PublishConfig());

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => <Node>[]);

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            didReviewCommand: mockDidReviewCommand,
            canPublishCommand: mockCanPublishCommand,
            sortedProcessingList: mockSortedProcessingList,
            doConfigurePublishCommand: mockConfigure,
          ),
        );
      await runner.run(['publish', '--input', emptyTicket.path]);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('checks did review before gg_multi can publish', () async {
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockSortedProcessingList = MockSortedProcessingList();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      // One repo, so the review gate is reached (an empty ticket returns
      // before it). The can-publish stub aborts the run right after the
      // ordered calls under test.
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
        ],
      );
      when(
        () => mockCanPublishCommand.checkTicket(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          verbose: any(named: 'verbose'),
          pana: any(named: 'pana'),
          includeCanPublish: any(named: 'includeCanPublish'),
        ),
      ).thenThrow(Exception('stop after can publish'));

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            didReviewCommand: mockDidReviewCommand,
            canPublishCommand: mockCanPublishCommand,
            sortedProcessingList: mockSortedProcessingList,
          ),
        );

      await expectLater(
        () => runner.run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Cannot publish.'),
          ),
        ),
      );

      verifyInOrder([
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
        () => mockCanPublishCommand.checkTicket(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          verbose: any(named: 'verbose'),
          pana: any(named: 'pana'),
          includeCanPublish: any(named: 'includeCanPublish'),
        ),
      ]);

      // The ticket wide call defers the per-repo gate; `exec` — which would
      // run the full check up front — is not used at all any more.
      verifyNever(
        () => mockCanPublishCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      );
    });

    test('aborts when the current state was not reviewed', () async {
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockConfigure = MockConfigurePublishCommand();

      // No config exists — the run would have to configure interactively.
      File(path.join(ticketDir.path, '.gg', 'gg-publish.json')).deleteSync();

      // The gate delegates to `gg did review`, whose chain reports the most
      // fundamental missing step — e.g. a missing commit — with its own
      // suggestion.
      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenThrow(Exception('Please run gg do commit.'));

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            didReviewCommand: mockDidReviewCommand,
            canPublishCommand: mockCanPublishCommand,
            doConfigurePublishCommand: mockConfigure,
          ),
        );

      await expectLater(
        () async => await runner.run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Please run gg do commit.'),
          ),
        ),
      );

      // The gate fires before the configuration is resolved: the interactive
      // version increment / merge message questions are never asked for a
      // state the publish refuses.
      verifyNever(
        () => mockConfigure.configure(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          defaultMergeMessage: any(named: 'defaultMergeMessage'),
          mergeOnly: any(named: 'mergeOnly'),
        ),
      );
      verifyNever(
        () => mockCanPublishCommand.checkTicket(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          verbose: any(named: 'verbose'),
          pana: any(named: 'pana'),
          includeCanPublish: any(named: 'includeCanPublish'),
        ),
      );
    });

    test('surfaces a merge conflict of the ticket checks unwrapped', () async {
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockCanPublishCommand = MockCanPublishCommand();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      // The push inside `can publish`'s ticket checks merges main into the
      // feature branches — a conflict there must reach the user unwrapped.
      when(
        () => mockCanPublishCommand.checkTicket(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          verbose: any(named: 'verbose'),
          pana: any(named: 'pana'),
          includeCanPublish: any(named: 'includeCanPublish'),
        ),
      ).thenThrow(
        MergeConflictException(
          'Merging origin/main into A produced conflicts:\n'
          ' - A/pubspec.yaml\n'
          'Please resolve the conflicts. Then execute: '
          "gg do commit -m 'Merge main' --no-log",
        ),
      );

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            didReviewCommand: mockDidReviewCommand,
            canPublishCommand: mockCanPublishCommand,
          ),
        );

      await expectLater(
        () async => await runner.run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<MergeConflictException>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(
              contains("gg do commit -m 'Merge main' --no-log"),
              isNot(contains('Cannot publish.')),
            ),
          ),
        ),
      );
    });

    test('publishes all repos, restores their workspace state and keeps '
        'the ticket', () async {
      // The VS Code workspace file of the ticket must survive the run.
      File(
        path.join(ticketDir.path, 'TICKPB.code-workspace'),
      ).writeAsStringSync('{"folders": []}');
      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockLocalizeRefs = MockLocalizeRefs();
      final mockGgDidPublish = MockGgDidPublish();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockLocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDidPublish.set(directory: any(named: 'directory')),
      ).thenAnswer((_) async {});

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(
              pubspec: Pubspec(
                'B',
                dependencies: <String, Dependency>{
                  'A': HostedDependency(
                    version: VersionConstraint.parse('^1.0.0'),
                  ),
                },
              ),
            ),
          ),
        ],
      );

      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');

      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);

      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer((invocation) async {
        final packageName = invocation.namedArguments[#packageName] as String;
        return PackagePublishInfo(
          packageName: packageName,
          waitsForPubDev: true,
        );
      });

      when(
        () => mockPubDevChecker.waitUntilVersionAvailable(
          packageName: any(named: 'packageName'),
          version: any(named: 'version'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            localizeRefs: mockLocalizeRefs,
            ggDidPublish: mockGgDidPublish,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );
      await runner.run(['publish', '--input', ticketDir.path, '--verbose']);

      expect(messages, contains('\nAll repos published\n'));
      expect(messages.any((m) => m.contains('A:')), isTrue);
      expect(messages.any((m) => m.contains('B:')), isTrue);

      // A productive run keeps the ticket: nothing moves to the trash and
      // the folder — VS Code workspace included — stays where it is.
      expect(
        Directory(path.join(tempDir.path, '.trash', 'TICKPB')).existsSync(),
        isFalse,
      );
      expect(ticketDir.existsSync(), isTrue);
      expect(Directory(path.join(ticketDir.path, 'A')).existsSync(), isTrue);
      expect(Directory(path.join(ticketDir.path, 'B')).existsSync(), isTrue);
      expect(
        File(path.join(ticketDir.path, 'TICKPB.code-workspace')).existsSync(),
        isTrue,
      );

      // The remote feature branches survive — work can simply continue.
      verifyNever(
        () => mockProcessRunner('git', [
          'push',
          'origin',
          '--delete',
          'TICKPB',
        ], workingDirectory: any(named: 'workingDirectory')),
      );

      // Every published repo went back to its feature branch, merged the
      // released main state, re-localized its references, recorded
      // didPublish and committed the restore as gg bookkeeping.
      verify(
        () => mockProcessRunner('git', [
          'checkout',
          'TICKPB',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).called(2);
      verify(
        () => mockProcessRunner('git', [
          'merge',
          '-m',
          '#gg: merge the published main back into TICKPB',
          'main',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).called(2);
      verify(
        () => mockLocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).called(2);
      verify(
        () => mockGgDidPublish.set(directory: any(named: 'directory')),
      ).called(2);
      verify(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: '#gg: restored local workspace references',
          force: true,
          updateChangeLog: false,
        ),
      ).called(2);

      // The user is told how to go on — the closing command in blue.
      expect(messages.join('\n'), contains('The ticket stays in place'));
      expect(coloredMessages, contains(cCmd('  gg do rm ticket TICKPB')));
    });

    test('waits on npm for a published TypeScript dependency', () async {
      // Make repo A a TypeScript project; B (Dart) depends on A.
      File(path.join(ticketDir.path, 'A', 'pubspec.yaml')).deleteSync();
      File(
        path.join(ticketDir.path, 'A', 'package.json'),
      ).writeAsStringSync('{"name": "A", "version": "1.0.0"}');
      File(
        path.join(ticketDir.path, 'A', 'tsconfig.json'),
      ).writeAsStringSync('{}');

      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      when(
        () => mockProcessRunner(
          'npm',
          ['install'],
          workingDirectory: any(named: 'workingDirectory'),
          environment: any(named: 'environment'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();
      final mockNpmChecker = MockNpmRegistryChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      stubCanPublish(mockCanPublishCommand);
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(
              pubspec: Pubspec(
                'B',
                dependencies: <String, Dependency>{
                  'A': HostedDependency(
                    version: VersionConstraint.parse('^1.0.0'),
                  ),
                },
              ),
            ),
          ),
        ],
      );
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});

      // The Dart repo B reports via pub.dev; the TypeScript repo A via npm.
      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer(
        (i) async => PackagePublishInfo(
          packageName: i.namedArguments[#packageName] as String,
          waitsForPubDev: false,
        ),
      );
      when(
        () => mockNpmChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer(
        (i) async => PackagePublishInfo(
          packageName: i.namedArguments[#packageName] as String,
          waitsForPubDev: true,
        ),
      );
      when(
        () => mockNpmChecker.waitUntilVersionAvailable(
          packageName: any(named: 'packageName'),
          version: any(named: 'version'),
          ggLog: any(named: 'ggLog'),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
            npmChecker: mockNpmChecker,
          ),
        );
      await runner.run(['publish', '--input', ticketDir.path, '--verbose']);

      // A's publish info is queried on npm (with A's repo dir so npm honors
      // its .npmrc), and B waits for A on npm.
      verify(
        () => mockNpmChecker.getPackagePublishInfo(
          packageName: 'A',
          workingDirectory: any(named: 'workingDirectory', that: isNotNull),
        ),
      ).called(1);
      verify(
        () => mockNpmChecker.waitUntilVersionAvailable(
          packageName: 'A',
          version: '1.0.0',
          ggLog: any(named: 'ggLog'),
          workingDirectory: any(named: 'workingDirectory', that: isNotNull),
        ),
      ).called(1);
    });

    test(
      'passes a per-repo merge message + increment to gg do publish',
      () async {
        // A per-repo override in the runtime config drives the merge
        // message and version increment gg_one receives (no
        // interactive editor anymore).
        File(
          path.join(ticketDir.path, '.gg', 'gg-publish.json'),
        ).writeAsStringSync('''
{
  "repos": {
    "A": { "version_increment": "minor", "merge_message": "per-repo msg" }
  }
}
''');

        final mockGgDoPublish = MockGgDoPublish();
        final mockGgDoCommit = MockGgDoCommit();
        final mockGgDoPush = MockGgDoPush();
        final mockUnlocalizeRefs = MockUnlocalizeRefs();
        final mockSortedProcessingList = MockSortedProcessingList();
        final mockProcessRunner = MockProcessRunner();
        _stubPubUpgrade(mockProcessRunner);
        _stubRepoSnapshot(mockProcessRunner);
        final mockCanPublishCommand = MockCanPublishCommand();
        final mockDidReviewCommand = MockDidReviewCommand();
        final mockGetVersion = MockGetVersion();
        final mockSetRefVersion = MockSetRefVersion();
        final mockGetRefVersion = MockGetRefVersion();
        final mockPubDevChecker = MockPubDevChecker();

        when(
          () => mockDidReviewCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});

        stubCanPublish(mockCanPublishCommand);

        when(
          () => mockSortedProcessingList.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer(
          (_) async => [
            Node(
              name: 'A',
              directory: Directory(path.join(ticketDir.path, 'A')),
              manifest: DartPackageManifest(pubspec: Pubspec('A')),
            ),
          ],
        );

        when(
          () => mockUnlocalizeRefs.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGgDoCommit.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            force: any(named: 'force'),
            updateChangeLog: any(named: 'updateChangeLog'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGgDoPush.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            force: any(named: 'force'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: any(named: 'versionIncrement'),
            channel: any(named: 'channel'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGetVersion.get(directory: any(named: 'directory')),
        ).thenAnswer((_) async => '1.0.0');
        when(
          () => mockGetRefVersion.get(
            directory: any(named: 'directory'),
            ref: any(named: 'ref'),
          ),
        ).thenAnswer((_) async => null);
        when(
          () => mockSetRefVersion.get(
            directory: any(named: 'directory'),
            ref: any(named: 'ref'),
            version: any(named: 'version'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockPubDevChecker.getPackagePublishInfo(
            packageName: any(named: 'packageName'),
          ),
        ).thenAnswer(
          (_) async =>
              const PackagePublishInfo(packageName: 'A', waitsForPubDev: false),
        );

        final runner = CommandRunner<void>('test', 'do publish ticket')
          ..addCommand(
            makePublishCommand(
              ggLog: ggLog,
              ensureInRegistry: mockEnsureInRegistry,
              ggDoPublish: mockGgDoPublish,
              ggDoCommit: mockGgDoCommit,
              ggDoPush: mockGgDoPush,
              unlocalizeRefs: mockUnlocalizeRefs,
              sortedProcessingList: mockSortedProcessingList,
              processRunner: mockProcessRunner.call,
              canPublishCommand: mockCanPublishCommand,
              didReviewCommand: mockDidReviewCommand,
              getVersionCommand: mockGetVersion,
              setRefVersionCommand: mockSetRefVersion,
              getRefVersionCommand: mockGetRefVersion,
              pubDevChecker: mockPubDevChecker,
            ),
          );

        await runner.run(['publish', '--input', ticketDir.path]);

        verify(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: 'per-repo msg',
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: 'minor',
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).called(1);
      },
    );

    test('forwards the release channel to gg do publish', () async {
      // Top-level channel: rc applies to repos without an override; a per-repo
      // channel override wins for that repo.
      File(
        path.join(ticketDir.path, '.gg', 'gg-publish.json'),
      ).writeAsStringSync('''
{
  "version_increment": "minor",
  "merge_message": "msg",
  "channel": "rc",
  "repos": {
    "B": { "channel": "stable" }
  }
}
''');

      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      stubCanPublish(mockCanPublishCommand);
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer(
        (_) async =>
            const PackagePublishInfo(packageName: 'A', waitsForPubDev: false),
      );

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

      await runner.run(['publish', '--input', ticketDir.path]);

      // A inherits the top-level rc channel …
      verify(
        () => mockGgDoPublish.exec(
          directory: any(
            named: 'directory',
            that: predicate<Directory>((dir) => dir.path.endsWith('A')),
          ),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: 'rc',
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).called(1);

      // … while B's per-repo override forces stable.
      verify(
        () => mockGgDoPublish.exec(
          directory: any(
            named: 'directory',
            that: predicate<Directory>((dir) => dir.path.endsWith('B')),
          ),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: 'stable',
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).called(1);
    });

    test('falls back to the top-level merge message + increment', () async {
      // No per-repo override: forRepo falls back to the top-level defaults.
      File(
        path.join(ticketDir.path, '.gg', 'gg-publish.json'),
      ).writeAsStringSync('''
{
  "version_increment": "major",
  "merge_message": "top-level msg"
}
''');

      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
        ],
      );

      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer(
        (_) async =>
            const PackagePublishInfo(packageName: 'A', waitsForPubDev: false),
      );

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

      await runner.run(['publish', '--input', ticketDir.path]);

      verify(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: 'top-level msg',
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: 'major',
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).called(1);
    });

    test('does not wait for dependency with publish_to none', () async {
      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      final aDir = Directory(path.join(ticketDir.path, 'A'));
      final bDir = Directory(path.join(ticketDir.path, 'B'));

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: aDir,
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
          Node(
            name: 'B',
            directory: bDir,
            manifest: DartPackageManifest(
              pubspec: Pubspec(
                'B',
                dependencies: <String, Dependency>{
                  'A': HostedDependency(
                    version: VersionConstraint.parse('^1.0.0'),
                  ),
                },
              ),
            ),
          ),
        ],
      );

      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockPubDevChecker.getPackagePublishInfo(packageName: 'A'),
      ).thenAnswer(
        (_) async =>
            const PackagePublishInfo(packageName: 'A', waitsForPubDev: false),
      );
      when(
        () => mockPubDevChecker.getPackagePublishInfo(packageName: 'B'),
      ).thenAnswer(
        (_) async =>
            const PackagePublishInfo(packageName: 'B', waitsForPubDev: true),
      );

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

      await runner.run(['publish', '--input', ticketDir.path]);

      verifyNever(
        () => mockPubDevChecker.waitUntilVersionAvailable(
          packageName: any(named: 'packageName'),
          version: any(named: 'version'),
          ggLog: any(named: 'ggLog'),
        ),
      );
    });

    test('aborts if can publish fails', () async {
      final mockGgDoPublish = MockGgDoPublish();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockCanPublishCommand.checkTicket(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          verbose: any(named: 'verbose'),
          pana: any(named: 'pana'),
          includeCanPublish: any(named: 'includeCanPublish'),
        ),
      ).thenThrow(Exception('can publish failed'));

      // The repo list is resolved before the review gate now.
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
        ],
      );

      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );
      await expectLater(
        () async => await runner.run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Cannot publish.'),
          ),
        ),
      );
    });

    test(
      'aborts on gg do publish failure for specific repo and keeps folder',
      () async {
        final mockGgDoPublish = MockGgDoPublish();
        final mockGgDoCommit = MockGgDoCommit();
        final mockGgDoPush = MockGgDoPush();
        final mockUnlocalizeRefs = MockUnlocalizeRefs();
        final mockSortedProcessingList = MockSortedProcessingList();
        final mockProcessRunner = MockProcessRunner();
        _stubPubUpgrade(mockProcessRunner);
        _stubRepoSnapshot(mockProcessRunner);
        final mockCanPublishCommand = MockCanPublishCommand();
        final mockDidReviewCommand = MockDidReviewCommand();
        final mockGetVersion = MockGetVersion();
        final mockSetRefVersion = MockSetRefVersion();
        final mockGetRefVersion = MockGetRefVersion();
        final mockPubDevChecker = MockPubDevChecker();

        when(
          () => mockDidReviewCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});

        stubCanPublish(mockCanPublishCommand);

        when(
          () => mockSortedProcessingList.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer(
          (_) async => [
            Node(
              name: 'A',
              directory: Directory(path.join(ticketDir.path, 'A')),
              manifest: DartPackageManifest(pubspec: Pubspec('A')),
            ),
            Node(
              name: 'B',
              directory: Directory(path.join(ticketDir.path, 'B')),
              manifest: DartPackageManifest(pubspec: Pubspec('B')),
            ),
          ],
        );

        when(
          () => mockUnlocalizeRefs.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});

        when(
          () => mockGgDoCommit.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            force: any(named: 'force'),
            updateChangeLog: any(named: 'updateChangeLog'),
          ),
        ).thenAnswer((_) async {});

        when(
          () => mockGgDoPush.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            force: any(named: 'force'),
          ),
        ).thenAnswer((_) async {});

        when(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: any(named: 'versionIncrement'),
            channel: any(named: 'channel'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((invocation) {
          final repoDir = invocation.namedArguments[#directory] as Directory;
          if (path.basename(repoDir.path) == 'B') {
            throw Exception('Publish failed for B');
          }
          return Future.value();
        });

        when(
          () => mockGetVersion.get(directory: any(named: 'directory')),
        ).thenAnswer((_) async => '1.0.0');
        when(
          () => mockGetRefVersion.get(
            directory: any(named: 'directory'),
            ref: any(named: 'ref'),
          ),
        ).thenAnswer((_) async => null);
        when(
          () => mockSetRefVersion.get(
            directory: any(named: 'directory'),
            ref: any(named: 'ref'),
            version: any(named: 'version'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockPubDevChecker.getPackagePublishInfo(
            packageName: any(named: 'packageName'),
          ),
        ).thenAnswer((invocation) async {
          final packageName = invocation.namedArguments[#packageName] as String;
          return PackagePublishInfo(
            packageName: packageName,
            waitsForPubDev: true,
          );
        });
        when(
          () => mockPubDevChecker.waitUntilVersionAvailable(
            packageName: any(named: 'packageName'),
            version: any(named: 'version'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});

        final runner = CommandRunner<void>('test', 'do publish ticket')
          ..addCommand(
            makePublishCommand(
              ggLog: ggLog,
              ensureInRegistry: mockEnsureInRegistry,
              ggDoPublish: mockGgDoPublish,
              ggDoCommit: mockGgDoCommit,
              ggDoPush: mockGgDoPush,
              unlocalizeRefs: mockUnlocalizeRefs,
              sortedProcessingList: mockSortedProcessingList,
              processRunner: mockProcessRunner.call,
              canPublishCommand: mockCanPublishCommand,
              didReviewCommand: mockDidReviewCommand,
              getVersionCommand: mockGetVersion,
              setRefVersionCommand: mockSetRefVersion,
              getRefVersionCommand: mockGetRefVersion,
              pubDevChecker: mockPubDevChecker,
            ),
          );
        await expectLater(
          () async => await runner.run(['publish', '--input', ticketDir.path]),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('Exception: Publish failed for B'),
            ),
          ),
        );

        // The reason is printed where »failed« is written into the config,
        // i.e. before the rollback output that would otherwise bury it.
        final reasonIndex = messages.indexWhere(
          (m) => m.contains('✗ Publishing B failed'),
        );
        expect(reasonIndex, isNonNegative);
        expect(messages[reasonIndex], contains('Publish failed for B'));
        // »Exception: « is stripped — the reason itself is the message.
        expect(messages[reasonIndex], isNot(contains('Exception:')));

        final hintIndex = messages.indexWhere(
          (m) => m.contains('gg do publish --continue'),
        );
        expect(hintIndex, reasonIndex + 1);
        expect(
          messages[hintIndex],
          contains('Fix the problem and resume with:'),
        );

        final restoreIndex = messages.indexWhere(
          (m) => m.contains('Restoring B after the failed publish'),
        );
        expect(restoreIndex, isNonNegative);
        expect(reasonIndex, lessThan(restoreIndex));

        // The »✗ … failed« line is a detail, the reason below it red, the
        // hint yellow with the command in blue.
        expect(coloredMessages[reasonIndex], startsWith('\x1B[90m'));
        expect(coloredMessages[reasonIndex], contains('\x1B[31m'));
        expect(coloredMessages[hintIndex], startsWith('\x1B[33m'));
        expect(
          coloredMessages[hintIndex],
          contains('\x1B[34mgg do publish --continue'),
        );

        // Repos must still exist in the ticket after a failed publish.
        expect(Directory(path.join(ticketDir.path, 'A')).existsSync(), isTrue);
        expect(Directory(path.join(ticketDir.path, 'B')).existsSync(), isTrue);
      },
    );

    test('aborts on unlocalize refs failure for specific repos', () async {
      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((invocation) {
        final repoDir = invocation.namedArguments[#directory] as Directory;
        if (path.basename(repoDir.path) == 'B') {
          throw Exception('Unlocalize failed for B');
        }
        return Future.value();
      });

      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer((invocation) async {
        final packageName = invocation.namedArguments[#packageName] as String;
        return PackagePublishInfo(
          packageName: packageName,
          waitsForPubDev: true,
        );
      });
      when(
        () => mockPubDevChecker.waitUntilVersionAvailable(
          packageName: any(named: 'packageName'),
          version: any(named: 'version'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );
      await expectLater(
        () async => await runner.run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains(
              'Failed to unlocalize refs for B: '
              'Exception: Unlocalize failed for B',
            ),
          ),
        ),
      );
    });

    test('aborts when GetVersion throws', () async {
      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
        ],
      );

      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenThrow(Exception('version read failed'));

      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer((invocation) async {
        final packageName = invocation.namedArguments[#packageName] as String;
        return PackagePublishInfo(
          packageName: packageName,
          waitsForPubDev: true,
        );
      });

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

      await expectLater(
        () async => await runner.run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains(
              'Failed to get version of A: Exception: '
              'version read failed',
            ),
          ),
        ),
      );
    });

    test(
      'updates dependency ref versions when a known ref is used later',
      () async {
        final mockGgDoPublish = MockGgDoPublish();
        final mockGgDoCommit = MockGgDoCommit();
        final mockGgDoPush = MockGgDoPush();
        final mockUnlocalizeRefs = MockUnlocalizeRefs();
        final mockSortedProcessingList = MockSortedProcessingList();
        final mockProcessRunner = MockProcessRunner();
        _stubPubUpgrade(mockProcessRunner);
        _stubRepoSnapshot(mockProcessRunner);
        final mockCanPublishCommand = MockCanPublishCommand();
        final mockDidReviewCommand = MockDidReviewCommand();
        final mockGetVersion = MockGetVersion();
        final mockSetRefVersion = MockSetRefVersion();
        final mockGetRefVersion = MockGetRefVersion();
        final mockPubDevChecker = MockPubDevChecker();

        when(
          () => mockDidReviewCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});

        stubCanPublish(mockCanPublishCommand);

        final aDir = Directory(path.join(ticketDir.path, 'A'));
        final bDir = Directory(path.join(ticketDir.path, 'B'));
        when(
          () => mockSortedProcessingList.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer(
          (_) async => [
            Node(
              name: 'A',
              directory: aDir,
              manifest: DartPackageManifest(pubspec: Pubspec('A')),
            ),
            Node(
              name: 'B',
              directory: bDir,
              manifest: DartPackageManifest(pubspec: Pubspec('B')),
            ),
          ],
        );

        when(
          () => mockUnlocalizeRefs.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});

        when(
          () => mockGetVersion.get(directory: aDir),
        ).thenAnswer((_) async => '1.2.3');
        when(
          () => mockGetVersion.get(directory: bDir),
        ).thenAnswer((_) async => '0.0.1');

        // General stub first; later (bDir, 'A') stub wins (mocktail).
        when(
          () => mockGetRefVersion.get(
            directory: any(named: 'directory'),
            ref: any(named: 'ref'),
          ),
        ).thenAnswer((_) async => null);

        when(
          () => mockGetRefVersion.get(directory: bDir, ref: 'A'),
        ).thenAnswer((_) async => '^any');

        when(
          () => mockSetRefVersion.get(
            directory: any(named: 'directory'),
            ref: any(named: 'ref'),
            version: any(named: 'version'),
          ),
        ).thenAnswer((_) async {});

        when(
          () => mockGgDoCommit.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            force: any(named: 'force'),
            updateChangeLog: any(named: 'updateChangeLog'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGgDoPush.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            force: any(named: 'force'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: any(named: 'versionIncrement'),
            channel: any(named: 'channel'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockPubDevChecker.getPackagePublishInfo(
            packageName: any(named: 'packageName'),
          ),
        ).thenAnswer((invocation) async {
          final packageName = invocation.namedArguments[#packageName] as String;
          return PackagePublishInfo(
            packageName: packageName,
            waitsForPubDev: true,
          );
        });
        when(
          () => mockPubDevChecker.waitUntilVersionAvailable(
            packageName: any(named: 'packageName'),
            version: any(named: 'version'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});

        final runner = CommandRunner<void>('test', 'do publish ticket')
          ..addCommand(
            makePublishCommand(
              ggLog: ggLog,
              ensureInRegistry: mockEnsureInRegistry,
              ggDoPublish: mockGgDoPublish,
              ggDoCommit: mockGgDoCommit,
              ggDoPush: mockGgDoPush,
              unlocalizeRefs: mockUnlocalizeRefs,
              sortedProcessingList: mockSortedProcessingList,
              processRunner: mockProcessRunner.call,
              canPublishCommand: mockCanPublishCommand,
              didReviewCommand: mockDidReviewCommand,
              getVersionCommand: mockGetVersion,
              setRefVersionCommand: mockSetRefVersion,
              getRefVersionCommand: mockGetRefVersion,
              pubDevChecker: mockPubDevChecker,
            ),
          );

        await runner.run(['publish', '--input', ticketDir.path]);

        verify(
          () => mockSetRefVersion.get(
            directory: bDir,
            ref: 'A',
            version: '1.2.3',
          ),
        ).called(1);
      },
    );

    test('aborts when updating dependent ref version fails', () async {
      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      final aDir = Directory(path.join(ticketDir.path, 'A'));
      final bDir = Directory(path.join(ticketDir.path, 'B'));
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: aDir,
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
          Node(
            name: 'B',
            directory: bDir,
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGetVersion.get(directory: aDir),
      ).thenAnswer((_) async => '2.0.0');
      when(
        () => mockGetVersion.get(directory: bDir),
      ).thenAnswer((_) async => '0.1.0');

      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockGetRefVersion.get(directory: bDir, ref: 'A'),
      ).thenAnswer((_) async => '^any');

      when(
        () =>
            mockSetRefVersion.get(directory: bDir, ref: 'A', version: '2.0.0'),
      ).thenThrow(Exception('update failed'));

      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer((invocation) async {
        final packageName = invocation.namedArguments[#packageName] as String;
        return PackagePublishInfo(
          packageName: packageName,
          waitsForPubDev: true,
        );
      });
      when(
        () => mockPubDevChecker.waitUntilVersionAvailable(
          packageName: any(named: 'packageName'),
          version: any(named: 'version'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

      await expectLater(
        () async => await runner.run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains(
              'Failed to update version of A in B: '
              'Exception: update failed',
            ),
          ),
        ),
      );
    });

    test('invokes RestorePublishTo after unlocalize for each repo', () async {
      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockRestorePublishTo = MockRestorePublishTo();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
        ],
      );

      final order = <String>[];
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {
        order.add('unlocalize');
      });
      when(
        () => mockRestorePublishTo.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {
        order.add('restore');
      });
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {
        order.add('commit');
      });
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer(
        (_) async =>
            const PackagePublishInfo(packageName: 'A', waitsForPubDev: false),
      );

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

      await runner.run(['publish', '--input', ticketDir.path]);

      // The second commit is the workspace restore after the publish.
      expect(order, ['unlocalize', 'restore', 'commit', 'commit']);
    });

    test('aborts when RestorePublishTo throws', () async {
      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockRestorePublishTo = MockRestorePublishTo();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      stubCanPublish(mockCanPublishCommand);
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
        ],
      );
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockRestorePublishTo.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenThrow(Exception('restore failed'));

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
          ),
        );

      await expectLater(
        () async => await runner.run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Failed to restore publish_to for A'),
          ),
        ),
      );
    });

    test('aborts when the dart refresh fails on a resume with step progress '
        '— the only path that still runs it', () async {
      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockRestorePublishTo = MockRestorePublishTo();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      stubCanPublish(mockCanPublishCommand);
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
        ],
      );
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockRestorePublishTo.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      // Stub `dart pub upgrade` so it fails with non-zero exit code.
      when(
        () => mockProcessRunner('dart', [
          'pub',
          'upgrade',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer(
        (_) async => ProcessResult(0, 1, '', 'pub upgrade exploded'),
      );

      // Give the run resumable progress: A failed and already carries
      // gg_one step progress, so the upgrade step is skipped and the
      // Dart refresh of _changeRefsToPubDev runs instead.
      Directory(path.join(ticketDir.path, '.gg')).createSync(recursive: true);
      File(
        path.join(ticketDir.path, '.gg', 'gg-publish.json'),
      ).writeAsStringSync(
        jsonEncode({
          'version_increment': 'patch',
          'merge_message': 'test merge',
          'repos': {
            'A': {'status': 'failed'},
          },
        }),
      );
      Directory(
        path.join(ticketDir.path, 'A', '.gg'),
      ).createSync(recursive: true);
      File(
        path.join(ticketDir.path, 'A', '.gg', 'gg-publish.json'),
      ).writeAsStringSync(
        jsonEncode({
          'version_increment': 'patch',
          'merge_message': 'test merge',
          'done_steps': ['prepare_version'],
        }),
      );

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
          ),
        );

      await expectLater(
        () async => await runner.run([
          'publish',
          '--input',
          ticketDir.path,
          '--continue',
        ]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Failed to execute dart pub upgrade in A'),
          ),
        ),
      );

      verifyNever(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      );
    });

    test(
      'runs npm install for typescript repos instead of dart pub upgrade',
      () async {
        // Swap pubspec for package.json+tsconfig so A becomes typescript.
        File(path.join(ticketDir.path, 'A', 'pubspec.yaml')).deleteSync();
        File(
          path.join(ticketDir.path, 'A', 'package.json'),
        ).writeAsStringSync(jsonEncode(<String, dynamic>{'name': 'A'}));
        File(
          path.join(ticketDir.path, 'A', 'tsconfig.json'),
        ).writeAsStringSync('{}');

        final mockGgDoPublish = MockGgDoPublish();
        final mockGgDoCommit = MockGgDoCommit();
        final mockGgDoPush = MockGgDoPush();
        final mockUnlocalizeRefs = MockUnlocalizeRefs();
        final mockRestorePublishTo = MockRestorePublishTo();
        final mockSortedProcessingList = MockSortedProcessingList();
        final mockProcessRunner = MockProcessRunner();
        _stubRepoSnapshot(mockProcessRunner);
        final mockCanPublishCommand = MockCanPublishCommand();
        final mockDidReviewCommand = MockDidReviewCommand();
        final mockGetVersion = MockGetVersion();
        final mockGetRefVersion = MockGetRefVersion();
        final mockSetRefVersion = MockSetRefVersion();
        final mockPubDevChecker = MockPubDevChecker();

        final repoADir = Directory(path.join(ticketDir.path, 'A'));

        when(
          () => mockDidReviewCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});
        stubCanPublish(mockCanPublishCommand);
        when(
          () => mockSortedProcessingList.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer(
          (_) async => [
            Node(
              name: 'A',
              directory: repoADir,
              manifest: TypeScriptPackageManifest(
                name: 'A',
                dependencies: const <String>[],
                devDependencies: const <String>[],
                rawJson: const <String, dynamic>{'name': 'A'},
              ),
            ),
          ],
        );
        when(
          () => mockUnlocalizeRefs.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockRestorePublishTo.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGetRefVersion.get(
            directory: any(named: 'directory'),
            ref: any(named: 'ref'),
          ),
        ).thenAnswer((_) async => null);
        when(
          () => mockSetRefVersion.get(
            directory: any(named: 'directory'),
            ref: any(named: 'ref'),
            version: any(named: 'version'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockProcessRunner(
            'npm',
            ['install'],
            workingDirectory: repoADir.path,
            environment: any(named: 'environment'),
          ),
        ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
        when(
          () => mockGgDoCommit.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            force: any(named: 'force'),
            updateChangeLog: any(named: 'updateChangeLog'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGgDoPush.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            force: any(named: 'force'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: any(named: 'versionIncrement'),
            channel: any(named: 'channel'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGetVersion.get(directory: any(named: 'directory')),
        ).thenAnswer((_) async => null);

        final runner = CommandRunner<void>('test', 'do publish ticket')
          ..addCommand(
            makePublishCommand(
              ggLog: ggLog,
              ensureInRegistry: mockEnsureInRegistry,
              ggDoPublish: mockGgDoPublish,
              ggDoCommit: mockGgDoCommit,
              ggDoPush: mockGgDoPush,
              unlocalizeRefs: mockUnlocalizeRefs,
              restorePublishTo: mockRestorePublishTo,
              sortedProcessingList: mockSortedProcessingList,
              processRunner: mockProcessRunner.call,
              canPublishCommand: mockCanPublishCommand,
              didReviewCommand: mockDidReviewCommand,
              getVersionCommand: mockGetVersion,
              setRefVersionCommand: mockSetRefVersion,
              getRefVersionCommand: mockGetRefVersion,
              pubDevChecker: mockPubDevChecker,
            ),
          );

        await runner.run(['publish', '--input', ticketDir.path]);

        // Two installs: one while the refs are pointed at the registry, one
        // when the workspace state is restored after the publish. Capture env
        // to assert PNPM_CONFIG_BLOCK_EXOTIC_SUBDEPS=false.
        final captured = verify(
          () => mockProcessRunner(
            'npm',
            ['install'],
            workingDirectory: repoADir.path,
            environment: captureAny(named: 'environment'),
          ),
        ).captured;
        expect(captured.length, 2);
        for (final env in captured.cast<Map<String, String>>()) {
          expect(env['PNPM_CONFIG_BLOCK_EXOTIC_SUBDEPS'], 'false');
        }

        verifyNever(
          () => mockProcessRunner('dart', [
            'pub',
            'upgrade',
          ], workingDirectory: any(named: 'workingDirectory')),
        );
      },
    );

    test('skips the dependency refresh for repos without a manifest', () async {
      // Remove the manifest — A becomes a git-only repo (ProjectType.none).
      File(path.join(ticketDir.path, 'A', 'pubspec.yaml')).deleteSync();

      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockRestorePublishTo = MockRestorePublishTo();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      final repoADir = Directory(path.join(ticketDir.path, 'A'));

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      stubCanPublish(mockCanPublishCommand);
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: repoADir,
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
        ],
      );
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockRestorePublishTo.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => null);

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

      await runner.run(['publish', '--input', ticketDir.path]);

      // Neither a Dart nor a TypeScript refresh command was executed.
      verifyNever(
        () => mockProcessRunner('dart', [
          'pub',
          'upgrade',
        ], workingDirectory: any(named: 'workingDirectory')),
      );
      verifyNever(
        () => mockProcessRunner(
          'npm',
          ['install'],
          workingDirectory: any(named: 'workingDirectory'),
          environment: any(named: 'environment'),
        ),
      );
    });

    test('runs npm install for bridge repos — the Dart side is resolved by '
        'the upgrade step, not by a duplicate refresh', () async {
      // Keep pubspec.yaml AND add package.json + tsconfig -> A is a bridge:
      // node_modules refresh via npm, pubspec.lock via »do upgrade deps«.
      File(
        path.join(ticketDir.path, 'A', 'package.json'),
      ).writeAsStringSync(jsonEncode(<String, dynamic>{'name': 'A'}));
      File(
        path.join(ticketDir.path, 'A', 'tsconfig.json'),
      ).writeAsStringSync('{}');

      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockRestorePublishTo = MockRestorePublishTo();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubRepoSnapshot(mockProcessRunner);
      // The workspace restore resolves the Dart side of the bridge.
      _stubPubUpgrade(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      final repoADir = Directory(path.join(ticketDir.path, 'A'));

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      stubCanPublish(mockCanPublishCommand);
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: repoADir,
            manifest: TypeScriptPackageManifest(
              name: 'A',
              dependencies: const <String>[],
              devDependencies: const <String>[],
              rawJson: const <String, dynamic>{'name': 'A'},
            ),
          ),
        ],
      );
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockRestorePublishTo.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockProcessRunner(
          'npm',
          ['install'],
          workingDirectory: repoADir.path,
          environment: any(named: 'environment'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockProcessRunner(
          'dart',
          ['pub', 'upgrade'],
          workingDirectory: repoADir.path,
          environment: any(named: 'environment'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => null);

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

      await runner.run(['publish', '--input', ticketDir.path]);

      // The pre-publish refresh handles the TypeScript install only (the
      // Dart side is covered by the upgrade step); the workspace restore
      // after the publish installs the TypeScript side again and resolves
      // the Dart side once.
      final captured = verify(
        () => mockProcessRunner(
          'npm',
          ['install'],
          workingDirectory: repoADir.path,
          environment: captureAny(named: 'environment'),
        ),
      ).captured;
      expect(captured.length, 2);
      for (final env in captured.cast<Map<String, String>>()) {
        expect(env['PNPM_CONFIG_BLOCK_EXOTIC_SUBDEPS'], 'false');
      }

      verify(
        () => mockProcessRunner(
          'dart',
          ['pub', 'upgrade'],
          workingDirectory: repoADir.path,
          environment: any(named: 'environment'),
        ),
      ).called(1);
    });

    test('refreshes BOTH sides of a bridge repo on a resume with step '
        'progress — the path where the upgrade step is skipped', () async {
      // Keep pubspec.yaml AND add package.json + tsconfig -> A is a bridge:
      // node_modules refresh via npm, pubspec.lock via »do upgrade deps«.
      File(
        path.join(ticketDir.path, 'A', 'package.json'),
      ).writeAsStringSync(jsonEncode(<String, dynamic>{'name': 'A'}));
      File(
        path.join(ticketDir.path, 'A', 'tsconfig.json'),
      ).writeAsStringSync('{}');

      final mockGgDoPublish = MockGgDoPublish();
      final mockGgDoCommit = MockGgDoCommit();
      final mockGgDoPush = MockGgDoPush();
      final mockUnlocalizeRefs = MockUnlocalizeRefs();
      final mockRestorePublishTo = MockRestorePublishTo();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      _stubRepoSnapshot(mockProcessRunner);
      final mockCanPublishCommand = MockCanPublishCommand();
      final mockDidReviewCommand = MockDidReviewCommand();
      final mockGetVersion = MockGetVersion();
      final mockGetRefVersion = MockGetRefVersion();
      final mockSetRefVersion = MockSetRefVersion();
      final mockPubDevChecker = MockPubDevChecker();

      final repoADir = Directory(path.join(ticketDir.path, 'A'));

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      stubCanPublish(mockCanPublishCommand);
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: repoADir,
            manifest: TypeScriptPackageManifest(
              name: 'A',
              dependencies: const <String>[],
              devDependencies: const <String>[],
              rawJson: const <String, dynamic>{'name': 'A'},
            ),
          ),
        ],
      );
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockRestorePublishTo.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockProcessRunner(
          'npm',
          ['install'],
          workingDirectory: repoADir.path,
          environment: any(named: 'environment'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockProcessRunner(
          'dart',
          ['pub', 'upgrade'],
          workingDirectory: repoADir.path,
          environment: any(named: 'environment'),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => null);

      final runner = CommandRunner<void>('test', 'do publish ticket')
        ..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

      // Give the run resumable progress so the upgrade step is skipped
      // and the full refresh (incl. the Dart side) runs instead.
      Directory(path.join(ticketDir.path, '.gg')).createSync(recursive: true);
      File(
        path.join(ticketDir.path, '.gg', 'gg-publish.json'),
      ).writeAsStringSync(
        jsonEncode({
          'version_increment': 'patch',
          'merge_message': 'test merge',
          'repos': {
            'A': {'status': 'failed'},
          },
        }),
      );
      Directory(
        path.join(ticketDir.path, 'A', '.gg'),
      ).createSync(recursive: true);
      File(
        path.join(ticketDir.path, 'A', '.gg', 'gg-publish.json'),
      ).writeAsStringSync(
        jsonEncode({
          'version_increment': 'patch',
          'merge_message': 'test merge',
          'done_steps': ['prepare_version'],
        }),
      );

      await runner.run(['publish', '--input', ticketDir.path, '--continue']);

      // On this path the upgrade step is skipped, so the pre-publish
      // refresh covers BOTH sides: the TypeScript install (with the pnpm
      // env override) AND the Dart pubspec.lock via dart pub upgrade. The
      // second call of each is the workspace restore after the publish.
      final captured = verify(
        () => mockProcessRunner(
          'npm',
          ['install'],
          workingDirectory: repoADir.path,
          environment: captureAny(named: 'environment'),
        ),
      ).captured;
      expect(captured.length, 2);
      for (final env in captured.cast<Map<String, String>>()) {
        expect(env['PNPM_CONFIG_BLOCK_EXOTIC_SUBDEPS'], 'false');
      }

      verify(
        () => mockProcessRunner(
          'dart',
          ['pub', 'upgrade'],
          workingDirectory: repoADir.path,
          environment: any(named: 'environment'),
        ),
      ).called(2);
    });
  });

  group('DoPublishCommand rollback on failure', () {
    late MockGgDoPublish mockGgDoPublish;
    late MockGgDoCommit mockGgDoCommit;
    late MockGgDoPush mockGgDoPush;
    late MockUnlocalizeRefs mockUnlocalizeRefs;
    late MockRestorePublishTo mockRestorePublishTo;
    late MockSortedProcessingList mockSortedProcessingList;
    late MockCanPublishCommand mockCanPublishCommand;
    late MockDidReviewCommand mockDidReviewCommand;
    late MockGetVersion mockGetVersion;
    late MockSetRefVersion mockSetRefVersion;
    late MockGetRefVersion mockGetRefVersion;
    late MockProcessRunner m;
    late String dirA;

    /// Creates a runner wired with all mocks of this group.
    CommandRunner<void> buildRunner() =>
        CommandRunner<void>('test', 'do publish ticket')..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoCommit: mockGgDoCommit,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            ggDoPush: mockGgDoPush,
            ggDoPublish: mockGgDoPublish,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: m.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
          ),
        );

    /// Makes `gg do publish` fail for the single repo A.
    void stubPublishFails() {
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenThrow(Exception('publish failed'));
    }

    /// Stubs `git rev-parse HEAD` so the snapshot sees [before] and every
    /// later call sees [after] — the failed publish moved HEAD.
    void stubHeadMoves(String before, String after) {
      var headCalls = 0;
      when(
        () => m('git', [
          'rev-parse',
          'HEAD',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer(
        (_) async => ProcessResult(0, 0, headCalls++ == 0 ? before : after, ''),
      );
    }

    setUp(() {
      mockGgDoPublish = MockGgDoPublish();
      mockGgDoCommit = MockGgDoCommit();
      mockGgDoPush = MockGgDoPush();
      mockUnlocalizeRefs = MockUnlocalizeRefs();
      mockRestorePublishTo = MockRestorePublishTo();
      mockSortedProcessingList = MockSortedProcessingList();
      mockCanPublishCommand = MockCanPublishCommand();
      mockDidReviewCommand = MockDidReviewCommand();
      mockGetVersion = MockGetVersion();
      mockSetRefVersion = MockSetRefVersion();
      mockGetRefVersion = MockGetRefVersion();
      m = MockProcessRunner();
      dirA = path.join(ticketDir.path, 'A');

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      stubCanPublish(mockCanPublishCommand);
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
        ],
      );
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockRestorePublishTo.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');
      _stubPubUpgrade(m);

      // Baseline git behaviour: clean repo on the feature branch with an
      // unchanged main. Individual tests override what their scenario needs.
      when(
        () => m('git', [
          'rev-parse',
          '--abbrev-ref',
          'HEAD',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'TICKPB', ''));
      when(
        () => m('git', [
          'rev-parse',
          'HEAD',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'h0', ''));
      when(
        () => m('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/main',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'm0', ''));
      when(
        () => m('git', [
          'ls-remote',
          'origin',
          'refs/heads/main',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'r0\trefs/heads/main', ''));
      when(
        () => m('git', [
          'ls-remote',
          'origin',
          'refs/heads/TICKPB',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer(
        (_) async => ProcessResult(0, 0, 'rf0\trefs/heads/TICKPB', ''),
      );
      when(
        () => m('git', [
          'tag',
          '--list',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      // A rollback tolerates failing aborts (nothing to abort).
      when(
        () => m('git', [
          'merge',
          '--abort',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', 'no merge'));
      when(
        () => m('git', [
          'rebase',
          '--abort',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', 'no rebase'));
    });

    test('restores HEAD, main position and new tags when nothing '
        'irreversible happened', () async {
      stubPublishFails();
      stubHeadMoves('h0', 'h1');

      // main moved locally during the failed run (m0 → m1) ...
      var mainCalls = 0;
      when(
        () => m('git', [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/main',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer(
        (_) async => ProcessResult(0, 0, mainCalls++ == 0 ? 'm0' : 'm1', ''),
      );
      // ... and the failed run created a tag.
      var tagCalls = 0;
      when(
        () => m('git', [
          'tag',
          '--list',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer(
        (_) async => ProcessResult(0, 0, tagCalls++ == 0 ? '' : 'v1.1.0', ''),
      );
      when(
        () => m('git', [
          'reset',
          '--hard',
          'h0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', [
          'branch',
          '-f',
          'main',
          'm0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', [
          'tag',
          '-d',
          'v1.1.0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('publish failed'),
          ),
        ),
      );

      verify(
        () => m('git', ['reset', '--hard', 'h0'], workingDirectory: dirA),
      ).called(1);
      verify(
        () => m('git', ['branch', '-f', 'main', 'm0'], workingDirectory: dirA),
      ).called(1);
      verify(
        () => m('git', ['tag', '-d', 'v1.1.0'], workingDirectory: dirA),
      ).called(1);
      expect(
        messages.any(
          (msg) => msg.contains('Restored the state before the publish in A'),
        ),
        isTrue,
      );
      expect(
        messages.any(
          (msg) => msg.contains('pushes to origin are not rolled back'),
        ),
        isTrue,
      );
    });

    test('a rejected per-repo gate takes the full restore path', () async {
      // The gate sits after the force-commit and BEFORE the push, so nothing
      // irreversible has happened when it rejects a repo: no version bump,
      // main unmoved, feature branch unpushed. That must full-restore the
      // repo — moving the gate below the push would silently downgrade this
      // to a cleanup restore, which keeps the commits and tells the user to
      // resume a failure that was entirely undoable.
      when(
        () => mockCanPublishCommand.checkRepo(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          pana: any(named: 'pana'),
        ),
      ).thenThrow(Exception('Cannot publish: A (Exception: pana failed)'));

      // HEAD moved because of the `#gg: changed references` commit.
      stubHeadMoves('h0', 'h1');
      when(
        () => m('git', [
          'reset',
          '--hard',
          'h0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Cannot publish: A'),
          ),
        ),
      );

      // The ref commit is thrown away — full restore, not cleanup restore.
      verify(
        () => m('git', ['reset', '--hard', 'h0'], workingDirectory: dirA),
      ).called(1);
      expect(
        messages.any(
          (msg) => msg.contains('Restored the state before the publish in A'),
        ),
        isTrue,
      );

      // Nothing was pushed and nothing was published before the rejection.
      verifyNever(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      );
      verifyNever(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      );
    });

    test('a full restore drops the repo-level .gg/gg-publish.json', () async {
      // The gitignored runtime file survives `reset --hard`, but its step
      // markers describe commits the rollback just removed.
      final repoRuntime = File(path.join(dirA, '.gg', 'gg-publish.json'))
        ..createSync(recursive: true);
      repoRuntime.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "done_steps": ["prepare_version"]
}
''');
      stubPublishFails();
      stubHeadMoves('h0', 'h1');
      when(
        () => m('git', [
          'reset',
          '--hard',
          'h0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );

      expect(repoRuntime.existsSync(), isFalse);
    });

    test('keeps all commits when the version was already bumped', () async {
      // The runtime file's steps stay real on the keep-commits path — a
      // later --continue resumes exactly there, so the file must survive.
      final repoRuntime = File(path.join(dirA, '.gg', 'gg-publish.json'))
        ..createSync(recursive: true);
      repoRuntime.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "done_steps": ["prepare_version"]
}
''');
      stubPublishFails();
      stubHeadMoves('h0', 'h1');

      // The snapshot sees 1.0.0, the restore sees the bumped 1.1.0 — the
      // registry may already carry the release, so nothing is reset.
      var versionCalls = 0;
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => versionCalls++ == 0 ? '1.0.0' : '1.1.0');

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );

      expect(repoRuntime.existsSync(), isTrue);

      verifyNever(
        () => m(
          'git',
          any(that: contains('reset')),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
      expect(
        messages.any(
          (msg) =>
              msg.contains('all commits were kept') &&
              msg.contains('resumes the publish'),
        ),
        isTrue,
      );
    });

    test('checks out the feature branch and keeps commits when origin/main '
        'already moved', () async {
      stubPublishFails();

      // The failed run left the repo on main ...
      var branchCalls = 0;
      when(
        () => m('git', [
          'rev-parse',
          '--abbrev-ref',
          'HEAD',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer(
        (_) async =>
            ProcessResult(0, 0, branchCalls++ == 0 ? 'TICKPB' : 'main', ''),
      );
      // ... and origin/main already received the release push (r0 → r9).
      var remoteCalls = 0;
      when(
        () => m('git', [
          'ls-remote',
          'origin',
          'refs/heads/main',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer(
        (_) async => ProcessResult(
          0,
          0,
          remoteCalls++ == 0 ? 'r0\trefs/heads/main' : 'r9\trefs/heads/main',
          '',
        ),
      );
      when(
        () => m('git', ['checkout', 'TICKPB'], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );

      verify(
        () => m('git', ['checkout', 'TICKPB'], workingDirectory: dirA),
      ).called(1);
      verifyNever(
        () => m(
          'git',
          any(that: contains('reset')),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
      expect(
        messages.any(
          (msg) => msg.contains('origin/main already received the release'),
        ),
        isTrue,
      );
    });

    test(
      'aborts before changing anything when saving the state fails',
      () async {
        when(
          () => m('git', [
            'rev-parse',
            '--abbrev-ref',
            'HEAD',
          ], workingDirectory: any(named: 'workingDirectory')),
        ).thenAnswer((_) async => ProcessResult(0, 1, '', 'not a repo'));

        await expectLater(
          () async => buildRunner().run([
            'publish',
            '--verbose',
            '--input',
            ticketDir.path,
          ]),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('Failed to save the state of A before publishing'),
            ),
          ),
        );

        verifyNever(
          () => mockUnlocalizeRefs.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        );
      },
    );

    test('logs a manual-recovery hint when the restore itself fails', () async {
      stubPublishFails();
      stubHeadMoves('h0', 'h1');
      // A dirty repo → the manual-recovery hint must also surface the stash
      // hash, otherwise following it would wipe the uncommitted changes.
      when(
        () => m('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, ' M lib/a.dart', ''));
      when(
        () => m('git', [
          'stash',
          'push',
          '--include-untracked',
          '--message',
          'gg-multi snapshot',
        ], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', ['rev-parse', 'stash@{0}'], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'stashsha', ''));
      when(
        () => m('git', [
          'stash',
          'apply',
          '--index',
          'stash@{0}',
        ], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', ['stash', 'drop', 'stash@{0}'], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', [
          'reset',
          '--hard',
          'h0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', 'reset boom'));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        // The publish failure stays the primary error.
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('publish failed'),
          ),
        ),
      );

      expect(
        messages.any(
          (msg) =>
              msg.contains('restore it manually') &&
              msg.contains('git reset --hard h0') &&
              msg.contains('git stash apply --index stashsha'),
        ),
        isTrue,
      );
    });

    test('falls back to master and tolerates unreachable remotes', () async {
      stubPublishFails();
      stubHeadMoves('h0', 'h1');

      // No main branch → the snapshot falls back to master.
      when(
        () => m('git', [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/main',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));
      when(
        () => m('git', [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/master',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'm0', ''));
      // The remote is unreachable at snapshot time and has no master branch
      // at restore time → both resolve to "unknown" and compare equal.
      var remoteCalls = 0;
      when(
        () => m('git', [
          'ls-remote',
          'origin',
          'refs/heads/master',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer(
        (_) async => remoteCalls++ == 0
            ? ProcessResult(0, 128, '', 'no connection')
            : ProcessResult(0, 0, '', ''),
      );
      when(
        () => m('git', [
          'reset',
          '--hard',
          'h0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );

      // Full restore ran; master did not move (m0 both times) → no branch -f.
      verify(
        () => m('git', ['reset', '--hard', 'h0'], workingDirectory: dirA),
      ).called(1);
      verifyNever(
        () => m(
          'git',
          any(that: contains('branch')),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      );
    });

    test('works without a default branch and an unreadable version', () async {
      stubPublishFails();
      stubHeadMoves('h0', 'h1');

      // Neither main nor master exist; the version is unreadable — both are
      // tolerated and the full restore still runs.
      when(
        () => m('git', [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/main',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));
      when(
        () => m('git', [
          'rev-parse',
          '--verify',
          '--quiet',
          'refs/heads/master',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', ''));
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenThrow(Exception('no version'));
      when(
        () => m('git', [
          'reset',
          '--hard',
          'h0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );

      verify(
        () => m('git', ['reset', '--hard', 'h0'], workingDirectory: dirA),
      ).called(1);
      // No default branch → neither main nor master is queried on the remote.
      // (The feature branch is still queried, so this is scoped to main/master.)
      verifyNever(
        () => m('git', [
          'ls-remote',
          'origin',
          'refs/heads/main',
        ], workingDirectory: any(named: 'workingDirectory')),
      );
      verifyNever(
        () => m('git', [
          'ls-remote',
          'origin',
          'refs/heads/master',
        ], workingDirectory: any(named: 'workingDirectory')),
      );
    });

    test('restores stashed uncommitted changes of a dirty repo', () async {
      stubPublishFails();
      stubHeadMoves('h0', 'h1');

      // The repo carries uncommitted changes → the snapshot stashes them
      // (push-with-untracked, record the hash, re-apply, drop).
      when(
        () => m('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, ' M lib/a.dart', ''));
      when(
        () => m('git', [
          'stash',
          'push',
          '--include-untracked',
          '--message',
          'gg-multi snapshot',
        ], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', ['rev-parse', 'stash@{0}'], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'stashsha', ''));
      when(
        () => m('git', [
          'stash',
          'apply',
          '--index',
          'stash@{0}',
        ], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', ['stash', 'drop', 'stash@{0}'], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', [
          'reset',
          '--hard',
          'h0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => m('git', [
          'stash',
          'apply',
          '--index',
          'stashsha',
        ], workingDirectory: dirA),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );

      verify(
        () => m('git', [
          'stash',
          'apply',
          '--index',
          'stashsha',
        ], workingDirectory: dirA),
      ).called(1);
    });

    test('fully restores an uncommitted half-written version bump', () async {
      stubPublishFails();
      stubHeadMoves('h0', 'h1');

      // gg_one wrote the new version into pubspec.yaml but its commit failed,
      // so the bump is uncommitted (shows in `git status`). That is
      // recoverable — nothing reached the registry — so restore fully.
      var versionCalls = 0;
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => versionCalls++ == 0 ? '1.0.0' : '1.1.0');
      // Clean at snapshot time, dirty (the half-bump) at restore time.
      var statusCalls = 0;
      when(
        () => m('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async {
        final out = statusCalls++ == 0 ? '' : ' M pubspec.yaml';
        return ProcessResult(0, 0, out, '');
      });
      when(
        () => m('git', [
          'reset',
          '--hard',
          'h0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );

      // The half-bump did not count as irreversible → full restore.
      verify(
        () => m('git', ['reset', '--hard', 'h0'], workingDirectory: dirA),
      ).called(1);
      expect(
        messages.any((msg) => msg.contains('all commits were kept')),
        isFalse,
      );
    });

    test(
      'keeps all commits when the feature branch was already pushed',
      () async {
        stubPublishFails();
        stubHeadMoves('h0', 'h1');

        // origin/<feature> advanced (rf0 → rf9): the failed run pushed the
        // feature commit, so resetting local below it would desync the two.
        var featureCalls = 0;
        when(
          () => m('git', [
            'ls-remote',
            'origin',
            'refs/heads/TICKPB',
          ], workingDirectory: any(named: 'workingDirectory')),
        ).thenAnswer(
          (_) async => ProcessResult(
            0,
            0,
            featureCalls++ == 0
                ? 'rf0\trefs/heads/TICKPB'
                : 'rf9\trefs/heads/TICKPB',
            '',
          ),
        );

        await expectLater(
          () async => buildRunner().run([
            'publish',
            '--verbose',
            '--input',
            ticketDir.path,
          ]),
          throwsA(isA<Exception>()),
        );

        verifyNever(
          () => m(
            'git',
            any(that: contains('reset')),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        );
        expect(
          messages.any(
            (msg) =>
                msg.contains(
                  'the feature branch was already pushed to origin',
                ) &&
                msg.contains('resumes the publish'),
          ),
          isTrue,
        );
      },
    );

    test('does not treat an unreachable remote as a moved main', () async {
      stubPublishFails();
      stubHeadMoves('h0', 'h1');

      // The snapshot read a concrete origin/main hash, but at restore time
      // `git ls-remote` fails (e.g. the network outage that broke the
      // publish). A null result must NOT masquerade as "already released".
      var remoteCalls = 0;
      when(
        () => m('git', [
          'ls-remote',
          'origin',
          'refs/heads/main',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer(
        (_) async => remoteCalls++ == 0
            ? ProcessResult(0, 0, 'r0\trefs/heads/main', '')
            : ProcessResult(0, 1, '', 'no connection'),
      );
      when(
        () => m('git', [
          'reset',
          '--hard',
          'h0',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await expectLater(
        () async => buildRunner().run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );

      // Full restore ran; the failed ls-remote did not force cleanup mode.
      verify(
        () => m('git', ['reset', '--hard', 'h0'], workingDirectory: dirA),
      ).called(1);
      expect(
        messages.any((msg) => msg.contains('already received the release')),
        isFalse,
      );
    });
  });

  group('DoPublishCommand configure + resume', () {
    late MockGgDoPublish mockGgDoPublish;
    late MockGgDoCommit mockGgDoCommit;
    late MockGgDoPush mockGgDoPush;
    late MockUnlocalizeRefs mockUnlocalizeRefs;
    late MockSortedProcessingList mockSortedProcessingList;
    late MockProcessRunner mockProcessRunner;
    late MockCanPublishCommand mockCanPublishCommand;
    late MockDidReviewCommand mockDidReviewCommand;
    late MockGetVersion mockGetVersion;
    late MockSetRefVersion mockSetRefVersion;
    late MockGetRefVersion mockGetRefVersion;
    late MockPubDevChecker mockPubDevChecker;
    late MockConfigurePublishCommand mockConfigure;
    late File runtimeFile;

    Node repoNode(String name) => Node(
      name: name,
      directory: Directory(path.join(ticketDir.path, name)),
      manifest: DartPackageManifest(pubspec: Pubspec(name)),
    );

    setUp(() {
      mockGgDoPublish = MockGgDoPublish();
      mockGgDoCommit = MockGgDoCommit();
      mockGgDoPush = MockGgDoPush();
      mockUnlocalizeRefs = MockUnlocalizeRefs();
      mockSortedProcessingList = MockSortedProcessingList();
      mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      mockCanPublishCommand = MockCanPublishCommand();
      mockDidReviewCommand = MockDidReviewCommand();
      mockGetVersion = MockGetVersion();
      mockSetRefVersion = MockSetRefVersion();
      mockGetRefVersion = MockGetRefVersion();
      mockPubDevChecker = MockPubDevChecker();
      mockConfigure = MockConfigurePublishCommand();
      runtimeFile = File(path.join(ticketDir.path, '.gg', 'gg-publish.json'));

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      stubCanPublish(mockCanPublishCommand);
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => [repoNode('A')]);
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');
      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);
      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer(
        (_) async =>
            const PackagePublishInfo(packageName: 'A', waitsForPubDev: false),
      );
    });

    CommandRunner<void> buildRunner() =>
        CommandRunner<void>('test', 'do publish ticket')..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
            doConfigurePublishCommand: mockConfigure,
          ),
        );

    test(
      'a registry-visibility lookup failure does not abort the publish',
      () async {
        // getPackagePublishInfo is a network read; a transient failure there
        // must not abort a run whose repo already published irreversibly.
        when(
          () => mockPubDevChecker.getPackagePublishInfo(
            packageName: any(named: 'packageName'),
          ),
        ).thenThrow(Exception('pub.dev unreachable'));

        await buildRunner().run(['publish', '--input', ticketDir.path]);

        expect(
          messages.any(
            (m) => m.contains('Could not check registry visibility'),
          ),
          isTrue,
        );
        // The repo still published, and the run completed.
        verify(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: any(named: 'versionIncrement'),
            channel: any(named: 'channel'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).called(1);
      },
    );

    test('--continue without a saved run throws a clear error', () async {
      runtimeFile.deleteSync();
      await expectLater(
        () => buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--continue',
        ]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Nothing to continue'),
          ),
        ),
      );
    });

    test(
      '--continue skips already-published repos and resumes the rest',
      () async {
        when(
          () => mockSortedProcessingList.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async => [repoNode('A'), repoNode('B')]);
        runtimeFile.writeAsStringSync('''
{
  "repos": {
    "A": {
      "version_increment": "patch", "merge_message": "m",
      "status": "published"
    },
    "B": {
      "version_increment": "patch", "merge_message": "m",
      "status": "pending"
    }
  }
}
''');

        await buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--continue',
        ]);

        // A was already published — it is skipped, only B is published.
        expect(messages, contains('\nA already published — skipping.'));
        verify(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: any(named: 'versionIncrement'),
            channel: any(named: 'channel'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).called(1);
        // Review + can-publish are skipped when resuming.
        verifyNever(
          () => mockDidReviewCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        );
      },
    );

    test('--restart ignores the saved config and reconfigures', () async {
      when(
        () => mockConfigure.configure(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => gg.PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'reconfigured',
        ),
      );

      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--restart',
      ]);

      verify(
        () => mockConfigure.configure(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).called(1);
    });

    test('-m is forwarded to configure as the default merge message', () async {
      // No config present → the interactive configure path runs, and -m is
      // handed to it as the default merge message.
      runtimeFile.deleteSync();
      when(
        () => mockConfigure.configure(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          defaultMergeMessage: any(named: 'defaultMergeMessage'),
        ),
      ).thenAnswer(
        (_) async => gg.PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'Release msg',
        ),
      );

      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '-m',
        'Release msg',
      ]);

      verify(
        () => mockConfigure.configure(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          defaultMergeMessage: 'Release msg',
        ),
      ).called(1);
    });

    test('reads the legacy <ticket>/.gg-publish.json when present', () async {
      runtimeFile.deleteSync();
      File(path.join(ticketDir.path, '.gg-publish.json')).writeAsStringSync('''
{
  "version_increment": "minor",
  "merge_message": "legacy msg"
}
''');

      await buildRunner().run(['publish', '--input', ticketDir.path]);

      verify(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: 'legacy msg',
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: 'minor',
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).called(1);
      verifyNever(
        () => mockConfigure.configure(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      );
    });

    test('--continue rejects a co-passed --config', () async {
      await expectLater(
        () => buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--continue',
          '--config',
          'x.json',
        ]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('cannot be combined'),
          ),
        ),
      );
    });

    test('--continue rejects --restart', () async {
      await expectLater(
        () => buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--continue',
          '--restart',
        ]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('cannot be combined'),
          ),
        ),
      );
    });

    test(
      'a plain re-run refuses a runtime file that still holds progress',
      () async {
        runtimeFile.writeAsStringSync('''
{
  "repos": {
    "A": {
      "version_increment": "patch", "merge_message": "m",
      "status": "failed"
    }
  }
}
''');
        await expectLater(
          () => buildRunner().run(['publish', '--input', ticketDir.path]),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('Unfinished publish in'),
            ),
          ),
        );
      },
    );

    test(
      '--continue after a review failure (nothing published) re-reviews',
      () async {
        runtimeFile.writeAsStringSync('''
{
  "repos": {
    "A": {
      "version_increment": "patch", "merge_message": "m",
      "status": "failed"
    }
  }
}
''');

        await buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--continue',
        ]);

        // No repo was published yet, so the review gate must still run.
        verify(
          () => mockDidReviewCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).called(1);
      },
    );

    test(
      'a fresh run passes resume: false and gitignores the runtime file',
      () async {
        await buildRunner().run(['publish', '--input', ticketDir.path]);

        // gg_one must not silently resume on a fresh gg_multi run.
        verify(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: any(named: 'versionIncrement'),
            channel: any(named: 'channel'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: false,
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).called(1);
        // The repo-level runtime file was gitignored before the pre-publish
        // commit, so gg_one's progress never shows up as an untracked file.
        final gitignore = File(path.join(ticketDir.path, 'A', '.gitignore'));
        expect(gitignore.existsSync(), isTrue);
        expect(gitignore.readAsStringSync(), contains('.gg/gg-publish.json'));
      },
    );

    test('--continue forwards resume: true to gg_one', () async {
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => [repoNode('A'), repoNode('B')]);
      runtimeFile.writeAsStringSync('''
{
  "repos": {
    "A": {
      "version_increment": "patch", "merge_message": "m",
      "status": "published"
    },
    "B": {
      "version_increment": "patch", "merge_message": "m",
      "status": "failed"
    }
  }
}
''');

      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--continue',
      ]);

      // Repo B is re-published in resume mode, so gg_one picks up at the
      // first step its own .gg/gg-publish.json marks as open.
      verify(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: true,
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).called(1);
    });

    test('--no-pr is forwarded to gg_one', () async {
      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--no-pr',
      ]);

      verify(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: false,
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).called(1);
    });

    test(
      'an absent --pr flag forwards null so persisted configs win',
      () async {
        await buildRunner().run(['publish', '--input', ticketDir.path]);

        verify(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: any(named: 'versionIncrement'),
            channel: any(named: 'channel'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: null,
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).called(1);
      },
    );

    test(
      '--continue skips review when a failed repo has step progress',
      () async {
        // First-repo failure AFTER irreversible steps: ticket file holds only
        // 'failed', but the repo-level file proves the partial publish —
        // re-reviewing the partially merged ticket would block the resume.
        runtimeFile.writeAsStringSync('''
{
  "repos": {
    "A": {
      "version_increment": "patch", "merge_message": "m",
      "status": "failed"
    }
  }
}
''');
        final repoRuntime = File(
          path.join(ticketDir.path, 'A', '.gg', 'gg-publish.json'),
        )..createSync(recursive: true);
        repoRuntime.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "done_steps": ["prepare_version", "publish_registry", "merge"]
}
''');

        await buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--continue',
        ]);

        verifyNever(
          () => mockDidReviewCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        );
      },
    );

    test('an unreadable repo progress file does not skip the review', () async {
      runtimeFile.writeAsStringSync('''
{
  "repos": {
    "A": {
      "version_increment": "patch", "merge_message": "m",
      "status": "failed"
    }
  }
}
''');
      final repoRuntime = File(
        path.join(ticketDir.path, 'A', '.gg', 'gg-publish.json'),
      )..createSync(recursive: true);
      repoRuntime.writeAsStringSync('{not valid json');

      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--continue',
      ]);

      // An unreadable file cannot prove progress — the review gate still
      // runs.
      verify(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).called(1);
    });

    test('--config refuses a runtime file that still holds progress', () async {
      runtimeFile.writeAsStringSync('''
{
  "repos": {
    "A": {
      "version_increment": "patch", "merge_message": "m",
      "status": "published"
    }
  }
}
''');

      await expectLater(
        () => buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--config',
          'x.json',
        ]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Unfinished publish in'),
          ),
        ),
      );
      // The progress markers survive untouched.
      expect(runtimeFile.readAsStringSync(), contains('"published"'));
    });

    test(
      '--config passes the guard when the runtime file has no progress',
      () async {
        // The setUp runtime file is config-only — --config may replace it.
        final configFile = File(path.join(ticketDir.path, 'plain.json'));
        configFile.writeAsStringSync(
          '{"version_increment":"major","merge_message":"plain msg"}',
        );

        await buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--config',
          'plain.json',
        ]);

        verify(
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: 'plain msg',
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: 'major',
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ).called(1);
      },
    );

    test('--config with --restart discards progress and proceeds', () async {
      runtimeFile.writeAsStringSync('''
{
  "repos": {
    "A": {
      "version_increment": "patch", "merge_message": "m",
      "status": "failed"
    }
  }
}
''');
      final configFile = File(path.join(ticketDir.path, 'fresh.json'));
      configFile.writeAsStringSync(
        '{"version_increment":"minor","merge_message":"fresh msg"}',
      );

      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--config',
        'fresh.json',
        '--restart',
      ]);

      verify(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: 'fresh msg',
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: 'minor',
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).called(1);
    });

    test('--restart removes the repo-level runtime files', () async {
      final repoRuntime = File(
        path.join(ticketDir.path, 'A', '.gg', 'gg-publish.json'),
      )..createSync(recursive: true);
      repoRuntime.writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "m",
  "done_steps": ["prepare_version"]
}
''');
      when(
        () => mockConfigure.configure(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          defaultMergeMessage: any(named: 'defaultMergeMessage'),
        ),
      ).thenAnswer(
        (_) async => gg.PublishConfig(
          versionIncrement: 'patch',
          mergeMessage: 'reconfigured',
        ),
      );

      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--restart',
      ]);

      // Stale gg_one step progress must not seed the reconfigured run.
      expect(repoRuntime.existsSync(), isFalse);
    });
  });

  group('DoPublishCommand skip unchanged repos', () {
    late MockGgDoPublish mockGgDoPublish;
    late MockGgDoCommit mockGgDoCommit;
    late MockGgDoPush mockGgDoPush;
    late MockUnlocalizeRefs mockUnlocalizeRefs;
    late MockSortedProcessingList mockSortedProcessingList;
    late MockProcessRunner mockProcessRunner;
    late MockCanPublishCommand mockCanPublishCommand;
    late MockDidReviewCommand mockDidReviewCommand;
    late MockGetVersion mockGetVersion;
    late MockSetRefVersion mockSetRefVersion;
    late MockGetRefVersion mockGetRefVersion;
    late MockPubDevChecker mockPubDevChecker;
    late MockPublishSkipCheck mockSkipCheck;

    setUpAll(() {
      registerFallbackValue(FakeNode());
      registerFallbackValue(<String, String>{});
    });

    setUp(() {
      mockGgDoPublish = MockGgDoPublish();
      mockGgDoCommit = MockGgDoCommit();
      mockGgDoPush = MockGgDoPush();
      mockUnlocalizeRefs = MockUnlocalizeRefs();
      mockSortedProcessingList = MockSortedProcessingList();
      mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      mockCanPublishCommand = MockCanPublishCommand();
      mockDidReviewCommand = MockDidReviewCommand();
      mockGetVersion = MockGetVersion();
      mockSetRefVersion = MockSetRefVersion();
      mockGetRefVersion = MockGetRefVersion();
      mockPubDevChecker = MockPubDevChecker();
      mockSkipCheck = MockPublishSkipCheck();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: Directory(path.join(ticketDir.path, 'A')),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');

      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer(
        (invocation) async =>
            invocation.namedArguments[#ref] == 'A' ? '^0.9.0' : null,
      );

      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer((invocation) async {
        final packageName = invocation.namedArguments[#packageName] as String;
        return PackagePublishInfo(
          packageName: packageName,
          waitsForPubDev: true,
        );
      });

      when(
        () => mockPubDevChecker.waitUntilVersionAvailable(
          packageName: any(named: 'packageName'),
          version: any(named: 'version'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
    });

    /// Builds the command under test with all mocks wired up.
    CommandRunner<void> buildRunner({
      gg.DidPublish? ggDidPublish,
      gg.InteractAdapter? interactAdapter,
      gg.HasTerminal? hasTerminal,
      TicketState? ticketState,
    }) => CommandRunner<void>('test', 'do publish ticket')
      ..addCommand(
        makePublishCommand(
          ggLog: ggLog,
          ensureInRegistry: mockEnsureInRegistry,
          ggDoPublish: mockGgDoPublish,
          ggDoCommit: mockGgDoCommit,
          ggDoPush: mockGgDoPush,
          unlocalizeRefs: mockUnlocalizeRefs,
          sortedProcessingList: mockSortedProcessingList,
          processRunner: mockProcessRunner.call,
          canPublishCommand: mockCanPublishCommand,
          didReviewCommand: mockDidReviewCommand,
          getVersionCommand: mockGetVersion,
          setRefVersionCommand: mockSetRefVersion,
          getRefVersionCommand: mockGetRefVersion,
          pubDevChecker: mockPubDevChecker,
          publishSkipCheck: mockSkipCheck,
          ggDidPublish: ggDidPublish,
          interactAdapter: interactAdapter,
          hasTerminal: hasTerminal,
          ticketState: ticketState,
        ),
      );

    /// Stubs the skip check: [skipped] repos skip, all others publish.
    void stubSkipCheck(Set<String> skipped) {
      when(
        () => mockSkipCheck.get(
          repo: any(named: 'repo'),
          refVersions: any(named: 'refVersions'),
        ),
      ).thenAnswer((invocation) async {
        final repo = invocation.namedArguments[#repo] as Node;
        return skipped.contains(repo.name)
            ? const PublishSkipDecision(skip: true, reason: 'Nothing changed.')
            : const PublishSkipDecision(
                skip: false,
                reason: 'the repo contains the manual commit »Fix bug«',
              );
      });
    }

    test('skips an unchanged repo and still propagates its version', () async {
      stubSkipCheck({'A'});

      await buildRunner().run(['publish', '--input', ticketDir.path]);

      // A is reported as skipped, in the repo line and in the summary.

      expect(messages[0], 'Publishing ...');

      expect(messages[1].split('\n'), [
        '',
        'A',
        '✓ Not published. Nothing changed.',
      ]);

      expect(messages[2].split('\n'), ['', 'B']);

      // Only B was published.
      final publishedDirs = verify(
        () => mockGgDoPublish.exec(
          directory: captureAny(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).captured.cast<Directory>();
      expect(publishedDirs, hasLength(1));
      expect(path.basename(publishedDirs.single.path), 'B');

      // The version of the skipped repo A still reached dependent B.
      verify(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: 'A',
          version: '1.0.0',
        ),
      ).called(1);

      // The full run succeeded, so the resume anchor is gone again.
      expect(
        File(path.join(ticketDir.path, '.gg', 'gg-publish.json')).existsSync(),
        isFalse,
      );
    });

    test(
      'keeps the localized refs of a skipped repo and records didPublish',
      () async {
        // A skipped repo stays workable: its references keep pointing at the
        // sibling checkouts, because the ticket stays in place. Only the
        // published repo is unlocalized for its release.
        stubSkipCheck({'A'});
        final mockGgDidPublish = MockGgDidPublish();
        when(
          () => mockGgDidPublish.set(directory: any(named: 'directory')),
        ).thenAnswer((_) async {});

        await buildRunner(
          ggDidPublish: mockGgDidPublish,
        ).run(['publish', '--input', ticketDir.path]);

        final unlocalized = verify(
          () => mockUnlocalizeRefs.get(
            directory: captureAny(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).captured.cast<Directory>().map((d) => path.basename(d.path));
        expect(unlocalized, isNot(contains('A')));
        expect(unlocalized, contains('B'));

        // Both repos are recorded as published: B by its publish, the
        // skipped A because its content is already released.
        final recorded = verify(
          () => mockGgDidPublish.set(directory: captureAny(named: 'directory')),
        ).captured.cast<Directory>().map((d) => path.basename(d.path));
        expect(recorded, containsAll(<String>['A', 'B']));
      },
    );

    test('reports a didPublish marker that could not be written and '
        'continues', () async {
      stubSkipCheck({'A'});
      final mockGgDidPublish = MockGgDidPublish();
      when(
        () => mockGgDidPublish.set(
          directory: any(
            named: 'directory',
            that: predicate<Directory>((d) => path.basename(d.path) == 'A'),
          ),
        ),
      ).thenThrow(Exception('no commits yet'));
      when(
        () => mockGgDidPublish.set(
          directory: any(
            named: 'directory',
            that: predicate<Directory>((d) => path.basename(d.path) == 'B'),
          ),
        ),
      ).thenAnswer((_) async {});

      await buildRunner(
        ggDidPublish: mockGgDidPublish,
      ).run(['publish', '--input', ticketDir.path, '--verbose']);

      expect(
        messages.any((m) => m.contains('Could not record didPublish for A')),
        isTrue,
      );

      // The run still finished: the resume anchor is gone again.
      expect(
        File(path.join(ticketDir.path, '.gg', 'gg-publish.json')).existsSync(),
        isFalse,
      );
    });

    test(
      'saves and restores pubspec_overrides.yaml around a publish',
      () async {
        stubSkipCheck({'A'});
        const overrides = 'dependency_overrides:\n  A:\n    path: ../A\n';
        File(
          path.join(ticketDir.path, 'B', 'pubspec_overrides.yaml'),
        ).writeAsStringSync(overrides);

        await buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--verbose',
        ]);

        final log = messages.join('\n');
        expect(
          log,
          contains(
            '✓ B: saved pubspec_overrides.yaml to '
            '.gg/pubspec_overrides_backup.yaml.',
          ),
        );
        expect(log, contains('✓ B: restored pubspec_overrides.yaml.'));

        // The overrides file is back and the backup is consumed.
        expect(
          File(
            path.join(ticketDir.path, 'B', 'pubspec_overrides.yaml'),
          ).readAsStringSync(),
          overrides,
        );
        expect(
          File(
            path.join(
              ticketDir.path,
              'B',
              '.gg',
              'pubspec_overrides_backup.yaml',
            ),
          ).existsSync(),
          isFalse,
        );
      },
    );

    test('warns when the workspace state could not be restored', () async {
      stubSkipCheck(<String>{});
      when(
        () => mockProcessRunner('git', [
          'checkout',
          'TICKPB',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', 'checkout broken'));

      await buildRunner().run(['publish', '--input', ticketDir.path]);

      // The publish itself succeeded — the restore failure is a warning,
      // and the run still completes.
      final log = messages.join('\n');
      expect(log, contains('workspace state could not be restored'));
      expect(log, contains('All repos published'));
    });

    test('aborts the merge and warns when the sync-back conflicts', () async {
      stubSkipCheck(<String>{});
      when(
        () => mockProcessRunner('git', [
          'merge',
          '-m',
          '#gg: merge the published main back into TICKPB',
          'main',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 1, '', 'conflict'));
      when(
        () => mockProcessRunner('git', [
          'merge',
          '--abort',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      await buildRunner().run(['publish', '--input', ticketDir.path]);

      final log = messages.join('\n');
      expect(log, contains('Could not merge main back into TICKPB'));
      // The rest of the restore still ran.
      expect(log, contains('back on TICKPB — local references restored'));
    });

    test('warns when the didReview state cannot be refreshed', () async {
      stubSkipCheck({'A', 'B'});
      final ticketState = MockTicketState();
      when(
        () => ticketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: any(named: 'key'),
          ignoreUnstaged: any(named: 'ignoreUnstaged'),
        ),
      ).thenThrow(Exception('no git'));

      await buildRunner(
        ticketState: ticketState,
      ).run(['publish', '--input', ticketDir.path]);

      expect(
        messages.join('\n'),
        contains('Could not refresh the didReview state'),
      );
    });

    test('re-blesses didReview at the end of a successful run', () async {
      stubSkipCheck({'A', 'B'});
      final ticketState = MockTicketState();
      when(
        () => ticketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: any(named: 'key'),
          ignoreUnstaged: any(named: 'ignoreUnstaged'),
        ),
      ).thenAnswer((_) async {});

      await buildRunner(
        ticketState: ticketState,
      ).run(['publish', '--input', ticketDir.path]);

      verify(
        () => ticketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: 'didReview',
        ),
      ).called(1);
    });

    group('the end-of-run cleanup offer', () {
      test('offers the cleanup and trashes the ticket on accept', () async {
        // Both repos skip — the run publishes nothing.
        stubSkipCheck({'A', 'B'});
        File(
          path.join(ticketDir.path, 'TICKPB.code-workspace'),
        ).writeAsStringSync('{"folders": []}');
        when(
          () => mockProcessRunner('git', [
            'push',
            'origin',
            '--delete',
            'TICKPB',
          ], workingDirectory: any(named: 'workingDirectory')),
        ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

        final adapter = MockInteractAdapter();
        when(
          () => adapter.choose(
            message: any(named: 'message'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => 0);

        await buildRunner(
          interactAdapter: adapter,
          hasTerminal: () => true,
        ).run(['publish', '--input', ticketDir.path]);

        // The offer names both ways out.
        final options =
            verify(
                  () => adapter.choose(
                    message: any(named: 'message'),
                    options: captureAny(named: 'options'),
                  ),
                ).captured.single
                as List<String>;
        expect(options, hasLength(2));
        expect(options.first, contains('.trash'));
        expect(options.last, contains('gg do rm ticket'));

        // Everything moved to the trash, the remote branches are gone and
        // the way to the workspace root is printed in blue.
        final trashDir = Directory(path.join(tempDir.path, '.trash', 'TICKPB'));
        expect(Directory(path.join(trashDir.path, 'A')).existsSync(), isTrue);
        expect(Directory(path.join(trashDir.path, 'B')).existsSync(), isTrue);
        expect(
          File(path.join(trashDir.path, 'TICKPB.code-workspace')).existsSync(),
          isTrue,
        );
        // The ticket's own files travelled along — the folder moved as one.
        expect(
          File(path.join(trashDir.path, '.gg', 'gg-publish.json')).existsSync(),
          isFalse,
          reason: 'the runtime file is deleted on success, before the move',
        );
        expect(ticketDir.existsSync(), isFalse);
        verify(
          () => mockProcessRunner('git', [
            'push',
            'origin',
            '--delete',
            'TICKPB',
          ], workingDirectory: any(named: 'workingDirectory')),
        ).called(2);
        expect(
          messages.join('\n'),
          contains('Change to the workspace root with:'),
        );
        expect(coloredMessages, contains(cCmd('  cd ${tempDir.path}')));
      });

      test('also appears after a run that actually published', () async {
        // Nothing skips — both repos go through the full publish.
        stubSkipCheck(<String>{});
        File(
          path.join(ticketDir.path, 'ticket.json'),
        ).writeAsStringSync('{"issue_id":"TICKPB"}');
        when(
          () => mockProcessRunner('git', [
            'push',
            'origin',
            '--delete',
            'TICKPB',
          ], workingDirectory: any(named: 'workingDirectory')),
        ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

        final adapter = MockInteractAdapter();
        when(
          () => adapter.choose(
            message: any(named: 'message'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => 0);

        await buildRunner(
          interactAdapter: adapter,
          hasTerminal: () => true,
        ).run(['publish', '--input', ticketDir.path]);

        // The question is asked up front, before the first repo is
        // published — no prompt sits between the irreversible steps.
        verifyInOrder([
          () => adapter.choose(
            message: any(named: 'message'),
            options: any(named: 'options'),
          ),
          () => mockGgDoPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            message: any(named: 'message'),
            deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
            verbose: any(named: 'verbose'),
            versionIncrement: any(named: 'versionIncrement'),
            channel: any(named: 'channel'),
            askBeforePublishing: any(named: 'askBeforePublishing'),
            resume: any(named: 'resume'),
            pr: any(named: 'pr'),
            mergeOnly: any(named: 'mergeOnly'),
            force: any(named: 'force'),
            options: any(named: 'options'),
          ),
        ]);

        // Accepting moves the whole ticket — repos and metadata alike.
        final trashDir = Directory(path.join(tempDir.path, '.trash', 'TICKPB'));

        expect(Directory(path.join(trashDir.path, 'A')).existsSync(), isTrue);
        expect(Directory(path.join(trashDir.path, 'B')).existsSync(), isTrue);
        expect(
          File(path.join(trashDir.path, 'ticket.json')).readAsStringSync(),
          '{"issue_id":"TICKPB"}',
        );
        expect(ticketDir.existsSync(), isFalse);
      });

      test('keeps a productive run workable when the user declines', () async {
        stubSkipCheck(<String>{});
        final adapter = MockInteractAdapter();
        when(
          () => adapter.choose(
            message: any(named: 'message'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => 1);

        await buildRunner(
          interactAdapter: adapter,
          hasTerminal: () => true,
        ).run(['publish', '--input', ticketDir.path]);

        expect(ticketDir.existsSync(), isTrue);
        expect(Directory(path.join(ticketDir.path, 'A')).existsSync(), isTrue);
        expect(messages.join('\n'), contains('The ticket stays in place'));
        expect(coloredMessages, contains(cCmd('  gg do rm ticket TICKPB')));
      });

      test('keeps the ticket when the user declines', () async {
        stubSkipCheck({'A', 'B'});
        final adapter = MockInteractAdapter();
        when(
          () => adapter.choose(
            message: any(named: 'message'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async => 1);

        await buildRunner(
          interactAdapter: adapter,
          hasTerminal: () => true,
        ).run(['publish', '--input', ticketDir.path]);

        expect(ticketDir.existsSync(), isTrue);
        expect(
          Directory(path.join(tempDir.path, '.trash', 'TICKPB')).existsSync(),
          isFalse,
        );
        expect(coloredMessages, contains(cCmd('  gg do rm ticket TICKPB')));
      });

      test(
        'keeps the ticket without asking when stdin is no terminal',
        () async {
          stubSkipCheck({'A', 'B'});
          final adapter = MockInteractAdapter();

          await buildRunner(
            interactAdapter: adapter,
            hasTerminal: () => false,
          ).run(['publish', '--input', ticketDir.path]);

          verifyNever(
            () => adapter.choose(
              message: any(named: 'message'),
              options: any(named: 'options'),
            ),
          );
          expect(ticketDir.existsSync(), isTrue);
        },
      );

      test(
        '--no-delete-remote-branch keeps the branches when trashing',
        () async {
          stubSkipCheck({'A', 'B'});
          final adapter = MockInteractAdapter();
          when(
            () => adapter.choose(
              message: any(named: 'message'),
              options: any(named: 'options'),
            ),
          ).thenAnswer((_) async => 0);

          await buildRunner(
            interactAdapter: adapter,
            hasTerminal: () => true,
          ).run([
            'publish',
            '--input',
            ticketDir.path,
            '--no-delete-remote-branch',
          ]);

          // Trashed, but no branch deletion was attempted.
          expect(ticketDir.existsSync(), isFalse);
          verifyNever(
            () => mockProcessRunner('git', [
              'push',
              'origin',
              '--delete',
              'TICKPB',
            ], workingDirectory: any(named: 'workingDirectory')),
          );
        },
      );
    });

    test('--publish-unchanged publishes every repo unchecked', () async {
      stubSkipCheck({'A', 'B'});

      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--publish-unchanged',
      ]);

      verifyNever(
        () => mockSkipCheck.get(
          repo: any(named: 'repo'),
          refVersions: any(named: 'refVersions'),
        ),
      );

      final publishedDirs = verify(
        () => mockGgDoPublish.exec(
          directory: captureAny(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).captured.cast<Directory>();
      expect(publishedDirs.map((d) => path.basename(d.path)), ['A', 'B']);
    });

    test('a later failure persists the skipped marker', () async {
      stubSkipCheck({'A'});

      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenThrow(Exception('registry down'));

      await expectLater(
        () => buildRunner().run(['publish', '--input', ticketDir.path]),
        throwsA(isA<Exception>()),
      );

      // The runtime file survives the failure and holds both markers —
      // and gg_one's config loader accepts the skipped status.
      final runtimeFile = File(
        path.join(ticketDir.path, '.gg', 'gg-publish.json'),
      );
      expect(runtimeFile.existsSync(), isTrue);
      final config = gg.PublishConfig.load(
        configArg: runtimeFile.path,
        fallbackDir: ticketDir.path,
      );
      expect(config.statusForRepo('A'), 'skipped');
      expect(config.statusForRepo('B'), 'failed');
    });

    test('--continue re-evaluates a previously skipped repo', () async {
      // A previous run skipped A and published B, then the user added a
      // manual commit to A. The resume must publish A instead of trusting
      // the stale marker.
      File(
        path.join(ticketDir.path, '.gg', 'gg-publish.json'),
      ).writeAsStringSync('''
{
  "version_increment": "patch",
  "merge_message": "test merge",
  "repos": {
    "A": { "status": "skipped" },
    "B": { "status": "published" }
  }
}
''');
      stubSkipCheck(const {});

      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--continue',
      ]);

      // The skip check ran exactly once — for A; B was short-circuited by
      // its published marker.
      final checkedRepos = verify(
        () => mockSkipCheck.get(
          repo: captureAny(named: 'repo'),
          refVersions: any(named: 'refVersions'),
        ),
      ).captured.cast<Node>();
      expect(checkedRepos.map((n) => n.name), ['A']);

      final publishedDirs = verify(
        () => mockGgDoPublish.exec(
          directory: captureAny(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).captured.cast<Directory>();
      expect(publishedDirs.map((d) => path.basename(d.path)), ['A']);

      expect(messages, contains('\nB already published — skipping.'));
    });
  });

  group('DoPublishCommand in merge mode', () {
    late MockGgDoPublish mockGgDoPublish;
    late MockGgDoCommit mockGgDoCommit;
    late MockGgDoPush mockGgDoPush;
    late MockUnlocalizeRefs mockUnlocalizeRefs;
    late MockRestorePublishTo mockRestorePublishTo;
    late MockSortedProcessingList mockSortedProcessingList;
    late MockProcessRunner mockProcessRunner;
    late MockCanPublishCommand mockCanPublishCommand;
    late MockDidReviewCommand mockDidReviewCommand;
    late MockGetVersion mockGetVersion;
    late MockSetRefVersion mockSetRefVersion;
    late MockGetRefVersion mockGetRefVersion;
    late MockPubDevChecker mockPubDevChecker;

    setUp(() {
      mockGgDoPublish = MockGgDoPublish();
      mockGgDoCommit = MockGgDoCommit();
      mockGgDoPush = MockGgDoPush();
      mockUnlocalizeRefs = MockUnlocalizeRefs();
      mockRestorePublishTo = MockRestorePublishTo();
      mockSortedProcessingList = MockSortedProcessingList();
      mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      // The ticket is trashed after a merge too, remote branches included.
      when(
        () => mockProcessRunner('git', [
          'push',
          'origin',
          '--delete',
          'TICKPB',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      mockCanPublishCommand = MockCanPublishCommand();
      mockDidReviewCommand = MockDidReviewCommand();
      mockGetVersion = MockGetVersion();
      mockSetRefVersion = MockSetRefVersion();
      mockGetRefVersion = MockGetRefVersion();
      mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockRestorePublishTo.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          for (final name in ['A', 'B'])
            Node(
              name: name,
              directory: Directory(path.join(ticketDir.path, name)),
              manifest: DartPackageManifest(pubspec: Pubspec(name)),
            ),
        ],
      );

      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');

      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);

      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});
    });

    /// Builds the publish command in merge mode with all mocks wired up.
    CommandRunner<void> buildRunner() =>
        CommandRunner<void>('test', 'do merge ticket')..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            mergeOnly: true,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

    /// Writes a `pubspec_overrides.yaml` with [content] into repo [name].
    void writeOverrides(String name, String content) {
      File(
        path.join(ticketDir.path, name, 'pubspec_overrides.yaml'),
      ).writeAsStringSync(content);
    }

    /// Builds a plain publish command — merge mode comes from --merge-only.
    CommandRunner<void> buildFlagRunner() =>
        CommandRunner<void>('test', 'do publish ticket')..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
          ),
        );

    test('--merge-only turns a plain publish into a merge', () async {
      // Replaces the former »gg do merge« command: the flag alone must put
      // the very same flow into merge mode.
      await buildFlagRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--merge-only',
        '-v',
      ]);

      verify(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: true,
          force: false,
          options: any(named: 'options'),
        ),
      ).called(2);

      expect(messages, contains('\nAll repos merged\n'));
    });

    test('merges every repo without publishing or tagging', () async {
      await buildRunner().run(['publish', '--input', ticketDir.path, '-v']);

      // gg_one is asked for a merge-only run.
      verify(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: true,
          force: false,
          options: any(named: 'options'),
        ),
      ).called(2);

      // Nothing reaches a registry, so nothing is waited for either.
      verifyNever(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      );

      expect(messages, contains('✓ Saved state of A'));

      // A merge keeps the ticket exactly like a publish does — the repos
      // stay in place and workable.
      expect(
        Directory(path.join(tempDir.path, '.trash', 'TICKPB')).existsSync(),
        isFalse,
      );
      expect(ticketDir.existsSync(), isTrue);
      expect(messages.join('\n'), contains('All repos merged'));
      expect(messages.join('\n'), contains('The ticket stays in place'));
    });

    test('refuses while a repo redirects refs to a working copy', () async {
      writeOverrides('B', 'dependency_overrides:\n  A:\n    path: ../A\n');

      await expectLater(
        () => buildRunner().run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(
              contains('These projects depend on other local projects: B'),
              contains('Just merging is not possible'),
              // Both escape hatches are named.
              contains('gg do publish'),
              contains('--force'),
            ),
          ),
        ),
      );

      // The guard runs before the review gate — nothing was touched.
      verifyNever(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      );
    });

    test('--force merges despite localized refs', () async {
      writeOverrides('B', 'dependency_overrides:\n  A:\n    path: ../A\n');

      await buildRunner().run([
        'publish',
        '--input',
        ticketDir.path,
        '--force',
      ]);

      verify(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: true,
          force: true,
          options: any(named: 'options'),
        ),
      ).called(2);
    });

    test('tolerates an overrides file without effective refs', () async {
      writeOverrides('B', 'dependency_overrides:\n');

      await buildRunner().run(['publish', '--input', ticketDir.path]);

      verify(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).called(1);
    });

    test('refuses while a TypeScript repo redirects refs through '
        'pnpm-workspace.yaml', () async {
      // gg_localize_refs redirects pnpm-managed TypeScript deps through the
      // overrides of pnpm-workspace.yaml — a link: entry is a working-copy
      // redirection exactly like a Dart path: override.
      File(
        path.join(ticketDir.path, 'B', 'pnpm-workspace.yaml'),
      ).writeAsStringSync('overrides:\n  A: link:../A\n');

      await expectLater(
        () => buildRunner().run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('These projects depend on other local projects: B'),
          ),
        ),
      );
    });

    test(
      'tolerates a pnpm-workspace.yaml holding only git overrides',
      () async {
        File(
          path.join(ticketDir.path, 'B', 'pnpm-workspace.yaml'),
        ).writeAsStringSync(
          'overrides:\n  A: git+ssh://git@github.com/u/a.git#feat\n',
        );

        await buildRunner().run(['publish', '--input', ticketDir.path]);

        verify(
          () => mockDidReviewCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).called(1);
      },
    );

    test(
      'gates every repo and reports a rejection with merge wording',
      () async {
        when(
          () => mockCanPublishCommand.checkRepo(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            pana: any(named: 'pana'),
          ),
        ).thenAnswer((invocation) {
          final dir = invocation.namedArguments[#directory] as Directory;
          if (path.basename(dir.path) == 'B') {
            throw Exception('Cannot publish: B (Exception: pana failed)');
          }
          return Future.value();
        });

        await expectLater(
          () => buildRunner().run(['publish', '--input', ticketDir.path]),
          throwsA(isA<Exception>()),
        );

        // The gate applies to a merge too — it is the same flow.
        verify(
          () => mockCanPublishCommand.checkRepo(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            pana: any(named: 'pana'),
          ),
        ).called(2);

        // ... and the failure is worded for the mode.
        expect(messages.any((m) => m.contains('✗ Merging B failed')), isTrue);
        expect(
          messages.any(
            (m) => m.contains('gg do publish --merge-only --continue'),
          ),
          isTrue,
        );
        expect(messages.any((m) => m.contains('✗ Publishing B')), isFalse);
        expect(
          messages.any((m) => m.contains('✗ Publishing B failed')),
          isFalse,
        );
      },
    );

    test('names »gg do publish --merge-only« in the resume hints', () async {
      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenThrow(Exception('merge failed'));

      await expectLater(
        () => buildRunner().run(['publish', '--input', ticketDir.path]),
        throwsA(isA<Exception>()),
      );

      expect(
        messages.any(
          (m) => m.contains('gg do publish --merge-only --continue'),
        ),
        isTrue,
      );
    });
  });

  // ...........................................................................
  group('DoPublishCommand per repo publish gate', () {
    late MockGgDoPublish mockGgDoPublish;
    late MockGgDoCommit mockGgDoCommit;
    late MockGgDoPush mockGgDoPush;
    late MockUnlocalizeRefs mockUnlocalizeRefs;
    late MockRestorePublishTo mockRestorePublishTo;
    late MockSortedProcessingList mockSortedProcessingList;
    late MockProcessRunner mockProcessRunner;
    late MockCanPublishCommand mockCanPublishCommand;
    late MockDidReviewCommand mockDidReviewCommand;
    late MockGetVersion mockGetVersion;
    late MockSetRefVersion mockSetRefVersion;
    late MockGetRefVersion mockGetRefVersion;
    late MockPubDevChecker mockPubDevChecker;
    late MockGgDoUpgradeDeps mockUpgradeDeps;
    late MockGgCanCommit mockGgCanCommit;

    /// Every call the ordering assertions care about, in the order it
    /// happened, as `<step>:<repo>`.
    late List<String> calls;

    String repoOf(Invocation invocation) => path.basename(
      (invocation.namedArguments[#directory] as Directory).path,
    );

    setUp(() {
      calls = [];
      mockGgDoPublish = MockGgDoPublish();
      mockGgDoCommit = MockGgDoCommit();
      mockGgDoPush = MockGgDoPush();
      mockUnlocalizeRefs = MockUnlocalizeRefs();
      mockRestorePublishTo = MockRestorePublishTo();
      mockSortedProcessingList = MockSortedProcessingList();
      mockProcessRunner = MockProcessRunner();
      _stubPubUpgrade(mockProcessRunner);
      _stubRepoSnapshot(mockProcessRunner);
      when(
        () => mockProcessRunner('git', [
          'push',
          'origin',
          '--delete',
          'TICKPB',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      mockCanPublishCommand = MockCanPublishCommand();
      mockDidReviewCommand = MockDidReviewCommand();
      mockGetVersion = MockGetVersion();
      mockSetRefVersion = MockSetRefVersion();
      mockGetRefVersion = MockGetRefVersion();
      mockPubDevChecker = MockPubDevChecker();

      when(
        () => mockDidReviewCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      stubCanPublish(mockCanPublishCommand);

      when(
        () => mockRestorePublishTo.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      // B depends on A, so A is published first.
      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          for (final name in ['A', 'B'])
            Node(
              name: name,
              directory: Directory(path.join(ticketDir.path, name)),
              manifest: DartPackageManifest(pubspec: Pubspec(name)),
            ),
        ],
      );

      // Record the order of the steps around the gate.
      when(
        () => mockUnlocalizeRefs.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((i) async => calls.add('unlocalize:${repoOf(i)}'));

      mockUpgradeDeps = MockGgDoUpgradeDeps();
      when(
        () => mockUpgradeDeps.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((i) async => calls.add('upgrade:${repoOf(i)}'));

      mockGgCanCommit = MockGgCanCommit();
      when(
        () => mockGgCanCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((i) async => calls.add('cancommit:${repoOf(i)}'));

      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          force: any(named: 'force'),
          updateChangeLog: any(named: 'updateChangeLog'),
        ),
      ).thenAnswer((i) async => calls.add('commit:${repoOf(i)}'));

      when(
        () => mockCanPublishCommand.checkRepo(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          pana: any(named: 'pana'),
        ),
      ).thenAnswer((i) async => calls.add('gate:${repoOf(i)}'));

      when(
        () => mockGgDoPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((i) async => calls.add('push:${repoOf(i)}'));

      when(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((i) async => calls.add('publish:${repoOf(i)}'));

      when(
        () => mockGetVersion.get(directory: any(named: 'directory')),
      ).thenAnswer((_) async => '1.0.0');

      when(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
        ),
      ).thenAnswer((_) async => null);

      when(
        () => mockSetRefVersion.get(
          directory: any(named: 'directory'),
          ref: any(named: 'ref'),
          version: any(named: 'version'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockPubDevChecker.getPackagePublishInfo(
          packageName: any(named: 'packageName'),
        ),
      ).thenAnswer(
        (invocation) async => PackagePublishInfo(
          packageName: invocation.namedArguments[#packageName] as String,
          waitsForPubDev: false,
        ),
      );
    });

    CommandRunner<void> buildRunner() =>
        CommandRunner<void>('test', 'do publish ticket')..addCommand(
          makePublishCommand(
            ggLog: ggLog,
            ensureInRegistry: mockEnsureInRegistry,
            ggDoPublish: mockGgDoPublish,
            ggDoCommit: mockGgDoCommit,
            ggDoPush: mockGgDoPush,
            unlocalizeRefs: mockUnlocalizeRefs,
            restorePublishTo: mockRestorePublishTo,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            canPublishCommand: mockCanPublishCommand,
            didReviewCommand: mockDidReviewCommand,
            getVersionCommand: mockGetVersion,
            setRefVersionCommand: mockSetRefVersion,
            getRefVersionCommand: mockGetRefVersion,
            pubDevChecker: mockPubDevChecker,
            ggDoUpgradeDeps: mockUpgradeDeps,
            ggCanCommit: mockGgCanCommit,
          ),
        );

    test(
      'defers the check to the repos instead of running it up front',
      () async {
        await buildRunner().run(['publish', '--input', ticketDir.path]);

        verify(
          () => mockCanPublishCommand.checkTicket(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            verbose: any(named: 'verbose'),
            pana: any(named: 'pana'),
            includeCanPublish: false,
          ),
        ).called(1);
        verify(
          () => mockCanPublishCommand.checkRepo(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            pana: any(named: 'pana'),
          ),
        ).called(2);
      },
    );

    group('--no-pana', () {
      /// The pana values the two halves of the gate were called with.
      List<bool?> panaOfGate() => [
        ...verify(
          () => mockCanPublishCommand.checkTicket(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            verbose: any(named: 'verbose'),
            pana: captureAny(named: 'pana'),
            includeCanPublish: any(named: 'includeCanPublish'),
          ),
        ).captured.cast<bool?>(),
        ...verify(
          () => mockCanPublishCommand.checkRepo(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            pana: captureAny(named: 'pana'),
          ),
        ).captured.cast<bool?>(),
      ];

      /// The options gg_one's »do publish« was called with per repo.
      List<Map<String, dynamic>> panaOfGgDoPublish() => verify(
        () => mockGgDoPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          deleteFeatureBranch: any(named: 'deleteFeatureBranch'),
          verbose: any(named: 'verbose'),
          versionIncrement: any(named: 'versionIncrement'),
          channel: any(named: 'channel'),
          askBeforePublishing: any(named: 'askBeforePublishing'),
          resume: any(named: 'resume'),
          pr: any(named: 'pr'),
          mergeOnly: any(named: 'mergeOnly'),
          force: any(named: 'force'),
          options: captureAny(named: 'options'),
        ),
      ).captured.cast<Map<String, dynamic>>();

      test('turns pana off everywhere it is checked', () async {
        await buildRunner().run([
          'publish',
          '--no-pana',
          '--input',
          ticketDir.path,
        ]);

        // checkTicket once, checkRepo per repo.
        expect(panaOfGate(), [false, false, false]);
        expect(panaOfGgDoPublish(), [
          {gg.panaOption: false},
          {gg.panaOption: false},
        ]);
      });

      test('runs pana by default', () async {
        await buildRunner().run(['publish', '--input', ticketDir.path]);

        expect(panaOfGate(), [true, true, true]);
        expect(panaOfGgDoPublish(), [
          {gg.panaOption: true},
          {gg.panaOption: true},
        ]);
      });

      test('takes the value from the exec options', () async {
        await makePublishCommand(
          ggLog: ggLog,
          ensureInRegistry: mockEnsureInRegistry,
          ggDoPublish: mockGgDoPublish,
          ggDoCommit: mockGgDoCommit,
          ggDoPush: mockGgDoPush,
          unlocalizeRefs: mockUnlocalizeRefs,
          restorePublishTo: mockRestorePublishTo,
          sortedProcessingList: mockSortedProcessingList,
          processRunner: mockProcessRunner.call,
          canPublishCommand: mockCanPublishCommand,
          didReviewCommand: mockDidReviewCommand,
          getVersionCommand: mockGetVersion,
          setRefVersionCommand: mockSetRefVersion,
          getRefVersionCommand: mockGetRefVersion,
          pubDevChecker: mockPubDevChecker,
          ggDoUpgradeDeps: mockUpgradeDeps,
          ggCanCommit: mockGgCanCommit,
        ).exec(
          directory: ticketDir,
          ggLog: ggLog,
          options: const <String, dynamic>{gg.panaOption: false},
        );

        expect(panaOfGate(), [false, false, false]);
      });
    });

    group('for hybrids and registry-less repos', () {
      /// A hybrid refreshes its dependencies through the node package
      /// manager, which the surrounding fixture does not stub.
      void stubNodeRefresh() {
        for (final pm in <String>['pnpm', 'npm', 'yarn']) {
          when(
            () => mockProcessRunner(
              pm,
              any(),
              workingDirectory: any(named: 'workingDirectory'),
              environment: any(named: 'environment'),
            ),
          ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
        }
      }

      /// Turns repo A into a hybrid whose npm side is at
      /// [packageJsonVersion].
      void makeAHybrid({
        required String pubspecVersion,
        required String packageJsonVersion,
      }) {
        File(
          path.join(ticketDir.path, 'A', 'pubspec.yaml'),
        ).writeAsStringSync('name: A\nversion: $pubspecVersion\n');
        File(path.join(ticketDir.path, 'A', 'package.json')).writeAsStringSync(
          '{"name": "@org/a", "version": "$packageJsonVersion"}',
        );
        stubNodeRefresh();
      }

      /// The dependency names the run looked up while propagating versions.
      List<String> lookedUpRefs() => verify(
        () => mockGetRefVersion.get(
          directory: any(named: 'directory'),
          ref: captureAny(named: 'ref'),
        ),
      ).captured.cast<String>();

      test('turns pana off for a repo whose manifests drifted', () async {
        // gg_one reconciles them and then skips pana, because the reconciled
        // version has no CHANGELOG.md section. The gate runs before that, so
        // it has to reach the same conclusion itself.
        makeAHybrid(pubspecVersion: '1.0.2', packageJsonVersion: '1.0.1');

        await buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--verbose',
        ]);

        expect(
          messages.join('\n'),
          contains('A: the manifests disagree on the version'),
        );
        // A is drifted, B is not.
        final panaPerRepo = verify(
          () => mockCanPublishCommand.checkRepo(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            pana: captureAny(named: 'pana'),
          ),
        ).captured.cast<bool?>();
        expect(panaPerRepo, [false, true]);
      });

      test('registers both names of a hybrid as reference versions', () async {
        // A Dart dependent resolves »A«, an npm dependent »@org/a« — both
        // constraints have to be updated.
        makeAHybrid(pubspecVersion: '1.0.1', packageJsonVersion: '1.0.1');

        await buildRunner().run(['publish', '--input', ticketDir.path]);

        // verify() consumes the recorded calls, so capture them once.
        final refs = lookedUpRefs();
        expect(refs, contains('A'));
        expect(refs, contains('@org/a'));
      });

      test('still records a name for a repo without a registry', () async {
        // »publish_to: none« leaves no registry, but the version still has to
        // reach the dependents' constraints.
        File(
          path.join(ticketDir.path, 'A', 'pubspec.yaml'),
        ).writeAsStringSync('name: A\nversion: 1.0.1\npublish_to: none\n');

        await buildRunner().run(['publish', '--input', ticketDir.path]);

        expect(lookedUpRefs(), contains('A'));
      });

      test('falls back to the directory name without a manifest', () async {
        File(path.join(ticketDir.path, 'A', 'pubspec.yaml')).deleteSync();

        await buildRunner().run(['publish', '--input', ticketDir.path]);

        expect(lookedUpRefs(), contains('A'));
      });
    });

    test('checks a repo after its refs point at pub.dev and after its '
        'dependencies were published', () async {
      await buildRunner().run(['publish', '--input', ticketDir.path]);

      // Within a repo: after the refs point at the registry, the
      // dependencies are upgraded and the repo is re-verified with
      // `gg can commit` before the bookkeeping commit sweeps everything up;
      // the gate sits between the force-commit and the push.
      expect(
        calls,
        containsAllInOrder([
          'unlocalize:B',
          'upgrade:B',
          'cancommit:B',
          'commit:B',
          'gate:B',
          'push:B',
          'publish:B',
        ]),
      );

      // Across repos: A is on the registry before B is even asked. This is
      // the whole point — pana can only resolve B's constraint on A once A
      // is published.
      expect(calls.indexOf('publish:A'), lessThan(calls.indexOf('gate:B')));
    });

    test('passes a logging ggLog to the gate', () async {
      // The gate is what makes the run fail, so its detail must be visible
      // without --verbose.
      when(
        () => mockCanPublishCommand.checkRepo(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          pana: any(named: 'pana'),
        ),
      ).thenAnswer((invocation) async {
        final log = invocation.namedArguments[#ggLog] as void Function(String);
        log('gate detail');
      });

      await buildRunner().run(['publish', '--input', ticketDir.path]);

      expect(messages, contains('gate detail'));
    });

    test('marks only the rejected repo failed and leaves the earlier one '
        'published', () async {
      when(
        () => mockCanPublishCommand.checkRepo(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          pana: any(named: 'pana'),
        ),
      ).thenAnswer((i) async {
        calls.add('gate:${repoOf(i)}');
        if (repoOf(i) == 'B') {
          throw Exception('Cannot publish: B (Exception: pana failed)');
        }
      });

      await expectLater(
        () => buildRunner().run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Cannot publish: B'),
          ),
        ),
      );

      // A got all the way through; B never reached anything irreversible.
      expect(calls, contains('publish:A'));
      expect(calls, isNot(contains('push:B')));
      expect(calls, isNot(contains('publish:B')));
      verifyNever(
        () => mockEnsureInRegistry.ensure(
          directory: Directory(path.join(ticketDir.path, 'B')),
          ggLog: any(named: 'ggLog'),
        ),
      );

      // The ticket file carries both outcomes, so --continue resumes at B.
      final config =
          jsonDecode(
                File(
                  path.join(ticketDir.path, '.gg', 'gg-publish.json'),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final repos = config['repos'] as Map<String, dynamic>;
      expect((repos['A'] as Map<String, dynamic>)['status'], 'published');
      expect((repos['B'] as Map<String, dynamic>)['status'], 'failed');

      // The reason is reported where the failure is recorded.
      expect(messages.any((m) => m.contains('✗ Publishing B failed')), isTrue);
      expect(messages.any((m) => m.contains('Cannot publish: B')), isTrue);
      expect(
        messages.any((m) => m.contains('gg do publish --continue')),
        isTrue,
      );
    });

    test('a failing upgrade fails the repo like a rejected gate', () async {
      when(
        () => mockUpgradeDeps.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((i) async {
        calls.add('upgrade:${repoOf(i)}');
        if (repoOf(i) == 'B') {
          throw Exception('Failed to upgrade.');
        }
      });

      await expectLater(
        () => buildRunner().run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Failed to upgrade.'),
          ),
        ),
      );

      // A got all the way through; B never reached anything irreversible.
      expect(calls, contains('publish:A'));
      expect(calls, isNot(contains('cancommit:B')));
      expect(calls, isNot(contains('gate:B')));
      expect(calls, isNot(contains('push:B')));
      expect(calls, isNot(contains('publish:B')));
    });

    test('a failing can commit fails the repo like a rejected gate', () async {
      when(
        () => mockGgCanCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((i) async {
        calls.add('cancommit:${repoOf(i)}');
        if (repoOf(i) == 'B') {
          throw Exception('Cannot commit.');
        }
      });

      await expectLater(
        () => buildRunner().run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Cannot commit.'),
          ),
        ),
      );

      expect(calls, contains('publish:A'));
      expect(calls, isNot(contains('gate:B')));
      expect(calls, isNot(contains('push:B')));
      expect(calls, isNot(contains('publish:B')));
    });

    group('on --continue', () {
      /// Marks the run as resumable and gives repo [name] gg_one step
      /// progress, as a repo that failed mid-publish would have.
      void writeProgress({required String repoWithSteps}) {
        File(
          path.join(ticketDir.path, '.gg', 'gg-publish.json'),
        ).writeAsStringSync(
          jsonEncode({
            'version_increment': 'patch',
            'merge_message': 'test merge',
            'repos': {
              'B': {'status': 'failed'},
            },
          }),
        );
        Directory(
          path.join(ticketDir.path, repoWithSteps, '.gg'),
        ).createSync(recursive: true);
        File(
          path.join(ticketDir.path, repoWithSteps, '.gg', 'gg-publish.json'),
        ).writeAsStringSync(
          jsonEncode({
            'version_increment': 'patch',
            'merge_message': 'test merge',
            'done_steps': ['prepare_version'],
          }),
        );
      }

      test(
        'skips the gate for a repo that already made publish progress',
        () async {
          writeProgress(repoWithSteps: 'B');

          await buildRunner().run([
            'publish',
            '--input',
            ticketDir.path,
            '--continue',
          ]);

          // B is past the point where the gate could still say anything
          // useful — its version is bumped already.
          expect(calls, contains('gate:A'));
          expect(calls, isNot(contains('gate:B')));
          expect(calls, contains('publish:B'));

          // The same holds for the upgrade + can-commit validation: it must
          // not touch a mid-publish state.
          expect(calls, contains('upgrade:A'));
          expect(calls, contains('cancommit:A'));
          expect(calls, isNot(contains('upgrade:B')));
          expect(calls, isNot(contains('cancommit:B')));

          // The Dart refresh of _changeRefsToPubDev only runs where the
          // upgrade step is skipped: for B (step progress), not for A. The
          // workspace restore after each publish adds one resolve per repo.
          verify(
            () => mockProcessRunner(
              'dart',
              ['pub', 'upgrade'],
              workingDirectory: path.join(ticketDir.path, 'B'),
              environment: any(named: 'environment'),
            ),
          ).called(2);
          verify(
            () => mockProcessRunner(
              'dart',
              ['pub', 'upgrade'],
              workingDirectory: path.join(ticketDir.path, 'A'),
              environment: any(named: 'environment'),
            ),
          ).called(1);
        },
      );

      test('re-checks a repo that made no publish progress', () async {
        File(
          path.join(ticketDir.path, '.gg', 'gg-publish.json'),
        ).writeAsStringSync(
          jsonEncode({
            'version_increment': 'patch',
            'merge_message': 'test merge',
            'repos': {
              'A': {'status': 'published'},
            },
          }),
        );

        await buildRunner().run([
          'publish',
          '--input',
          ticketDir.path,
          '--continue',
        ]);

        // Re-validating on resume is the point: B is checked again.
        expect(calls, contains('gate:B'));
      });
    });

    test('constructs its upgrade and can-commit collaborators by default', () {
      // makePublishCommand always injects mocks for the two, so the
      // default construction is exercised here.
      expect(DoPublishCommand(ggLog: ggLog), isNotNull);
    });
  });
}

// Mock for ProcessRunner
class MockProcessRunner extends Mock {
  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool? runInShell,
  });
}

/// Stubs both halves of the publish gate on [mock] so they succeed: the
/// ticket wide `checkTicket` `do publish` runs up front, and the per-repo
/// `checkRepo` it runs inside `_publishRepo`. A test that is about one of
/// them overrides just that one afterwards.
void stubCanPublish(MockCanPublishCommand mock) {
  when(
    () => mock.checkTicket(
      directory: any(named: 'directory'),
      ggLog: any(named: 'ggLog'),
      verbose: any(named: 'verbose'),
      pana: any(named: 'pana'),
      includeCanPublish: any(named: 'includeCanPublish'),
    ),
  ).thenAnswer((_) async {});

  when(
    () => mock.checkRepo(
      directory: any(named: 'directory'),
      ggLog: any(named: 'ggLog'),
      pana: any(named: 'pana'),
    ),
  ).thenAnswer((_) async {});
}

/// Stubs `dart pub upgrade` on [runner] so it succeeds for any working
/// directory.
void _stubPubUpgrade(MockProcessRunner runner) {
  when(
    () => runner(
      'dart',
      ['pub', 'upgrade'],
      workingDirectory: any(named: 'workingDirectory'),
      environment: any(named: 'environment'),
    ),
  ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
}

/// Stubs the git calls of the pre-publish snapshot on [runner]: constant
/// branch/HEAD, a clean working tree, an existing `main` with an unchanged
/// remote and no tags. With these values a rollback after a failure sees an
/// unchanged repo and skips it.
void _stubRepoSnapshot(MockProcessRunner runner) {
  when(
    () => runner('git', [
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ], workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer((_) async => ProcessResult(0, 0, 'TICKPB', ''));
  when(
    () => runner('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer((_) async => ProcessResult(0, 0, 'samehead', ''));
  when(
    () => runner('git', [
      'status',
      '--porcelain',
    ], workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
  when(
    () => runner('git', [
      'rev-parse',
      '--verify',
      '--quiet',
      'refs/heads/main',
    ], workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer((_) async => ProcessResult(0, 0, 'mainhead', ''));
  when(
    () => runner('git', [
      'ls-remote',
      'origin',
      'refs/heads/main',
    ], workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer(
    (_) async => ProcessResult(0, 0, 'remotemain\trefs/heads/main', ''),
  );
  when(
    () => runner('git', [
      'ls-remote',
      'origin',
      'refs/heads/TICKPB',
    ], workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer(
    (_) async => ProcessResult(0, 0, 'remotefeature\trefs/heads/TICKPB', ''),
  );
  when(
    () => runner('git', [
      'tag',
      '--list',
    ], workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

  // The post-publish workspace restore: back to the feature branch, then
  // merge the released main state into it.
  when(
    () => runner('git', [
      'checkout',
      'TICKPB',
    ], workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
  when(
    () => runner('git', [
      'merge',
      '-m',
      '#gg: merge the published main back into TICKPB',
      'main',
    ], workingDirectory: any(named: 'workingDirectory')),
  ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
}

/// Builds a [DoPublishCommand] whose upgrade and can-commit collaborators
/// default to pre-stubbed mocks — otherwise every test reaching
/// `_publishRepo` would run a real »dart pub upgrade« and real checks.
///
/// The post-publish collaborators (re-localization, didPublish, ticket
/// state) default to pre-stubbed mocks as well, and [hasTerminal] defaults
/// to `false`, so runs behave headless: the cleanup offer is skipped and
/// the ticket is kept. Tests about the offer inject an adapter plus
/// `hasTerminal: () => true`.
DoPublishCommand makePublishCommand({
  required GgLog ggLog,
  bool mergeOnly = false,
  gg.DoCommit? ggDoCommit,
  gg.DoUpgradeDeps? ggDoUpgradeDeps,
  gg.CanCommit? ggCanCommit,
  ChangeRefsToPubDev? unlocalizeRefs,
  ChangeRefsToLocal? localizeRefs,
  RestorePublishTo? restorePublishTo,
  gg.DoPush? ggDoPush,
  gg.DoPublish? ggDoPublish,
  gg.DidPublish? ggDidPublish,
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
  DoConfigurePublishCommand? doConfigurePublishCommand,
  gg.EnsurePublishConfigIgnored? ensureIgnored,
  EnsureInRegistry? ensureInRegistry,
  TicketState? ticketState,
  gg.InteractAdapter? interactAdapter,
  gg.HasTerminal? hasTerminal,
}) {
  if (ggDoUpgradeDeps == null) {
    final mock = MockGgDoUpgradeDeps();
    when(
      () => mock.exec(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {});
    ggDoUpgradeDeps = mock;
  }
  if (ggCanCommit == null) {
    final mock = MockGgCanCommit();
    when(
      () => mock.exec(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {});
    ggCanCommit = mock;
  }
  if (localizeRefs == null) {
    final mock = MockLocalizeRefs();
    when(
      () => mock.get(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {});
    localizeRefs = mock;
  }
  if (ggDidPublish == null) {
    final mock = MockGgDidPublish();
    when(
      () => mock.set(directory: any(named: 'directory')),
    ).thenAnswer((_) async {});
    ggDidPublish = mock;
  }
  if (ticketState == null) {
    final mock = MockTicketState();
    when(
      () => mock.writeSuccess(
        ticketDir: any(named: 'ticketDir'),
        subs: any(named: 'subs'),
        key: any(named: 'key'),
        ignoreUnstaged: any(named: 'ignoreUnstaged'),
      ),
    ).thenAnswer((_) async {});
    ticketState = mock;
  }
  return DoPublishCommand(
    ggLog: ggLog,
    mergeOnly: mergeOnly,
    ggDoCommit: ggDoCommit,
    ggDoUpgradeDeps: ggDoUpgradeDeps,
    ggCanCommit: ggCanCommit,
    unlocalizeRefs: unlocalizeRefs,
    localizeRefs: localizeRefs,
    restorePublishTo: restorePublishTo,
    ggDoPush: ggDoPush,
    ggDoPublish: ggDoPublish,
    ggDidPublish: ggDidPublish,
    sortedProcessingList: sortedProcessingList,
    processRunner: processRunner,
    canPublishCommand: canPublishCommand,
    didReviewCommand: didReviewCommand,
    getVersionCommand: getVersionCommand,
    setRefVersionCommand: setRefVersionCommand,
    getRefVersionCommand: getRefVersionCommand,
    pubDevChecker: pubDevChecker,
    npmChecker: npmChecker,
    publishSkipCheck: publishSkipCheck,
    doConfigurePublishCommand: doConfigurePublishCommand,
    ensureIgnored: ensureIgnored,
    ensureInRegistry: ensureInRegistry,
    ticketState: ticketState,
    interactAdapter: interactAdapter ?? MockInteractAdapter(),
    hasTerminal: hasTerminal ?? () => false,
  );
}
