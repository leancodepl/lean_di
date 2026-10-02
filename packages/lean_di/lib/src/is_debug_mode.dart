import 'package:meta/meta.dart';

/// Whether this is a debug build - the same computation Flutter's own
/// `kDebugMode` uses, replicated here so it works without a dependency on
/// Flutter (this package doesn't have one, on purpose).
@internal
const bool kIsDebugBuild = !bool.fromEnvironment('dart.vm.product') &&
    !bool.fromEnvironment('dart.vm.profile');
