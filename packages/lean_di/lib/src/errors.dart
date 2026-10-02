import 'package:lean_di/src/is_debug_mode.dart';

import 'types.dart';

/// Thrown by `Deps.get` and `Deps.tryGet` when no dependency is registered
/// under [key] in this `Deps` scope or any of its ancestors.
class DependencyNotRegisteredError extends Error {
  /// Thrown for [key] - see the class-level docs above.
  DependencyNotRegisteredError(this.key);

  /// The key that was looked up.
  final DependencyKey key;

  @override
  String toString() {
    if (!kIsDebugBuild) {
      return '''
DependencyNotRegisteredError: No dependency is registered for key ($key) in this Deps scope or any of its ancestors.
''';
    }

    return '''
DependencyNotRegisteredError: No dependency is registered for key ($key) in this Deps scope or any of its ancestors.

Make sure it was added via Deps.add/Deps.replace, or listed in the register argument of a DepsProvider above this point in the widget tree.

If you have registered a dependency this issue may be caused by:

1. A type mismatch. Deps looks up by exact runtime Type - Dependency<FooImpl> is not found by deps.get<Foo>(). Register an Alias, or look up the same type you registered.

2. Looking up in a different Deps scope than the one you registered in - e.g. a forked child that hasn't inherited it, or a DepsProvider on another route (including dialogs, modals, overlays).

Bad:
deps.add(Dependency<FooImpl>((deps, _) => FooImpl()));
final foo = deps.get<Foo>(); // throws - FooImpl ≠ Foo

Good:
deps.add(Dependency<Foo>((deps, _) => FooImpl()));
final foo = deps.get<Foo>();

Good:
deps.addAll([
  Dependency<FooImpl>((deps, _) => FooImpl()),
  const Alias<Foo, FooImpl>(),
]);
final foo = deps.get<Foo>();
''';
  }
}

/// Thrown when an operation needs this `Deps` scope to still be alive, but
/// `Deps.dispose` has already been called on it - by `Deps.add` (adding to a
/// disposed scope makes no sense) and by `Deps.get`/`Deps.tryGet` (resolving
/// a value from a scope whose dependencies have all been torn down doesn't
/// either).
class DepsDisposedError extends Error {
  /// Thrown for the failing operation, optionally naming the [key] it was
  /// about - see the class-level docs above.
  DepsDisposedError({this.key});

  /// The dependency key involved, if the failing operation was about a
  /// specific key (e.g. `Deps.get`) rather than the scope as a whole (e.g.
  /// `Deps.add`).
  final DependencyKey? key;

  @override
  String toString() {
    if (!kIsDebugBuild) {
      return '''
DepsDisposedError: This Deps scope has already been disposed${key != null ? ' for requested key ($key)' : ''} and can no longer register or resolve dependencies.
''';
    }

    return '''
DepsDisposedError: This Deps scope has already been disposed${key != null ? ' for requested key ($key)' : ''} and can no longer register or resolve dependencies.

If this came from a widget, you're likely holding onto a Deps reference that outlived its DepsProvider - e.g. a callback that captured a Deps and ran after the provider that owned it unmounted.

Don't store a Deps from BuildContext.deps / DepsProvider.of and use it after that widget is gone. Look it up when you need it, or keep the work inside the widget's lifetime.

Bad:
late final Deps deps;

@override
void initState() {
  super.initState();
  deps = context.deps;
}

void onPressed() {
  deps.get<Foo>(); // throws if DepsProvider has already unmounted
}

Good:
void onPressed() {
  context.get<Foo>();
}
''';
  }
}

/// Thrown when resolving [key] re-enters its own `Dependency.create` before
/// the first call has finished - i.e. a dependency, directly or indirectly,
/// depends on itself.
class DependencyCycleError extends Error {
  /// Thrown for [key] - see the class-level docs above.
  DependencyCycleError(this.key);

  /// The key whose creation cycled back on itself.
  final DependencyKey key;

  @override
  String toString() {
    if (!kIsDebugBuild) {
      return '''
DependencyCycleError: Creating key ($key) triggered another attempt to resolve key ($key) before the first one finished.
''';
    }

    return '''
DependencyCycleError: Creating key ($key) triggered another attempt to resolve key ($key) before the first one finished.

This usually means Dependency.create for ($key) - directly, or indirectly via Deps.get inside it - depends on itself.

deps.add(Dependency<Foo>((deps, _) => Foo(other: deps.get<Foo>())));

Or a longer cycle, e.g. Foo -> Bar -> Foo:

deps.addAll([
  Dependency<Foo>((deps, _) => Foo(bar: deps.get<Bar>())),
  Dependency<Bar>((deps, _) => Bar(foo: deps.get<Foo>())),
]);

Break the cycle by not reading ($key) while it is still being created - pass the collaborator in, register one of them as a value, or split the dependency.
''';
  }
}
