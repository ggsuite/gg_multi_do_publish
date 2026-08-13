// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_lang/gg_lang.dart';

import 'package:gg_multi_do_publish/src/backend/pub_dev_checker.dart'
    show PackagePublishInfo;

/// The npm counterpart of [PubDevChecker]: checks whether published versions
/// are visible on npm, backed by gg_lang's [RegistryWaiter] over an
/// [NpmRegistry] (`npm view <name> version`).
///
/// A thin gg_multi-side adapter — registry interaction and the poll/wait logic
/// live in gg_lang.
class NpmRegistryChecker {
  /// Creates a new checker. Inject [_waiter] in tests; production resolves a
  /// [RegistryWaiter] over the npm registry from the language catalog.
  NpmRegistryChecker({
    this._waiter,
    this._catalog,
    this._delay,
    this.pollInterval = const Duration(seconds: 5),
    this.timeout = const Duration(minutes: 5),
  });

  final RegistryWaiter? _waiter;
  final LanguageCatalog? _catalog;
  final Future<void> Function(Duration duration)? _delay;

  /// Delay between poll attempts.
  final Duration pollInterval;

  /// Maximum waiting time for a version to appear on npm.
  final Duration timeout;

  /// Returns publish info for [packageName] (whether dependents must wait for
  /// npm availability). [workingDirectory] is the package directory — npm
  /// resolves the project-level `.npmrc` (scoped/private registries) there.
  Future<PackagePublishInfo> getPackagePublishInfo({
    required String packageName,
    String? workingDirectory,
  }) async {
    final waiter = await _resolveWaiter(workingDirectory);
    return PackagePublishInfo(
      packageName: packageName,
      waitsForPubDev: await waiter.isPublished(packageName: packageName),
    );
  }

  /// Returns whether [version] of [packageName] is already visible on npm.
  Future<bool> isVersionAvailable({
    required String packageName,
    required String version,
    String? workingDirectory,
  }) async {
    final waiter = await _resolveWaiter(workingDirectory);
    return waiter.isVersionAvailable(
      packageName: packageName,
      version: version,
    );
  }

  /// Waits until [version] of [packageName] is visible on npm. Progress
  /// (including the npm status page url) is reported through [ggLog].
  Future<void> waitUntilVersionAvailable({
    required String packageName,
    required String version,
    required void Function(String message) ggLog,
    String? workingDirectory,
  }) async {
    final waiter = await _resolveWaiter(workingDirectory, log: ggLog);
    await waiter.waitUntilVersionAvailable(
      packageName: packageName,
      version: version,
    );
  }

  // ...........................................................................
  Future<RegistryWaiter> _resolveWaiter(
    String? workingDirectory, {
    void Function(String message)? log,
  }) async {
    if (_waiter != null) {
      return _waiter;
    }
    // coverage:ignore-start
    final catalog = _catalog ?? await LanguageCatalog.load();
    final spec = catalog.spec(ProjectType.typescript);
    final registry = const RegistryFactory().forProjectType(
      ProjectType.typescript,
      spec: spec,
      workingDirectory: workingDirectory,
    );

    // The status page comes from the merged .npmrc: a scoped package on a
    // private feed is not on npmjs.com, and printing that link sends the user
    // to a 404. The catalog template is the fallback when nothing resolves.
    final statusUrl = workingDirectory == null
        ? spec.registry?.statusUrl
        : await NpmRegistryResolver().statusUrlTemplateOf(
            directory: Directory(workingDirectory),
            fallback: spec.registry?.statusUrl,
          );

    return RegistryWaiter(
      registry: registry,
      registryName: 'npm',
      statusUrl: statusUrl,
      log: log,
      delay: _delay,
      pollInterval: pollInterval,
      timeout: timeout,
    );
    // coverage:ignore-end
  }
}
