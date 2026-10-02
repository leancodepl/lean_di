<div align="center">

[![Banner][banner-img]][leancode-landing]

</div>

# Lean DI

A service-locator-based dependency injection solution for Dart, with scopes,
modules, computed dependencies, and reactivity support.

This documentation is for plain Dart usage of Lean DI. For usage in Flutter see
[`flutter_lean_di`](https://pub.dev/packages/flutter_lean_di).

## Installation

```sh
dart pub add lean_di
```

## Quick start

```dart
import 'package:lean_di/lean_di.dart';

void main() {
  Deps.global.add(Dependency.value(Greeter()));

  final greeter = Deps.global.get<Greeter>();

  greeter.greet();
}

class Greeter {
  void greet() => print('Hello world!');
}
```

`Deps.global` is the global, ambient `Deps` container - a box you register
services into and look them up from anywhere, by type. Everything below builds
on that one idea: `add(...)` to register, `get<T>()` to look up.

> **A note on `create`:** every `Dependency`'s `create` callback takes two
> positional parameters - `(DepsReader deps, T? oldValue)`. `oldValue` is
> only relevant for the "computed dependency" recipe below; for a plain
> one-shot factory, just ignore it (`(deps, _) => ...`).

## Common recipes

### Registering a dependency

```dart
// A value that already exists and never changes.
Deps.global.add(Dependency.value(SomeService()));

// Lazily created on first use.
Deps.global.add(Dependency((deps, _) => SomeService()));

// With cleanup when removed/replaced/the scope is disposed.
Deps.global.add(
  Dependency(
    (deps, _) => SomeService(),
    dispose: (service) => service.dispose(),
  ),
);

// Eagerly created on registration - once the whole add()/addAll() call has
// registered everything, so it can read dependencies registered with it.
Deps.global.add(Dependency((deps, _) => SomeService(), lazy: false));

// Depending on another registered service.
Deps.global.add(
  Dependency(
    (deps, _) => SomeOtherService(deps.get<SomeService>()),
  ),
);
```

### Reading a dependency

```dart
// Returns an instance of the dependency, creating it first if needed. Throws
// DependencyNotRegisteredError if the dependency has not been registered.
SomeService service = Deps.global.get<SomeService>();

// Same, but returns null instead of throwing if dependency has not been
// registered.
SomeService? service = Deps.global.tryGet<SomeService>();

// Returns an instance of the dependency if it has been already created. Returns
// null if instance of the dependency has not been created yet and doesn't
// trigger creation. Returns null if dependency has not been registered.
SomeService? service = Deps.global.peek<SomeService>();
```

### Watching for changes

```dart
// Fires whenever a *new instance* is registered under this type (add()
// with a changed cacheKey, or replace()) - not on that instance's own
// internal state changes. Cheap: never subscribes to the value itself.
Stream<SomeService> instances = Deps.global.watchInstance<SomeService>();

// Fires on registration changes AND on internal state changes reported by
// the resolved value's DependencyObserver, if it has one - see "Observing
// internal state changes" below.
Stream<SomeService> full = Deps.global.watch<SomeService>();

// Combine several dependencies - handy for a widget/effect that needs more
// than one. watch2..watch5 cover 2-5 types; they use watchInstance
// semantics, not watch, for each.
Deps.global.watch2<UserService, SettingsService>().listen((values) {
  final (user, settings) = values;
  // ...
});
```

### Computed dependencies

A dependency can recompute its value in reaction to another one changing -
`create` is simply called again, with the previous value as `oldValue`,
whenever a key it read via `deps.watchInstance(...)` (not the untracked
`deps.get(...)`) on its *last* run gets re-registered under a new instance.
There's no separate list of "what to observe" to keep in sync - reading via
`watchInstance` inside `create` *is* the declaration, rediscovered fresh on
every run:

```dart
Deps.global.add(
  Dependency<UserGreeting>((deps, oldValue) {
    final user = deps.watchInstance<UserService>().currentUser;
    return oldValue == null
        ? UserGreeting('Hello, ${user.name}!')
        : oldValue.copyWith(text: 'Hello, ${user.name}!');
  }),
);
```

Which keys are tracked can even depend on `oldValue`, so a `create` that
takes a different branch on a later run automatically re-subscribes to
whatever it read *this* time, dropping keys it no longer reads.

### Registering the same instance under another type

Useful for exposing a concrete implementation through an interface, so
either can be looked up:

```dart
Deps.global.addAll([
  Dependency<SomeServiceImpl>((deps, _) => SomeServiceImpl()),
  const Alias<SomeService, SomeServiceImpl>(),
]);

Deps.global.get<SomeService>() == Deps.global.get<SomeServiceImpl>(); // true
```

The alias is lazy, stays in sync with a later `replace<SomeServiceImpl>(...)`,
and never disposes anything itself - only `SomeServiceImpl`'s own `dispose`
(if any) tears the shared instance down. `watch<SomeService>()` does
*not* react to the shared instance's internal state changes by default -
`SomeService` declares nothing about being observable, so nothing is
assumed; pass `createObserver` to `Alias` explicitly if you want that.

One caveat worth knowing: because this is sugar for a second, independent
registration, removing only `SomeServiceImpl` (bare
`remove<SomeServiceImpl>()`) leaves the `SomeService` key registered
and pointing at what's now a disposed instance. Register and remove them
together - e.g. via a `Module` (see below), or by removing both keys
explicitly.

### Observing internal state changes

Beyond "a new instance was registered," a dependency can report its own
internal state changes (e.g. a mutable object notifying its listeners) so
`watch<T>()` reacts to those too, not just registration:

```dart
Deps.global.add(
  Dependency<Counter>(
    (deps, _) => Counter(),
    createObserver: (counter) => CounterObserver(counter),
  ),
);

Deps.global.watch<Counter>().listen((counter) => print('now: ${counter.value}'));

class CounterObserver extends DependencyObserver<Counter> {
  CounterObserver(this.counter) {
    counter.addListener(_onChange);
  }

  final Counter counter;

  void _onChange() => notifyStateChanged();

  @override
  Future<void> dispose() async => counter.removeListener(_onChange);
}
```

One observer is created per resolved value (shared by every subscriber),
and only once something actually calls `watch()` - a dependency that's
only ever plain-read via `get()` never pays for this. If you're on Flutter,
[`flutter_lean_di`](https://pub.dev/packages/flutter_lean_di) ships
`ChangeNotifierDependency`/`ListenableDependency` for `ChangeNotifier`
/`Listenable` values, and
[`flutter_lean_di_bloc`](https://pub.dev/packages/flutter_lean_di_bloc)
ships `BlocDependency` for `bloc`/`cubit` - you rarely need to write a
`DependencyObserver` by hand outside plain Dart code.

### Scoping

`Deps` instances form a tree: a child scope (`fork`) inherits everything
its ancestors have registered, and can override specific keys locally
without touching the parent. Changes in an ancestor (a new registration, a
replacement, an internal state change) propagate down to every descendant
that hasn't shadowed that key itself.

```dart
final authScope = Deps.global.fork(debugLabel: 'AuthScope');
authScope.add(Dependency<AuthToken>.value(AuthToken('...')));

authScope.get<AuthToken>();       // registered directly in authScope
authScope.get<SomeGlobalService>(); // inherited from Deps.global (the parent)

await authScope.dispose(); // disposes only what authScope itself registered
```

`Deps()` creates a scope with no parent at all - useful for tests,
so each test gets a clean, isolated container instead of sharing
`Deps.global`.

### Grouping dependencies

A `Module` bundles several dependencies so they're added and removed
together as one unit:

```dart
final authModule = Module([
  Dependency<AuthService>((deps, _) => AuthService()),
  Dependency<TokenStorage>((deps, _) => TokenStorage()),
], debugLabel: 'Auth');

Deps.global.add(authModule);
// ...
Deps.global.remove(authModule); // removes both AuthService and TokenStorage
```

`remove(...)` also accepts a fresh `Module`/`Dependency` describing
the same types - lookup is by type, not by holding onto the exact instance
that was originally registered.

### Startup dependencies via tags

You can use tags for more complex creation orchestration scenarios than the
eager creation on registration provided by `lazy: false`. Tag dependencies
that need to be ready at some point, and create them all when needed:

```dart
void main() {
  Deps.global
    ..add(Dependency<Database>((deps, _) => Database(), tags: const ['startup']))
    ..add(Dependency<Analytics>((deps, _) => Analytics(), tags: const ['startup']));

  // ...

  final startupKeys = Deps.global.getEntriesWithTag('startup').map((d) => d.key);
  Deps.global.ensureResolved(startupKeys); // synchronous - forces creation now

  startServer();
}
```

### Removing and replacing

```dart
final unregister = Deps.global.add(Dependency<Foo>((deps, _) => Foo()));
unregister(); // equivalent to remove<Foo>()

// add() again under the same key/cacheKey keeps the existing value, but the
// entry takes on the new dependency - its lazy flag, and the create/dispose
// used from then on. replace() always tears down and recreates.
Deps.global.replace(Dependency<Foo>((deps, _) => Foo()));
```

### Error handling

| Error                          | Thrown by                     | When                                                                 |
| ------------------------------ | ----------------------------- | -------------------------------------------------------------------- |
| `DependencyNotRegisteredError` | `get`                         | Nothing is registered under that key in this scope or its ancestors. |
| `DepsDisposedError`            | `add`, `get`, `tryGet`        | The scope has already been disposed.                                 |
| `DependencyCycleError`         | `get`, `tryGet` (on creation) | `create` re-enters resolving its own key before finishing.           |

`isRegistered<T>()` and `tryGet<T>()` are the ways to check whether a
dependency is registered without `get` throwing.

An error thrown by the `create` of an eager (`lazy: false`) dependency isn't
thrown from `add`/`addAll` - it's reported to the current zone's error
handler, the other dependencies are still registered and created, and the
failed one is created again on its next `get`.

## See also

- [`flutter_lean_di`](https://pub.dev/packages/flutter_lean_di) - Flutter
  integration: a `DepsProvider` widget, `context.get`/`watch`/`watchInstance`
  /`select`, and Flutter-flavored `Dependency` subclasses.
- [`flutter_lean_di_bloc`](https://pub.dev/packages/flutter_lean_di_bloc) -
  `bloc`/`cubit` integration on top of `flutter_lean_di`.

---

## 🛠️ Maintained by LeanCode
<div align="center">

  [<img src="https://leancodepublic.blob.core.windows.net/public/wide.png" alt="LeanCode Logo" width="300" />][leancode-landing]

</div>

This package is built with 💙 by **[LeanCode][leancode-landing]**.
We are **top-tier experts** focused on Flutter Enterprise solutions.

### Why LeanCode?

- **Creators of [Patrol][patrol-landing]** – the next-gen testing framework for Flutter.

- **Production-Ready** – We use this package in apps with millions of users.

- **Full-Cycle Product Development** – We take your product from scratch to long-term maintenance.

<div align="center">
  <br />

  **Need help with your Flutter project?**

  [**👉 Hire our team**][leancode-estimate]
  &nbsp;&nbsp;•&nbsp;&nbsp;
  [Check our other packages][leancode-packages]

</div>

[banner-img]: https://raw.githubusercontent.com/leancodepl/lean_di/refs/heads/main/packages/lean_di/doc/banner.png 
[leancode-landing]: https://leancode.co/?utm_source=github.com&utm_medium=referral&utm_campaign=lean_di
[leancode-estimate]: https://leancode.co/get-estimate?utm_source=github.com&utm_medium=referral&utm_campaign=lean_di
[leancode-packages]: https://pub.dev/packages?q=publisher%3Aleancode.co&sort=downloads
[patrol-landing]: https://patrol.leancode.co/?utm_source=github.com&utm_medium=referral&utm_campaign=lean_di