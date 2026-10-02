<div align="center">

[![Banner][banner-img]][leancode-landing]

</div>

# Lean DI for Bloc

`Bloc` and `Cubit` integration for Lean DI, with state observable through
`context.watch` and `context.select`.

Register your `Bloc`s and `Cubit`s as Lean DI dependencies, and build your UI
with `BlocBuilder`, `BlocSelector`, `BlocListener` and `BlocConsumer` - the
same widgets you know from `flutter_bloc`, resolving their bloc from the
nearest `DepsProvider`. For registering and scoping dependencies in general,
see [`flutter_lean_di`](https://pub.dev/packages/flutter_lean_di).

## Installation

```sh
flutter pub add flutter_lean_di_bloc bloc
```

## Quick start

```dart
import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lean_di_bloc/flutter_lean_di_bloc.dart';

void main() => runApp(const MaterialApp(home: CounterPage()));

class CounterCubit extends Cubit<int> {
  CounterCubit() : super(0);

  void increment() => emit(state + 1);
}

class CounterPage extends StatelessWidget {
  const CounterPage({super.key});

  @override
  Widget build(BuildContext context) {
    // CounterCubit is created on first use and closed together with this
    // DepsProvider.
    return DepsProvider(
      register: [BlocDependency<CounterCubit>((deps, _) => CounterCubit())],
      builder: (context, _) => Scaffold(
        body: Center(
          // Rebuilds with every new state.
          child: BlocBuilder<CounterCubit, int>(
            builder: (context, count) => Text('$count'),
          ),
        ),
        floatingActionButton: FloatingActionButton(
          // Reads CounterCubit without listening to it.
          onPressed: () => context.get<CounterCubit>().increment(),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}
```

## Registering blocs

`BlocDependency` registers a `Bloc` or `Cubit` like any other `Dependency`,
and closes it with `close()` when it's removed - e.g. when its `DepsProvider`
is disposed:

```dart
DepsProvider(
  register: [
    // Lazily created on first use, closed with the DepsProvider.
    BlocDependency<CounterCubit>((deps, _) => CounterCubit()),

    // Depending on other dependencies, created as soon as it's registered,
    // and created again when userId changes.
    BlocDependency<ProfileBloc>(
      (deps, _) => ProfileBloc(deps.get<UserRepository>(), userId),
      lazy: false,
      cacheKey: userId,
    ),

    // With custom cleanup instead of the default close().
    BlocDependency<SessionCubit>(
      (deps, _) => SessionCubit(),
      dispose: (cubit) async {
        await cubit.logOut();
        await cubit.close();
      },
    ),
  ],
  child: const ProfileScreen(),
);
```

A bloc registered this way also works with `flutter_lean_di`'s own `context`
lookups - `context.watch` and `context.select` react to every state it emits:

```dart
final count = context.watch<CounterCubit>().state;
final isEven = context.select<CounterCubit, bool>((cubit) => cubit.state.isEven);
```

## Widgets

| Widget                                  | Use it to                                                        |
| --------------------------------------- | ---------------------------------------------------------------- |
| `BlocBuilder<TBloc, TState>`            | Build from the bloc's state, optionally filtered with `buildWhen`. |
| `BlocSelector<TBloc, TState, TSelected>` | Build from a part of the state, rebuilding only when it changes. |
| `BlocListener<TBloc, TState>`           | Run side effects on new states, optionally filtered with `listenWhen`. |
| `BlocConsumer<TBloc, TState>`           | Do both for the same state changes.                              |

Each of them resolves `TBloc` from the nearest `DepsProvider`, and follows a
new instance when one is registered under `TBloc` - e.g. after `replace()`, or
a changed `cacheKey`. Pass `bloc` to use a specific instance instead:

```dart
BlocBuilder<CounterCubit, int>(
  bloc: myCounterCubit,
  builder: (context, count) => Text('$count'),
);
```

### `BlocBuilder`

Rebuilds with every new state, or only with the ones `buildWhen` accepts:

```dart
BlocBuilder<CounterCubit, int>(
  buildWhen: (previous, current) => current.isEven,
  builder: (context, count) => Text('$count'),
);
```

### `BlocSelector`

Rebuilds only when the value returned by `selector` changes (compared with
`==`). Prefer it over `BlocBuilder` with a hand-written `buildWhen` when only
part of the state matters:

```dart
BlocSelector<ProfileBloc, ProfileState, String>(
  selector: (state) => state.name,
  builder: (context, name) => Text(name),
);
```

### `BlocListener`

Calls `listener` for new states - optionally filtered with `listenWhen` -
without rebuilding anything. Use it for one-off side effects, like navigation
or showing a dialog:

```dart
BlocListener<CounterCubit, int>(
  listenWhen: (previous, current) => current == 10,
  listener: (context, count) => showDialog<void>(
    context: context,
    builder: (_) => const AlertDialog(title: Text('You reached 10!')),
  ),
  child: const CounterView(),
);
```

### `BlocConsumer`

Combines `BlocBuilder` and `BlocListener`, for when the same state changes
need both a rebuild and a side effect:

```dart
BlocConsumer<CounterCubit, int>(
  listenWhen: (previous, current) => current == 10,
  listener: (context, count) => ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Reached 10!')),
  ),
  builder: (context, count) => Text('$count'),
);
```

## Coming from `flutter_bloc`

| `flutter_bloc`                            | `flutter_lean_di_bloc`                                             |
| ----------------------------------------- | ------------------------------------------------------------------ |
| `BlocProvider(create: ...)`               | `DepsProvider(register: [BlocDependency(...)])`                    |
| `MultiBlocProvider`                       | One `DepsProvider` with several dependencies in `register`         |
| `BlocProvider.value`                      | `Dependency.value(bloc, createObserver: BlocDependencyObserver.new)` |
| `context.read<T>()`                       | `context.get<T>()`                                                 |
| `context.watch<T>()`, `context.select`    | Same                                                               |
| `BlocBuilder`, `BlocSelector`, `BlocListener`, `BlocConsumer` | Same names and parameters                        |

Like `BlocProvider.value`, a `Dependency.value` never closes the bloc - that's
up to whoever created it. `createObserver` makes `context.watch` and
`context.select` react to its states, as they do for a `BlocDependency`.

The widgets have the same names as `flutter_bloc`'s, so don't import both
packages in the same file.

## See also

- [`flutter_lean_di`](https://pub.dev/packages/flutter_lean_di) -
  `DepsProvider`, reading dependencies from `context`, app-wide, per-screen
  and shared dependencies, testing and debugging.
- [`lean_di`](https://pub.dev/packages/lean_di) - the underlying container,
  usable in plain Dart.
- [`bloc`](https://pub.dev/packages/bloc) - `Bloc` and `Cubit` themselves.

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

[banner-img]: https://raw.githubusercontent.com/leancodepl/lean_di/refs/heads/main/packages/flutter_lean_di_bloc/doc/banner.png
[leancode-landing]: https://leancode.co/?utm_source=github.com&utm_medium=referral&utm_campaign=flutter_lean_di_bloc
[leancode-estimate]: https://leancode.co/get-estimate?utm_source=github.com&utm_medium=referral&utm_campaign=flutter_lean_di_bloc
[leancode-packages]: https://pub.dev/packages?q=publisher%3Aleancode.co&sort=downloads
[patrol-landing]: https://patrol.leancode.co/?utm_source=github.com&utm_medium=referral&utm_campaign=flutter_lean_di_bloc