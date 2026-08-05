// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_lang/gg_lang.dart';
import 'package:gg_multi_do_publish/src/backend/npm_registry_checker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  late MockRegistry registry;
  late NpmRegistryChecker checker;

  setUp(() {
    registry = MockRegistry();
    checker = NpmRegistryChecker(
      waiter: RegistryWaiter(
        registry: registry,
        registryName: 'npm',
        delay: (_) async {},
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
  });

  void mockLatest(Version? version) {
    when(
      () => registry.latestVersion(packageName: any(named: 'packageName')),
    ).thenAnswer((_) async => version);
  }

  group('NpmRegistryChecker', () {
    test(
      'getPackagePublishInfo reports whether the package is published',
      () async {
        mockLatest(Version(1, 0, 0));
        final info = await checker.getPackagePublishInfo(packageName: 'a');
        expect(info.packageName, 'a');
        expect(info.waitsForPubDev, isTrue);

        mockLatest(null);
        final info2 = await checker.getPackagePublishInfo(packageName: 'b');
        expect(info2.waitsForPubDev, isFalse);
      },
    );

    test('isVersionAvailable delegates to the waiter', () async {
      mockLatest(Version(1, 2, 4));
      expect(
        await checker.isVersionAvailable(packageName: 'a', version: '1.2.4'),
        isTrue,
      );

      mockLatest(Version(1, 2, 3));
      expect(
        await checker.isVersionAvailable(packageName: 'a', version: '1.2.4'),
        isFalse,
      );
    });

    test(
      'waitUntilVersionAvailable returns once the version is visible',
      () async {
        mockLatest(Version(1, 2, 4));
        await checker.waitUntilVersionAvailable(
          packageName: 'a',
          version: '1.2.4',
          ggLog: (_) {},
        );
      },
    );
  });
}
