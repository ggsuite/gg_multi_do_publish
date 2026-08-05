// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_do_publish/src/backend/ensure_in_registry.dart';
import 'package:gg_publish/gg_publish.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

class FakeDirectory extends Fake implements Directory {}

void main() {
  late Directory d;
  late MockIsInRegistry isInRegistry;
  final messages = <String>[];
  // The same messages with their color codes intact, for tests that assert
  // how a message is highlighted.
  final coloredMessages = <String>[];

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
  });

  // Collects log messages while removing color codes.
  void ggLog(String msg) {
    coloredMessages.add(msg);
    messages.add(rmControls(msg));
  }

  // ...........................................................................
  /// Makes the registry report the given states, one per call. The last
  /// state is repeated for further calls.
  void mockInRegistry(List<bool?> results) {
    var call = 0;
    when(
      () => isInRegistry.inRegistry(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {
      final result = results[call < results.length ? call : results.length - 1];
      call++;
      return result;
    });
  }

  // ...........................................................................
  /// Creates an [EnsureInRegistry] whose prompt returns [answers] one by one
  /// and whose terminal check reports [hasTerminal].
  EnsureInRegistry ensureInRegistry({
    List<String?> answers = const [],
    bool hasTerminal = true,
  }) {
    final remaining = [...answers];
    return EnsureInRegistry(
      ggLog: ggLog,
      isInRegistry: isInRegistry,
      readLineFromStdIn: () => remaining.removeAt(0),
      hasTerminal: () => hasTerminal,
    );
  }

  // ...........................................................................
  setUp(() {
    messages.clear();
    coloredMessages.clear();
    isInRegistry = MockIsInRegistry();
    d = Directory.systemTemp.createTempSync('ensure_in_registry_test_');
    File(
      path.join(d.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: test_pkg\nversion: 1.0.0\n');
  });

  // ...........................................................................
  tearDown(() {
    if (d.existsSync()) {
      d.deleteSync(recursive: true);
    }
  });

  // ...........................................................................
  group('EnsureInRegistry', () {
    group('ensure(directory, ggLog)', () {
      test(
        'does nothing when the package is already in the registry',
        () async {
          mockInRegistry([true]);

          await ensureInRegistry().ensure(directory: d, ggLog: ggLog);

          expect(messages, isEmpty);
        },
      );

      test('does nothing when the package has no public registry', () async {
        mockInRegistry([null]);

        await ensureInRegistry().ensure(directory: d, ggLog: ggLog);

        expect(messages, isEmpty);
      });

      test('asks for a manual first publish of a Dart package '
          'and continues once it is in the registry', () async {
        mockInRegistry([false, true]);

        await ensureInRegistry(
          answers: [''],
        ).ensure(directory: d, ggLog: ggLog);

        final log = messages.join('\n');
        expect(
          log,
          contains('»test_pkg« has no version published on pub.dev yet.'),
        );
        expect(
          log,
          contains(
            'publish the first version manually directly out of the '
            'current working folder',
          ),
        );
        expect(log, contains('cd ${d.absolute.path}'));
        expect(log, contains('dart pub publish'));
        expect(
          log,
          contains('Press ⏎ once the package is published, »q« + ⏎ to abort.'),
        );
        expect(
          log,
          contains('»test_pkg« is now available on pub.dev. Continuing.'),
        );
      });

      test('shows the shell commands in blue', () async {
        mockInRegistry([false, true]);

        await ensureInRegistry(
          answers: [''],
        ).ensure(directory: d, ggLog: ggLog);

        final blueMessages = coloredMessages.where(
          (m) => m.startsWith('\x1B[34m'),
        );
        expect(blueMessages, hasLength(2));
        expect(blueMessages.first, contains('cd ${d.absolute.path}'));
        expect(blueMessages.last, contains('dart pub publish'));
      });

      test('asks again while the package is not yet visible', () async {
        mockInRegistry([false, false, true]);

        await ensureInRegistry(
          answers: ['', ''],
        ).ensure(directory: d, ggLog: ggLog);

        expect(
          messages.join('\n'),
          contains(
            '»test_pkg« is not yet visible on pub.dev. A fresh publish '
            'can take a few minutes to appear. Please try again.',
          ),
        );
      });

      test('throws when the user aborts with »q«', () async {
        mockInRegistry([false]);

        await expectLater(
          ensureInRegistry(answers: ['q']).ensure(directory: d, ggLog: ggLog),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains(
                'Publishing aborted: »test_pkg« has no version on pub.dev.',
              ),
            ),
          ),
        );
      });

      test('throws when stdin is not a terminal', () async {
        mockInRegistry([false]);

        await expectLater(
          ensureInRegistry(
            hasTerminal: false,
          ).ensure(directory: d, ggLog: ggLog),
          throwsA(
            isA<Exception>().having(
              (e) => rmControls(e.toString()),
              'message',
              contains('Cannot show the first-publish prompt'),
            ),
          ),
        );
      });

      test('shows a pnpm command with »--access public« for a scoped '
          'npm package', () async {
        File(path.join(d.path, 'pubspec.yaml')).deleteSync();
        File(
          path.join(d.path, 'package.json'),
        ).writeAsStringSync('{"name": "@org/test_pkg", "version": "1.0.0"}');
        File(path.join(d.path, 'tsconfig.json')).writeAsStringSync('{}');
        mockInRegistry([false, true]);

        await ensureInRegistry(
          answers: [''],
        ).ensure(directory: d, ggLog: ggLog);

        final log = messages.join('\n');
        expect(
          log,
          contains('»@org/test_pkg« has no version published on npm yet.'),
        );
        expect(log, contains('pnpm publish --no-git-checks --access public'));
      });

      test('shows a plain pnpm command for an unscoped npm package', () async {
        File(path.join(d.path, 'pubspec.yaml')).deleteSync();
        File(
          path.join(d.path, 'package.json'),
        ).writeAsStringSync('{"name": "test_pkg", "version": "1.0.0"}');
        File(path.join(d.path, 'tsconfig.json')).writeAsStringSync('{}');
        mockInRegistry([false, true]);

        await ensureInRegistry(
          answers: [''],
        ).ensure(directory: d, ggLog: ggLog);

        final log = messages.join('\n');
        expect(log, contains('pnpm publish --no-git-checks'));
        expect(log, isNot(contains('--access public')));
      });

      test('treats a null answer like an empty one', () async {
        mockInRegistry([false, true]);

        await ensureInRegistry(
          answers: [null],
        ).ensure(directory: d, ggLog: ggLog);

        expect(
          messages.join('\n'),
          contains('»test_pkg« is now available on pub.dev. Continuing.'),
        );
      });
    });

    test('can be created with default dependencies', () {
      expect(EnsureInRegistry(ggLog: ggLog), isNotNull);
    });
  });
}
