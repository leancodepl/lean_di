<div align="center">

[![Banner][banner-img]][leancode-landing]

</div>

# Lean DI for Flutter

Service-locator-based dependency injection for Flutter, with modules,
reactivity, and scopes bound to the widget tree but accesible outside it.

This documentation is for Flutter usage of Lean DI. For usage in plain Dart
see [`lean_di`](https://pub.dev/packages/lean_di), which `flutter_lean_di`
builds on and re-exports.

## Installation

```sh
flutter pub add flutter_lean_di
```

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:flutter_lean_di/flutter_lean_di.dart';

void main() => runApp(const MaterialApp(home: CounterPage()));

class Counter extends ChangeNotifier {
  int value = 0;

  void increment() {
    value++;
    notifyListeners();
  }
}

class CounterPage extends StatelessWidget {
  const CounterPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Counter is created on first use and disposed together with this
    // DepsProvider.
    return DepsProvider(
      register: [ChangeNotifierDependency<Counter>((deps, _) => Counter())],
      builder: (context, _) => Scaffold(
        // Rebuilds whenever Counter calls notifyListeners().
        body: Center(child: Text('${context.watch<Counter>().value}')),
        floatingActionButton: FloatingActionButton(
          // Reads Counter without listening to it.
          onPressed: () => context.get<Counter>().increment(),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}
```

A `DepsProvider` puts a `Deps` scope - a box of dependencies, looked up by
type - into the widget tree. Dependencies listed in `register` live exactly as
long as the `DepsProvider` does, and every widget below it can read them from
`context`.

> **A note on `create`:** every `Dependency`'s `create` callback takes two
> positional parameters - `(DepsReader deps, T? oldValue)`. `deps` reads other
> dependencies, and `oldValue` is only relevant for computed dependencies (see
> [`lean_di`](https://pub.dev/packages/lean_di#computed-dependencies)). For a
> plain factory, just ignore it: `(deps, _) => ...`.

## Registering dependencies

```dart
DepsProvider(
  register: [
    // A value that already exists and never changes.
    Dependency.value(SomeConfig()),

    // Lazily created on first use.
    Dependency((deps, _) => SomeService()),

    // Eagerly created as soon as the DepsProvider registers it.
    Dependency((deps, _) => Analytics(), lazy: false),

    // With cleanup when the DepsProvider is disposed.
    Dependency(
      (deps, _) => SomeRepository(),
      dispose: (repository) => repository.close(),
    ),

    // Depending on another dependency - registered here or anywhere above.
    Dependency((deps, _) => SomeOtherService(deps.get<SomeService>())),

    // A ChangeNotifier: context.watch() rebuilds on notifyListeners(), and
    // it's disposed with the DepsProvider.
    ChangeNotifierDependency<Counter>((deps, _) => Counter()),

    // Any other Listenable: same, but without a default dispose.
    ListenableDependency<ValueNotifier<int>>((deps, _) => ValueNotifier(0)),
  ],
  child: const SomeScreen(),
);
```

For `Bloc`s and `Cubit`s, see
[`flutter_lean_di_bloc`](https://pub.dev/packages/flutter_lean_di_bloc)'s
`BlocDependency`.

### Registrations across rebuilds

`register` is applied again every time the `DepsProvider` rebuilds, the same
way Flutter treats widgets:

- A dependency with the same type and `cacheKey` as before keeps its value.
  From then on it uses the new `Dependency` - e.g. its `dispose`.
- A dependency with a different `cacheKey` is disposed and created again.
- A dependency that's no longer listed is removed and disposed.

So a dependency built from widget parameters should use them as its
`cacheKey`:

```dart
DepsProvider(
  register: [
    ChangeNotifierDependency<UserDetails>(
      (deps, _) => UserDetails(userId),
      // A new userId disposes the old UserDetails and creates a new one.
      cacheKey: userId,
    ),
  ],
  child: const UserScreen(),
);
```

## Reading dependencies

```dart
// Reads a dependency without listening to it - like provider's
// context.read(). Use it in callbacks, e.g. onPressed.
final service = context.get<SomeService>();

// Rebuilds when a new instance is registered AND when the current one reports
// an internal change, e.g. a ChangeNotifier calling notifyListeners().
final counter = context.watch<Counter>();

// Rebuilds only when a new instance is registered - not on its internal
// changes. Cheaper when you only care which instance is there.
final auth = context.watchInstance<AuthService>();

// Rebuilds only when the selected value changes (compared with ==).
final isEven = context.select<Counter, bool>((counter) => counter.value.isEven);

// Nullable variants for dependencies that might not be registered.
final maybeCounter = context.maybeWatch<Counter>();

// The nearest Deps scope itself, e.g. for tryGet() or peek().
final deps = context.deps;
```

Use `context.watch`, `context.watchInstance` and `context.select` in `build`,
and `context.get` in callbacks. `DepsProvider.of(context)` and the static
`DepsProvider.watch`/`watchInstance`/`select` (and their `maybe...` variants)
do the same without the `context` extension.

### `child` vs `builder`

`child` is built with the `context` from *above* the `DepsProvider`, which
can't see its dependencies. To read them right away, use `builder` - or put
the reading code in a separate widget:

```dart
// Bad: this context doesn't see Foo.
DepsProvider(
  register: [Dependency((deps, _) => Foo())],
  child: Text(context.get<Foo>().label),
);

// Good.
DepsProvider(
  register: [Dependency((deps, _) => Foo())],
  builder: (context, _) => Text(context.get<Foo>().label),
);
```

## Scoping

A `DepsProvider(...)` forks the nearest scope above it: it can read everything
its ancestors registered, and a dependency it registers under the same type
shadows the ancestor's one for its subtree only. That gives you
a dependency per app, per screen or per flow, depending on where the
`DepsProvider` sits.

### App-wide dependencies

Register app-wide dependencies in `Deps.global` - it can be used outside the
widget tree too - and expose it to the widgets with `DepsProvider.global` at the
root of the app:

```dart
void main() {
  Deps.global.addAll([
    Dependency.value(Logger()),
    Dependency((deps, _) => ApiClient(deps.get<Logger>())),
  ]);

  runApp(DepsProvider.global(child: const MyApp()));
}
```

Every `DepsProvider` below forks `Deps.global`, so they can all read `Logger`
and `ApiClient`. Without `DepsProvider.global`, the topmost `DepsProvider`
starts a new, empty scope instead.

### Screen dependencies

Wrap a screen in a `DepsProvider` to create its dependencies when the screen
is pushed and dispose them when it's popped:

```dart
Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => DepsProvider(
      register: [ChangeNotifierDependency<Counter>((deps, _) => Counter())],
      child: const CounterScreen(),
    ),
  ),
);
```

Routes, dialogs and bottom sheets are separate subtrees under the `Navigator`,
so they don't see the dependencies of the screen that opened them - only the
ones registered above the `Navigator`, e.g. in `Deps.global`.

### Dependencies shared by several screens

A flow that spans several routes - e.g. a checkout or a multi-step form -
has no single widget around all of its screens. Use `DepsProvider.shared` in
each of them with the same key:

```dart
class CheckoutDepsProvider extends StatelessWidget {
  const CheckoutDepsProvider({super.key, required this.checkoutId, required this.child});

  final String checkoutId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DepsProvider.shared(
      checkoutId,
      register: [ChangeNotifierDependency<Cart>((deps, _) => Cart())],
      child: child,
    );
  }
}
```

All `DepsProvider.shared` widgets with an equal key under the same nearest
scope share one scope: it's created when the first of them mounts and
disposed when the last of them unmounts, however the user navigates between
them. So every step of the flow sees the same `Cart`, and it's disposed once
the user leaves the flow. Use a new key for each run of the flow, so that
starting it again starts with fresh dependencies.

### Providing an existing `Deps`

`DepsProvider.deps(deps, ...)` provides a `Deps` you created yourself, e.g. a
`Deps.global.fork()` kept outside the widget tree. `register` works as usual,
but the `DepsProvider` never disposes `deps` - that's up to you.

## Grouping dependencies

A `Module` bundles several dependencies so they're registered and removed
together:

```dart
final authModule = Module([
  Dependency<AuthService>((deps, _) => AuthService()),
  Dependency<TokenStorage>((deps, _) => TokenStorage()),
], debugLabel: 'Auth');

DepsProvider(
  register: [authModule],
  child: const AuthScreen(),
);
```

Always give the dependencies in a `Module` an explicit type, e.g.
`Dependency<AuthService>(...)`. Without it they're registered under `Object`.

See [`lean_di`](https://pub.dev/packages/lean_di) for more: computed
dependencies, registering one instance under several types with `Alias`, and
observing internal state changes of your own types with `DependencyObserver`.

## Testing

Provide a separate `Deps` with fakes in each test, instead of sharing
`Deps.global`:

```dart
testWidgets('shows the user name', (tester) async {
  final deps = Deps()
    ..add(Dependency<ApiClient>.value(FakeApiClient()));
  addTearDown(deps.dispose);

  await tester.pumpWidget(
    DepsProvider.deps(
      deps,
      child: const MaterialApp(home: UserScreen()),
    ),
  );

  expect(find.text('John'), findsOneWidget);
});
```

Fakes only replace dependencies that the widgets under test read from above.
A dependency that a `DepsProvider` inside them registers itself shadows the
fake.

## Debugging

Each `DepsProvider` shows its scope and dependencies - and whether each one
has been created yet - in the widget inspector. In DevTools, turn off "Show
only widgets created by user" to see them. For a quick dump from anywhere,
use:

```dart
debugPrint(Deps.global.toDiagnosticsNode().toStringDeep());
```

In debug builds this includes every descendant scope. That tracking is off in
profile and release builds - enable it with
`--dart-define=lean_di.diagnosticsMode=true`.

## Errors

| Error                          | Thrown by                                                | When                                                                 |
| ------------------------------ | -------------------------------------------------------- | -------------------------------------------------------------------- |
| `DepsProviderNotFoundError`    | `context.get`/`watch`/`watchInstance`/`select`, `DepsProvider.of` | There's no `DepsProvider` above the widget.                  |
| `DependencyNotRegisteredError` | `context.get`/`watch`/`watchInstance`/`select`           | Nothing is registered under that type in the scope or its ancestors. |
| `DepsDisposedError`            | `context.get`, ...                                       | The scope has already been disposed.                                 |
| `DependencyCycleError`         | `context.get`, ... (on creation)                         | `create` re-enters resolving its own type before finishing.          |

`DepsProviderNotFoundError` usually means one of:

1. The dependency is registered in another route - including dialogs and
   bottom sheets. See [Screen dependencies](#screen-dependencies).
2. A `Deps.global` dependency is read without `DepsProvider.global` at the
   root of the app.
3. A `DepsProvider`'s own dependency is read from the context above it. See
   [`child` vs `builder`](#child-vs-builder).

The `maybe...` variants - `maybeWatch`, `maybeWatchInstance`, `maybeSelect`,
`DepsProvider.maybeOf` - return `null` instead of throwing when the dependency
or the `DepsProvider` is missing.

An error thrown by the `create` of an eager (`lazy: false`) dependency isn't
thrown from the `DepsProvider` - it's reported to the current zone's error
handler, the other dependencies are still created, and the failed one is
created again the next time it's read.

## See also

- [`lean_di`](https://pub.dev/packages/lean_di) - the underlying container,
  usable in plain Dart: `Deps`, scopes, computed dependencies, aliases and
  observers in more detail.
- [`flutter_lean_di_bloc`](https://pub.dev/packages/flutter_lean_di_bloc) -
  `bloc`/`cubit` integration: `BlocDependency`, and `BlocBuilder`,
  `BlocListener` and `BlocConsumer` that resolve their bloc from `Deps`.

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

[banner-img]: https://raw.githubusercontent.com/leancodepl/lean_di/refs/heads/main/packages/flutter_lean_di/doc/banner.png
[leancode-landing]: https://leancode.co/?utm_source=github.com&utm_medium=referral&utm_campaign=flutter_lean_di
[leancode-estimate]: https://leancode.co/get-estimate?utm_source=github.com&utm_medium=referral&utm_campaign=flutter_lean_di
[leancode-packages]: https://pub.dev/packages?q=publisher%3Aleancode.co&sort=downloads
[patrol-landing]: https://patrol.leancode.co/?utm_source=github.com&utm_medium=referral&utm_campaign=flutter_lean_di