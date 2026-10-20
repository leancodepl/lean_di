import 'dependency.dart';
import 'deps.dart';
import 'registerable.dart';

/// Groups several [Dependency] descriptors so they can be registered and
/// removed together as one unit - see [Deps.add]/[Deps.addAll] and
/// [Deps.remove], which also accepts a [Module] to remove every dependency
/// it lists. [DependencyDiagnostics.module] reports which [Module] (if any)
/// a given registered dependency came from.
class Module implements Registerable {
  /// Groups [entries] so they can be registered and removed together -
  /// see the class-level docs above.
  Module(
    List<SingleRegisterable> entries, {
    this.debugLabel,
  }) : dependencies = List.unmodifiable([
          for (final entry in entries) entry.dependency,
        ]);

  @override
  final List<Dependency<Object>> dependencies;

  /// A debug label to help identify this module in logs and diagnostics.
  final String? debugLabel;

  @override
  String toString() => "Module('$debugLabel')";
}
