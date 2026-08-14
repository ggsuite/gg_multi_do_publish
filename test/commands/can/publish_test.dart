// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_multi_do_publish/src/commands/can/publish.dart';
import 'package:gg_multi_commit/gg_multi_commit.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

class MockGgCanCommit extends Mock implements gg.CanCommit {}

class MockGgCanMerge extends Mock implements gg.CanMerge {}

class MockGgCanPublish extends Mock implements gg.CanPublish {}

class MockGgNpmLoggedIn extends Mock implements gg.NpmLoggedIn {}

class MockSortedProcessingList extends Mock implements SortedProcessingList {}

class MockDidCommitCommand extends Mock implements DidCommitCommand {}

class MockDoPushCommand extends Mock implements DoPushCommand {}

class FakeDirectory extends Fake implements Directory {}

void main() {
  late Directory tempDir;
  late Directory ticketsDir;
  late Directory ticketDir;
  final messages = <String>[];

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
  });

  void ggLog(String msg) => messages.add(rmControls(msg));

  setUp(() {
    messages.clear();
    tempDir = Directory.systemTemp.createTempSync('can_publish_ticket_test_');
    ticketsDir = Directory(path.join(tempDir.path, 'tickets'))..createSync();
    ticketDir = Directory(path.join(ticketsDir.path, 'TICKPB'))..createSync();
    Directory(path.join(ticketDir.path, 'A')).createSync();
    Directory(path.join(ticketDir.path, 'B')).createSync();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('CanPublishCommand (ticket-wide)', () {
    test('fails outside any ticket folder', () async {
      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(CanPublishCommand(ggLog: ggLog));
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
      expect(
        messages,
        contains('Please run this command inside a ticket folder.'),
      );
    });

    test('logs when there are no repositories', () async {
      final emptyTicket = Directory(path.join(ticketsDir.path, 'EMPTY'))
        ..createSync();
      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(CanPublishCommand(ggLog: ggLog));
      await runner.run(['publish', '--input', emptyTicket.path]);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('checks uncommitted changes and fails if found', () async {
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgCanMerge = MockGgCanMerge();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockDidCommitCommand = MockDidCommitCommand();
      final mockDoPushCommand = MockDoPushCommand();

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

      // Simulate uncommitted changes in A
      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: path.join(ticketDir.path, 'A')),
      ).thenAnswer((_) async => ProcessResult(1, 0, ' M file.txt', ''));
      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: path.join(ticketDir.path, 'B')),
      ).thenAnswer((_) async => ProcessResult(2, 0, '', ''));

      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(
          CanPublishCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggCanMerge: mockGgCanMerge,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            didCommitCommand: mockDidCommitCommand,
            doPushCommand: mockDoPushCommand,
          ),
        );
      await expectLater(
        () async => await runner.run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );
      expect(messages.any((m) => m.contains('Uncommitted changes in')), isTrue);
      expect(messages.any((m) => m.contains(' - A')), isTrue);
    });

    group('lock file drift', () {
      /// Wires a ticket of two repos whose `git status --porcelain` returns
      /// [statusOfA] / [statusOfB], and returns the runner plus the mocks the
      /// tests assert on.
      ({
        CommandRunner<void> runner,
        MockProcessRunner processRunner,
        gg.MockPubGetOffline pubGetOffline,
      })
      setUpTicket({
        required String statusOfA,
        required String statusOfB,
        int commitExitCode = 0,
      }) {
        final mockSortedProcessingList = MockSortedProcessingList();
        final mockProcessRunner = MockProcessRunner();
        final mockPubGetOffline = gg.MockPubGetOffline();
        final mockGgCanMerge = MockGgCanMerge();
        final mockGgCanPublish = MockGgCanPublish();
        final mockDidCommitCommand = MockDidCommitCommand();
        final mockDoPushCommand = MockDoPushCommand();

        // Everything downstream of the two steps under test just succeeds.
        when(
          () => mockGgCanMerge.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockGgCanPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockDidCommitCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => mockDoPushCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            upgrade: any(named: 'upgrade'),
          ),
        ).thenAnswer((_) async {});

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
          () => mockPubGetOffline.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {
          messages.add('pubGetOffline');
        });

        for (final entry in <String, String>{
          'A': statusOfA,
          'B': statusOfB,
        }.entries) {
          when(
            () => mockProcessRunner('git', [
              'status',
              '--porcelain',
            ], workingDirectory: path.join(ticketDir.path, entry.key)),
          ).thenAnswer((_) async => ProcessResult(1, 0, entry.value, ''));
        }

        when(
          () => mockProcessRunner(
            'git',
            any(that: contains('add')),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer((_) async => ProcessResult(2, 0, '', ''));

        when(
          () => mockProcessRunner(
            'git',
            any(that: contains('commit')),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        ).thenAnswer(
          (_) async => ProcessResult(
            3,
            commitExitCode,
            '',
            commitExitCode == 0 ? '' : 'nothing to commit',
          ),
        );

        final runner = CommandRunner<void>('test', 'can publish ticket')
          ..addCommand(
            CanPublishCommand(
              ggLog: ggLog,
              ggCanCommit: MockGgCanCommit(),
              ggCanMerge: mockGgCanMerge,
              ggCanPublish: mockGgCanPublish,
              ggPubGetOffline: mockPubGetOffline,
              sortedProcessingList: mockSortedProcessingList,
              processRunner: mockProcessRunner.call,
              didCommitCommand: mockDidCommitCommand,
              doPushCommand: mockDoPushCommand,
            ),
          );

        return (
          runner: runner,
          processRunner: mockProcessRunner,
          pubGetOffline: mockPubGetOffline,
        );
      }

      test('syncs the lock files before looking at the working tree', () async {
        final t = setUpTicket(statusOfA: '', statusOfB: '');

        await t.runner.run(['publish', '--verbose', '--input', ticketDir.path]);

        verify(
          () => t.pubGetOffline.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).called(2);
        // Ran before the status was read — otherwise a lock file merely out of
        // date would surface as an uncommitted change.
        expect(
          messages.indexOf('pubGetOffline'),
          lessThan(messages.indexWhere((m) => m.contains('Uncommitted'))),
        );
      });

      test('commits drift that is nothing but lock files', () async {
        final t = setUpTicket(
          statusOfA: ' M pubspec.lock\n?? packages/x/pubspec.lock',
          statusOfB: '',
        );

        await t.runner.run(['publish', '--verbose', '--input', ticketDir.path]);

        verify(
          () => t.processRunner('git', [
            'add',
            '--',
            'pubspec.lock',
            'packages/x/pubspec.lock',
          ], workingDirectory: path.join(ticketDir.path, 'A')),
        ).called(1);
        verify(
          () => t.processRunner('git', [
            'commit',
            '-m',
            '#gg: Update pubspec.lock, packages/x/pubspec.lock',
            // The pathspec is on the commit too, so nothing that was staged
            // meanwhile rides along.
            '--',
            'pubspec.lock',
            'packages/x/pubspec.lock',
          ], workingDirectory: path.join(ticketDir.path, 'A')),
        ).called(1);
        expect(
          messages.any(
            (m) => m.contains(
              'Committed lock file drift in A: pubspec.lock, '
              'packages/x/pubspec.lock',
            ),
          ),
          isTrue,
        );
      });

      test('still reports drift that touches another file as well', () async {
        final t = setUpTicket(
          statusOfA: ' M pubspec.lock\n M lib/src/main.dart',
          statusOfB: '',
        );

        await expectLater(
          () async => await t.runner.run([
            'publish',
            '--verbose',
            '--input',
            ticketDir.path,
          ]),
          throwsA(isA<Exception>()),
        );
        expect(messages.any((m) => m.contains('Uncommitted changes in')), true);
        expect(messages.any((m) => m.contains(' - A')), isTrue);
        verifyNever(
          () => t.processRunner(
            'git',
            any(that: contains('commit')),
            workingDirectory: any(named: 'workingDirectory'),
          ),
        );
      });

      test('fails loudly when the lock file commit does not work', () async {
        final t = setUpTicket(
          statusOfA: ' M pubspec.lock',
          statusOfB: '',
          commitExitCode: 1,
        );

        await expectLater(
          () async => await t.runner.run([
            'publish',
            '--verbose',
            '--input',
            ticketDir.path,
          ]),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('Could not commit pubspec.lock in A'),
            ),
          ),
        );
      });
    });

    test('executes did commit, do push, and can merge successfully', () async {
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgCanMerge = MockGgCanMerge();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockDidCommitCommand = MockDidCommitCommand();
      final mockDoPushCommand = MockDoPushCommand();

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
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockDidCommitCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockDoPushCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          upgrade: any(named: 'upgrade'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgCanMerge.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      final mockGgCanPublish = MockGgCanPublish();
      when(
        () => mockGgCanPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(
          CanPublishCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggCanMerge: mockGgCanMerge,
            ggCanPublish: mockGgCanPublish,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            didCommitCommand: mockDidCommitCommand,
            doPushCommand: mockDoPushCommand,
          ),
        );
      await runner.run(['publish', '--verbose', '--input', ticketDir.path]);
      expect(messages, contains('\nAll repos can be published\n'));
      verify(
        () => mockGgCanPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          options: any(named: 'options'),
        ),
      ).called(2);
      expect(messages.any((m) => m.contains('A')), isTrue);
      expect(messages.any((m) => m.contains('B')), isTrue);
    });

    test('fails on can merge check for specific repos', () async {
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgCanMerge = MockGgCanMerge();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockDidCommitCommand = MockDidCommitCommand();
      final mockDoPushCommand = MockDoPushCommand();

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
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockDidCommitCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockDoPushCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          upgrade: any(named: 'upgrade'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgCanMerge.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((invocation) {
        final repoDir = invocation.namedArguments[#directory] as Directory;
        if (path.basename(repoDir.path) == 'B') {
          throw Exception('Merge check failed for B');
        }
        return Future.value();
      });

      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(
          CanPublishCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggCanMerge: mockGgCanMerge,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            didCommitCommand: mockDidCommitCommand,
            doPushCommand: mockDoPushCommand,
          ),
        );
      await expectLater(
        () async => await runner.run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );
      expect(
        messages.any(
          (m) =>
              m.contains('✗ Cannot merge\nException: Merge check failed for B'),
        ),
        isTrue,
      );
    });

    test('names the repo and the reason without --verbose', () async {
      // The per-repo detail goes to the task log, which is silent without
      // --verbose. A bare »Cannot merge.« leaves the user with nothing to act
      // on, so the reason travels in the exception.
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgCanMerge = MockGgCanMerge();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockDidCommitCommand = MockDidCommitCommand();
      final mockDoPushCommand = MockDoPushCommand();

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
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));
      when(
        () => mockDidCommitCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockDoPushCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          upgrade: any(named: 'upgrade'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockGgCanMerge.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((invocation) {
        final repoDir = invocation.namedArguments[#directory] as Directory;
        if (path.basename(repoDir.path) == 'B') {
          throw Exception('Local references found in the package manifest.');
        }
        return Future.value();
      });

      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(
          CanPublishCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggCanMerge: mockGgCanMerge,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            didCommitCommand: mockDidCommitCommand,
            doPushCommand: mockDoPushCommand,
          ),
        );

      await expectLater(
        () async => await runner.run(['publish', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            'Exception: Cannot merge.\n'
                '  - B: Local references found in the package manifest.',
          ),
        ),
      );
    });

    test('fails when did commit throws exception', () async {
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgCanMerge = MockGgCanMerge();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockDidCommitCommand = MockDidCommitCommand();
      final mockDoPushCommand = MockDoPushCommand();

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
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockDidCommitCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenThrow(Exception('Did commit failed'));

      when(
        () => mockDoPushCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          upgrade: any(named: 'upgrade'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgCanMerge.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(
          CanPublishCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggCanMerge: mockGgCanMerge,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            didCommitCommand: mockDidCommitCommand,
            doPushCommand: mockDoPushCommand,
          ),
        );
      await expectLater(
        () async => await runner.run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );
      expect(
        messages.any(
          (m) => m.contains('✗ Not committed\nException: Did commit failed'),
        ),
        isTrue,
      );
    });

    test('passes a merge conflict of do push through unwrapped', () async {
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgCanMerge = MockGgCanMerge();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockDidCommitCommand = MockDidCommitCommand();
      final mockDoPushCommand = MockDoPushCommand();

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
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockDidCommitCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      // The push merges main into the feature branches — a conflict there
      // must not be wrapped into the generic 'Failed to push.' error: its
      // message carries the actionable report and the half-merged working
      // tree must survive.
      when(
        () => mockDoPushCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          upgrade: any(named: 'upgrade'),
        ),
      ).thenThrow(
        MergeConflictException(
          'Merging origin/main into A produced conflicts:\n'
          ' - A/pubspec.yaml\n'
          'Please resolve the conflicts. Then execute: '
          "gg do commit -m 'Merge main' --no-log",
        ),
      );

      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(
          CanPublishCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggCanMerge: mockGgCanMerge,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            didCommitCommand: mockDidCommitCommand,
            doPushCommand: mockDoPushCommand,
          ),
        );
      await expectLater(
        () async => await runner.run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(
          isA<MergeConflictException>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(
              contains("gg do commit -m 'Merge main' --no-log"),
              isNot(contains('Failed to push.')),
            ),
          ),
        ),
      );
      // The conflict aborts the run before `can merge` is asked.
      verifyNever(
        () => mockGgCanMerge.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      );
    });

    test('fails when do push throws exception', () async {
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgCanMerge = MockGgCanMerge();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockDidCommitCommand = MockDidCommitCommand();
      final mockDoPushCommand = MockDoPushCommand();

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
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockDidCommitCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockDoPushCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          upgrade: any(named: 'upgrade'),
        ),
      ).thenThrow(Exception('do push failed'));

      when(
        () => mockGgCanMerge.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(
          CanPublishCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggCanMerge: mockGgCanMerge,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            didCommitCommand: mockDidCommitCommand,
            doPushCommand: mockDoPushCommand,
          ),
        );
      await expectLater(
        () async => await runner.run([
          'publish',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );
      expect(
        messages.any(
          (m) => m.contains('✗ Failed to push\nException: do push failed'),
        ),
        isTrue,
      );
    });

    test(
      'fails when a repo is not publish-ready (e.g. not logged in to npm)',
      () async {
        final mockGgCanCommit = MockGgCanCommit();
        final mockGgCanMerge = MockGgCanMerge();
        final mockGgCanPublish = MockGgCanPublish();
        final mockSortedProcessingList = MockSortedProcessingList();
        final mockProcessRunner = MockProcessRunner();
        final mockDidCommitCommand = MockDidCommitCommand();
        final mockDoPushCommand = MockDoPushCommand();

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
          () => mockProcessRunner('git', [
            'status',
            '--porcelain',
          ], workingDirectory: any(named: 'workingDirectory')),
        ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

        when(
          () => mockDidCommitCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});

        when(
          () => mockDoPushCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            upgrade: any(named: 'upgrade'),
          ),
        ).thenAnswer((_) async {});

        when(
          () => mockGgCanMerge.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((_) async {});

        // Repo B is not logged in to npm.
        when(
          () => mockGgCanPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((invocation) {
          final repoDir = invocation.namedArguments[#directory] as Directory;
          if (path.basename(repoDir.path) == 'B') {
            throw Exception('Not logged in to the npm registry');
          }
          return Future.value();
        });

        final runner = CommandRunner<void>('test', 'can publish ticket')
          ..addCommand(
            CanPublishCommand(
              ggLog: ggLog,
              ggCanCommit: mockGgCanCommit,
              ggCanMerge: mockGgCanMerge,
              ggCanPublish: mockGgCanPublish,
              sortedProcessingList: mockSortedProcessingList,
              processRunner: mockProcessRunner.call,
              didCommitCommand: mockDidCommitCommand,
              doPushCommand: mockDoPushCommand,
            ),
          );
        await expectLater(
          () async => await runner.run([
            'publish',
            '--verbose',
            '--input',
            ticketDir.path,
          ]),
          throwsA(isA<Exception>()),
        );
        expect(messages.any((m) => m.contains('✗ Cannot publish')), isTrue);
        expect(
          messages.any((m) => m.contains('Not logged in to the npm registry')),
          isTrue,
        );
      },
    );

    test('uses quiet taskLog when verbose is false', () async {
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgCanMerge = MockGgCanMerge();
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockDidCommitCommand = MockDidCommitCommand();
      final mockDoPushCommand = MockDoPushCommand();

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
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockDidCommitCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockDoPushCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          upgrade: any(named: 'upgrade'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgCanMerge.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      final mockGgCanPublish = MockGgCanPublish();
      when(
        () => mockGgCanPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async {});

      final localMessages = <String>[];
      void localLog(String msg) => localMessages.add(rmControls(msg));

      final command = CanPublishCommand(
        ggLog: localLog,
        ggCanCommit: mockGgCanCommit,
        ggCanMerge: mockGgCanMerge,
        ggCanPublish: mockGgCanPublish,
        sortedProcessingList: mockSortedProcessingList,
        processRunner: mockProcessRunner.call,
        didCommitCommand: mockDidCommitCommand,
        doPushCommand: mockDoPushCommand,
      );

      await command.get(directory: ticketDir, ggLog: localLog, verbose: false);

      // The closing summary is visible without --verbose; the per-step
      // status lines are the ones above it.
      expect(localMessages.last, '\nAll repos can be published\n');
      expect(localMessages.any((m) => m.contains('✓ Can publish?')), isTrue);
    });
  });

  // ...........................................................................
  group('CanPublishCommand (per repo gate)', () {
    late MockGgCanMerge mockGgCanMerge;
    late MockGgCanPublish mockGgCanPublish;
    late MockGgNpmLoggedIn mockGgNpmLoggedIn;
    late MockSortedProcessingList mockSortedProcessingList;
    late MockProcessRunner mockProcessRunner;
    late MockDidCommitCommand mockDidCommitCommand;
    late MockDoPushCommand mockDoPushCommand;

    /// A command whose collaborators all succeed, so a test only has to
    /// override the one it is about.
    CanPublishCommand command() => CanPublishCommand(
      ggLog: ggLog,
      ggCanMerge: mockGgCanMerge,
      ggCanPublish: mockGgCanPublish,
      ggNpmLoggedIn: mockGgNpmLoggedIn,
      sortedProcessingList: mockSortedProcessingList,
      processRunner: mockProcessRunner.call,
      didCommitCommand: mockDidCommitCommand,
      doPushCommand: mockDoPushCommand,
    );

    Directory repoDir(String name) =>
        Directory(path.join(ticketDir.path, name));

    setUp(() {
      mockGgCanMerge = MockGgCanMerge();
      mockGgCanPublish = MockGgCanPublish();
      mockGgNpmLoggedIn = MockGgNpmLoggedIn();
      mockSortedProcessingList = MockSortedProcessingList();
      mockProcessRunner = MockProcessRunner();
      mockDidCommitCommand = MockDidCommitCommand();
      mockDoPushCommand = MockDoPushCommand();

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: repoDir('A'),
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
          Node(
            name: 'B',
            directory: repoDir('B'),
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      for (final stub in [
        () => mockDidCommitCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
        () => mockDoPushCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          // The publish upgrades every repo again right before it is
          // published — the ticket-wide push must not upgrade as well.
          upgrade: false,
        ),
        () => mockGgCanMerge.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
        () => mockGgCanPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          options: any(named: 'options'),
        ),
        () => mockGgNpmLoggedIn.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ]) {
        when(stub).thenAnswer((_) async {});
      }
    });

    group('checkTicket(includeCanPublish: false)', () {
      test('runs the ticket wide steps but not gg can publish', () async {
        await command().checkTicket(
          directory: ticketDir,
          ggLog: ggLog,
          verbose: true,
          includeCanPublish: false,
        );

        verify(
          () => mockGgCanMerge.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).called(2);
        verify(
          () => mockDoPushCommand.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            upgrade: any(named: 'upgrade'),
          ),
        ).called(1);

        // The deferred step must not even print its status line.
        verifyNever(
          () => mockGgCanPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        );
        expect(messages.any((m) => m.contains('Can merge?')), isTrue);
        expect(messages.any((m) => m.contains('Can publish?')), isFalse);
      });

      test('still checks the npm login of every repo', () async {
        await command().checkTicket(
          directory: ticketDir,
          ggLog: ggLog,
          verbose: true,
          includeCanPublish: false,
        );

        verify(
          () => mockGgNpmLoggedIn.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).called(2);
        expect(messages.any((m) => m.contains('Logged in to npm?')), isTrue);
      });
    });

    group('--no-pana', () {
      /// The options every »gg can publish« of the run was called with.
      List<Map<String, dynamic>> capturedOptions() => verify(
        () => mockGgCanPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          options: captureAny(named: 'options'),
        ),
      ).captured.cast<Map<String, dynamic>>();

      test('forwards pana: false from the command line', () async {
        final runner = CommandRunner<void>('test', 'can publish ticket')
          ..addCommand(command());
        await runner.run(['publish', '--no-pana', '--input', ticketDir.path]);

        expect(capturedOptions(), [
          {gg.panaOption: false},
          {gg.panaOption: false},
        ]);
      });

      test('forwards pana: true by default', () async {
        final runner = CommandRunner<void>('test', 'can publish ticket')
          ..addCommand(command());
        await runner.run(['publish', '--input', ticketDir.path]);

        expect(capturedOptions(), [
          {gg.panaOption: true},
          {gg.panaOption: true},
        ]);
      });

      test('forwards pana: false from the exec options', () async {
        await command().exec(
          directory: ticketDir,
          ggLog: ggLog,
          options: const <String, dynamic>{gg.panaOption: false},
        );

        expect(capturedOptions(), [
          {gg.panaOption: false},
          {gg.panaOption: false},
        ]);
      });

      test('checkRepo() forwards its pana parameter', () async {
        await command().checkRepo(
          directory: repoDir('A'),
          ggLog: ggLog,
          pana: false,
        );

        expect(capturedOptions(), [
          {gg.panaOption: false},
        ]);
      });
    });

    test('get() still runs the complete check', () async {
      final runner = CommandRunner<void>('test', 'can publish ticket')
        ..addCommand(command());
      await runner.run(['publish', '--verbose', '--input', ticketDir.path]);

      verify(
        () => mockGgCanPublish.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          options: any(named: 'options'),
        ),
      ).called(2);
      verify(
        () => mockGgNpmLoggedIn.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).called(2);
      expect(messages, contains('\nAll repos can be published\n'));
    });

    test(
      'names the repo and the reason when it is not logged in to npm',
      () async {
        // A ticket mixes pub.dev, npm and registry-less repos, and the
        // per-repo detail goes to the task log, which is silent without
        // --verbose. A bare »Not logged in to npm.« therefore reads like the
        // check fired for a package that does not publish to npm at all.
        when(
          () => mockGgNpmLoggedIn.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer((invocation) {
          final dir = invocation.namedArguments[#directory] as Directory;
          if (path.basename(dir.path) == 'B') {
            throw Exception('Not logged in to the npm registry');
          }
          return Future.value();
        });

        await expectLater(
          () => command().checkTicket(
            directory: ticketDir,
            ggLog: ggLog,
            verbose: true,
          ),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              'Exception: Not logged in to npm.\n'
                  '  - B: Not logged in to the npm registry',
            ),
          ),
        );
        expect(
          messages.any((m) => m.contains('✗ Not logged in to npm')),
          isTrue,
        );

        // The npm sweep runs before `Can publish?`, so that step never starts.
        verifyNever(
          () => mockGgCanPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        );
      },
    );

    group('checkRepo()', () {
      test('passes for a publish-ready repo', () async {
        final dir = repoDir('A');
        await command().checkRepo(directory: dir, ggLog: ggLog);

        verify(
          () => mockGgCanPublish.exec(
            directory: dir,
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        ).called(1);
        expect(messages.first.split('\n'), ['', 'A']);
      });

      test('names the repo and the reason for one repo', () async {
        // The per-repo detail below goes to the task log, which is silent
        // without --verbose — so the reason has to travel in the exception.
        when(
          () => mockGgCanPublish.exec(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        ).thenThrow(Exception('pana failed'));

        await expectLater(
          () => command().checkRepo(directory: repoDir('B'), ggLog: ggLog),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              'Exception: Cannot publish.\n  - B: pana failed',
            ),
          ),
        );
        expect(messages, contains('✗ Cannot publish\nException: pana failed'));
      });

      test('works outside a ticket folder', () async {
        // It takes a repository, so it must not look for a ticket around it.
        final loneRepo = Directory(path.join(tempDir.path, 'lone'))
          ..createSync();
        await command().checkRepo(directory: loneRepo, ggLog: ggLog);

        verify(
          () => mockGgCanPublish.exec(
            directory: loneRepo,
            ggLog: any(named: 'ggLog'),
            options: any(named: 'options'),
          ),
        ).called(1);
      });
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
