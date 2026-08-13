// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_lang/gg_lang.dart';

/// Checks whether published versions are visible on pub.dev, backed by
/// gg_lang's [RegistryWaiter] over a [PubDevRegistry].
///
/// This is a thin gg_multi-side adapter: all registry interaction and the
/// poll/wait logic live in gg_lang. The class is kept (rather than using
/// [RegistryWaiter] directly) so the publish flow can inject a mock and
/// dispatch by project type.
class PubDevChecker {
  /// Creates a new checker. Inject [waiter] in tests; production resolves a
  /// [RegistryWaiter] over the pub.dev registry from the language catalog.
  PubDevChecker({
    RegistryWaiter? waiter,
    LanguageCatalog? catalog,
    Future<void> Function(Duration duration)? delay,
    this.pollInterval = const Duration(seconds: 15),
    // pub.dev can take up to ~10 minutes to make a fresh upload visible —
    // the default leaves headroom beyond that.
    this.timeout = const Duration(minutes: 15),
  }) : _waiter = waiter,
       _catalog = catalog,
       _delay = delay;

  final RegistryWaiter? _waiter;
  final LanguageCatalog? _catalog;
  final Future<void> Function(Duration duration)? _delay;

  /// Delay between poll attempts.
  final Duration pollInterval;

  /// Maximum waiting time for a version to appear on pub.dev.
  final Duration timeout;

  /// Returns publish info for [packageName] (whether dependents must wait for
  /// pub.dev availability).
  Future<PackagePublishInfo> getPackagePublishInfo({
    required String packageName,
  }) async {
    final waiter = await _resolveWaiter();
    return PackagePublishInfo(
      packageName: packageName,
      waitsForPubDev: await waiter.isPublished(packageName: packageName),
    );
  }

  /// Returns whether [version] of [packageName] is already visible on pub.dev.
  Future<bool> isVersionAvailable({
    required String packageName,
    required String version,
  }) async {
    final waiter = await _resolveWaiter();
    return waiter.isVersionAvailable(
      packageName: packageName,
      version: version,
    );
  }

  /// Waits until [version] of [packageName] is visible on pub.dev. Progress
  /// (including the pub.dev status page url) is reported through [ggLog].
  Future<void> waitUntilVersionAvailable({
    required String packageName,
    required String version,
    required void Function(String message) ggLog,
  }) async {
    final waiter = await _resolveWaiter(log: ggLog);
    await waiter.waitUntilVersionAvailable(
      packageName: packageName,
      version: version,
    );
  }

  // ...........................................................................
  Future<RegistryWaiter> _resolveWaiter({
    void Function(String message)? log,
  }) async {
    if (_waiter != null) {
      return _waiter;
    }
    // coverage:ignore-start
    final catalog = _catalog ?? await LanguageCatalog.load();
    final spec = catalog.spec(ProjectType.dart);
    final registry = const RegistryFactory().forProjectType(
      ProjectType.dart,
      spec: spec,
    );
    return RegistryWaiter(
      registry: registry,
      registryName: 'pub.dev',
      statusUrl: spec.registry?.statusUrl,
      log: log,
      delay: _delay,
      pollInterval: pollInterval,
      timeout: timeout,
    );
    // coverage:ignore-end
  }
}

/// Describes how a package is published.
class PackagePublishInfo {
  /// Creates a publish info model.
  const PackagePublishInfo({
    required this.packageName,
    required this.waitsForPubDev,
  });

  /// The package name from the manifest.
  final String packageName;

  /// Whether dependent publishes must wait for registry availability.
  final bool waitsForPubDev;
}
