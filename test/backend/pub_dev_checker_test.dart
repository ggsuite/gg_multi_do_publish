// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_lang/gg_lang.dart';
import 'package:gg_multi_do_publish/src/backend/pub_dev_checker.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  late MockRegistry registry;
  late PubDevChecker checker;

  setUp(() {
    registry = MockRegistry();
    checker = PubDevChecker(
      waiter: RegistryWaiter(
        registry: registry,
        registryName: 'pub.dev',
        delay: (_) async {},
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
  });

  void mockLatest(Version? version) {
    when(() => registry.latestVersion(packageName: any(named: 'packageName')))
        .thenAnswer((_) async => version);
  }

  group('PubDevChecker', () {
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

    test('has sensible default timeouts', () {
      final checker = PubDevChecker();
      expect(checker.timeout, const Duration(minutes: 15));
      expect(checker.pollInterval, const Duration(seconds: 15));
    });

    test('PackagePublishInfo exposes its fields', () {
      const info = PackagePublishInfo(packageName: 'x', waitsForPubDev: true);
      expect(info.packageName, 'x');
      expect(info.waitsForPubDev, isTrue);
    });
  });
}
