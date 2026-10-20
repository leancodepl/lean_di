import 'alias.dart';
import 'dependency.dart';
import 'deps.dart';
import 'module.dart';

/// Something that can be passed to [Deps.add]/[Deps.addAll] (and removed via
/// [Deps.remove]) - implemented by [Dependency], [Alias] and [Module].
///
/// To create one, use [Dependency.new], [Dependency.value], [Alias.new], or
/// [Module.new].
abstract class Registerable {
  /// The individual [Dependency] descriptors this groups - just a
  /// single-element list containing itself for a standalone [Dependency],
  /// or every dependency listed in a [Module].
  Iterable<Dependency<Object>> get dependencies;
}

/// A [Registerable] that describes exactly one [dependency] - extended by
/// [Dependency] itself and by [Alias]. These are what can be listed inside a
/// [Module]; [Module] itself is deliberately not one, so modules don't nest.
abstract class SingleRegisterable implements Registerable {
  /// Allows subclasses to declare `const` constructors.
  const SingleRegisterable();

  /// The single [Dependency] this describes.
  Dependency<Object> get dependency;

  @override
  Iterable<Dependency<Object>> get dependencies => [dependency];
}
