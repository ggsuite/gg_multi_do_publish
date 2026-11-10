// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

library;

// Moved to gg_multi_core; still exported for the users of this package.
export 'package:gg_multi_core/gg_multi_core.dart' show ReadSettings;

export 'src/backend/ensure_in_registry.dart';
export 'src/backend/npm_registry_checker.dart';
export 'src/backend/pub_dev_checker.dart';
export 'src/commands/can/publish.dart';
export 'src/commands/do/configure_publish.dart';
export 'src/commands/do/publish.dart';
