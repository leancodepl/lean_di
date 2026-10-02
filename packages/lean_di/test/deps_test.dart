import 'dart:async';

import 'package:lean_di/lean_di.dart';
import 'package:test/test.dart';

void main() {
  late Deps deps;

  setUp(() => deps = Deps());

  tearDown(() => deps.dispose());

  test('instant', () {
    deps
      ..add(Dependency<Bar>((deps, _) => Bar()))
      ..add(Dependency<Foo>((deps, _) => Foo(bar: deps.get())));

    expect(() => deps.get<Foo>(), returnsNormally);
  });

  test('create mutates the old value in place when a tracked key changes',
      () async {
    final scopeDeps = Deps()
      ..add(Dependency((deps, _) => Baz(label: 'first')))
      ..add(
        Dependency<Qux>((deps, oldValue) {
          final baz = deps.watchInstance<Baz>();
          return oldValue == null ? Qux(baz: baz) : (oldValue..baz = baz);
        }),
      )
      // Force resolution now, so the assertion below genuinely exercises
      // create() reacting to a later change - not just its first run
      // picking up an already-replaced Baz on first (lazy) resolution.
      ..get<Qux>();

    await Future<void>.delayed(Duration.zero);

    scopeDeps.replace(Dependency.value(Baz(label: 'second')));
    await Future<void>.delayed(Duration.zero);

    expect(scopeDeps.get<Qux>().label, equals('second'));
  });

  test('create returns a fresh value when a tracked key changes', () async {
    final scopeDeps = Deps()
      ..add(Dependency((deps, _) => Baz(label: 'first')))
      ..add(Dependency<Qux>((deps, _) => Qux(baz: deps.watchInstance())))
      ..get<Qux>();

    await Future<void>.delayed(Duration.zero);

    scopeDeps.replace(Dependency.value(Baz(label: 'second')));
    await Future<void>.delayed(Duration.zero);

    expect(scopeDeps.get<Qux>().label, equals('second'));
  });

  test('create re-runs synchronously, exactly once, when a tracked key changes',
      () {
    var createCalls = 0;
    final scopeDeps = Deps()
      ..add(Dependency((deps, _) => Baz(label: 'first')))
      ..add(
        Dependency<Qux>((deps, _) {
          createCalls++;
          return Qux(baz: deps.watchInstance());
        }),
      )
      ..get<Qux>();
    expect(createCalls, equals(1));

    // A lazy replacement fires both DependencyRegistered and, once Qux
    // resolves it, DependencyChanged - only the first is an actual change.
    scopeDeps.replace(Dependency((deps, _) => Baz(label: 'second')));

    expect(scopeDeps.get<Qux>().label, equals('second'));
    expect(createCalls, equals(2));
  });

  test(
      'a chain of computed dependencies across scopes settles synchronously '
      'when a dependency is replaced in the parent', () {
    final createCalls = <String>[];
    final root = Deps()..add(Dependency((deps, _) => Baz(label: 'first')));
    final child = root.fork()
      ..add(
        Dependency<Qux>((deps, _) {
          createCalls.add('Qux');
          return Qux(baz: deps.watchInstance());
        }),
      )
      ..add(
        Dependency<Corge>((deps, _) {
          createCalls.add('Corge');
          final qux = deps.watchInstance<Qux>();
          final baz = deps.watchInstance<Baz>();
          return Corge('${qux.label}/${baz.label}');
        }),
      );
    expect(child.get<Corge>().label, equals('first/first'));

    root.replace(Dependency((deps, _) => Baz(label: 'second')));

    expect(child.get<Corge>().label, equals('second/second'));
    expect(createCalls, equals(['Corge', 'Qux', 'Qux', 'Corge']));
  });

  test(
      'create never re-runs when it only reads through get(), not '
      'watchInstance()', () async {
    var createCalls = 0;
    final scopeDeps = Deps()
      ..add(Dependency((deps, _) => Baz(label: 'first')))
      ..add(
        Dependency<Qux>((deps, oldValue) {
          createCalls++;
          final baz = deps.get<Baz>();
          return oldValue == null ? Qux(baz: baz) : (oldValue..baz = baz);
        }),
      )
      ..get<Qux>();

    await Future<void>.delayed(Duration.zero);
    expect(createCalls, equals(1)); // the initial run only

    scopeDeps.replace(Dependency.value(Baz(label: 'second')));
    await Future<void>.delayed(Duration.zero);

    expect(createCalls, equals(1));
    expect(scopeDeps.get<Qux>().label, equals('first'));
  });

  test(
      'create only reacts to the keys it actually reads this run - '
      'unread keys are ignored even though they change', () async {
    final scopeDeps = Deps()
      ..add(Dependency((_, __) => Corge('corge-1')))
      ..add(Dependency((_, __) => Grault('grault-1')))
      ..add(
        Dependency<Waldo>(
          // Only ever reads Corge - Grault is never tracked.
          (deps, _) => Waldo(label: deps.watchInstance<Corge>().label),
        ),
      );

    await Future<void>.delayed(Duration.zero);
    expect(scopeDeps.get<Waldo>().label, equals('corge-1'));

    // Not tracked - should be silently ignored.
    scopeDeps.replace(Dependency.value(Grault('grault-2')));
    await Future<void>.delayed(Duration.zero);
    expect(scopeDeps.get<Waldo>().label, equals('corge-1'));

    // Tracked - should propagate.
    scopeDeps.replace(Dependency.value(Corge('corge-2')));
    await Future<void>.delayed(Duration.zero);
    expect(scopeDeps.get<Waldo>().label, equals('corge-2'));
  });

  test(
      'create adjusts its subscription when the keys it reads change '
      'between runs', () async {
    // An external toggle, flipped mid-test, standing in for create's logic
    // taking a different branch (e.g. based on oldValue) on a later run.
    var useCorge = true;

    final scopeDeps = Deps()
      ..add(Dependency((_, __) => Corge('corge-1')))
      ..add(Dependency((_, __) => Grault('grault-1')))
      ..add(
        Dependency<Waldo>(
          (deps, _) => Waldo(
            label: useCorge
                ? deps.watchInstance<Corge>().label
                : deps.watchInstance<Grault>().label,
          ),
        ),
      );

    await Future<void>.delayed(Duration.zero);
    expect(scopeDeps.get<Waldo>().label, equals('corge-1'));

    // Flip the branch, then force a re-run via the key still tracked from
    // the last run (Corge) - this run should read Grault instead, and
    // re-subscribe to track Grault, not Corge, from now on.
    useCorge = false;
    scopeDeps.replace(Dependency.value(Corge('corge-2')));
    await Future<void>.delayed(Duration.zero);
    expect(scopeDeps.get<Waldo>().label, equals('grault-1'));

    // No longer tracked - should be silently ignored.
    scopeDeps.replace(Dependency.value(Corge('corge-3')));
    await Future<void>.delayed(Duration.zero);
    expect(scopeDeps.get<Waldo>().label, equals('grault-1'));

    // Tracked now instead.
    scopeDeps.replace(Dependency.value(Grault('grault-2')));
    await Future<void>.delayed(Duration.zero);
    expect(scopeDeps.get<Waldo>().label, equals('grault-2'));
  });

  test('createObserver is only called once something actually watches',
      () async {
    var createObserverCalls = 0;
    var disposeCalls = 0;

    final scopeDeps = Deps()
      ..add(
        Dependency<Bar>(
          (_, __) => Bar(),
          createObserver: (value) {
            createObserverCalls++;
            return _TrackingObserver(onDispose: () => disposeCalls++);
          },
        ),
      );

    // Plain reads - a pure "service locator" usage - shouldn't set up any
    // observation machinery at all.
    expect(scopeDeps.get<Bar>(), isA<Bar>());
    expect(scopeDeps.get<Bar>(), isA<Bar>());
    expect(createObserverCalls, equals(0));

    // Only watch() should trigger it, and only once.
    final sub = scopeDeps.watch<Bar>().listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(createObserverCalls, equals(1));

    await sub.cancel();
    await scopeDeps.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(disposeCalls, equals(1));
  });

  test(
      'watch() shares one observer across multiple '
      'subscribers to the same key', () async {
    var createObserverCalls = 0;

    final scopeDeps = Deps()
      ..add(
        Dependency<Bar>(
          (_, __) => Bar(),
          createObserver: (value) {
            createObserverCalls++;
            return _TrackingObserver(onDispose: () {});
          },
        ),
      );

    final sub1 = scopeDeps.watch<Bar>().listen((_) {});
    final sub2 = scopeDeps.watch<Bar>().listen((_) {});
    await Future<void>.delayed(Duration.zero);

    expect(createObserverCalls, equals(1));

    await sub1.cancel();
    await sub2.cancel();
    await scopeDeps.dispose();
  });

  test(
      'watchInstance() never triggers observer creation, even '
      'with multiple subscribers', () async {
    var createObserverCalls = 0;

    final scopeDeps = Deps()
      ..add(
        Dependency<Bar>(
          (_, __) => Bar(),
          createObserver: (value) {
            createObserverCalls++;
            return _TrackingObserver(onDispose: () {});
          },
        ),
      );

    final sub1 = scopeDeps.watchInstance<Bar>().listen((_) {});
    final sub2 = scopeDeps.watchInstance<Bar>().listen((_) {});
    await Future<void>.delayed(Duration.zero);

    expect(createObserverCalls, equals(0));

    await sub1.cancel();
    await sub2.cancel();
    await scopeDeps.dispose();
  });

  test(
      'watch() switches to a newly re-registered '
      'instance and stops reacting to the old one', () async {
    Dependency<Counter> makeCounter(int value) => Dependency<Counter>(
          (_, __) => Counter(value),
          createObserver: _CounterObserver.new,
        );

    final scopeDeps = Deps()..add(makeCounter(1));

    final values = <int>[];
    final sub = scopeDeps.watch<Counter>().listen((c) => values.add(c.value));
    await Future<void>.delayed(Duration.zero);

    final firstCounter = scopeDeps.get<Counter>()..set(2);
    await Future<void>.delayed(Duration.zero);

    scopeDeps.replace(makeCounter(100));
    await Future<void>.delayed(Duration.zero);

    // Mutating the now-replaced instance shouldn't reach the subscriber.
    firstCounter.set(999);
    await Future<void>.delayed(Duration.zero);

    scopeDeps.get<Counter>().set(200);
    await Future<void>.delayed(Duration.zero);

    expect(values, equals([1, 2, 100, 200]));

    await sub.cancel();
    await scopeDeps.dispose();
  });

  test(
      'DependencyObserver.dispose is called exactly once on replacement and '
      'once on removal', () async {
    final disposedLabels = <String>[];
    Dependency<Counter> makeCounter(String label, int value) =>
        Dependency<Counter>(
          (_, __) => Counter(value),
          createObserver: (c) =>
              _CounterObserver(c, onDispose: () => disposedLabels.add(label)),
        );

    final scopeDeps = Deps()..add(makeCounter('first', 1));

    final sub = scopeDeps.watch<Counter>().listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(disposedLabels, isEmpty);

    scopeDeps.replace(makeCounter('second', 2));
    await Future<void>.delayed(Duration.zero);
    expect(disposedLabels, equals(['first']));

    await sub.cancel();
    await scopeDeps.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(disposedLabels, equals(['first', 'second']));
  });

  test('get() throws after Deps.dispose()', () async {
    final scopeDeps = Deps()..add(Dependency<Bar>((_, __) => Bar()));
    expect(scopeDeps.get<Bar>(), isA<Bar>());

    await scopeDeps.dispose();

    expect(
      () => scopeDeps.get<Bar>(),
      throwsA(isA<DepsDisposedError>()),
    );
  });

  test('add() throws after Deps.dispose(), but remove() is a no-op', () async {
    final scopeDeps = Deps()..add(Dependency<Bar>((_, __) => Bar()));
    await scopeDeps.dispose();

    expect(
      () => scopeDeps.add(Dependency<Foo>((_, __) => Foo(bar: Bar()))),
      throwsA(isA<DepsDisposedError>()),
    );
    expect(() => scopeDeps.remove<Bar>(), returnsNormally);
  });

  test(
      'get() throws DependencyNotRegisteredException for an unknown key, '
      'but tryGet() returns null', () {
    final scopeDeps = Deps();

    expect(
      () => scopeDeps.get<Bar>(),
      throwsA(isA<DependencyNotRegisteredError>()),
    );
    expect(scopeDeps.tryGet<Bar>(), isNull);
  });

  test('peek() returns the current value without triggering creation', () {
    var created = false;
    final scopeDeps = Deps()
      ..add(Dependency<Bar>((_, __) {
        created = true;
        return Bar();
      }));

    expect(scopeDeps.peek<Bar>(), isNull);
    expect(created, isFalse);

    final value = scopeDeps.get<Bar>();
    expect(created, isTrue);
    expect(scopeDeps.peek<Bar>(), same(value));
  });

  test(
      'debugLabel shows up in toString(), falling back to root/identity '
      'when unset', () {
    final labeled = Deps(debugLabel: 'AuthScope');
    expect(labeled.toString(), equals("Deps('AuthScope')"));

    final forkedLabel = labeled.fork(debugLabel: 'ChildScope');
    expect(forkedLabel.toString(), equals("Deps('ChildScope')"));

    final unlabeled = Deps();
    expect(unlabeled.toString(), isNot(contains('null')));
    expect(Deps.global.toString(), equals("Deps('global')"));
  });

  test('isDisposed reflects dispose()', () async {
    final scopeDeps = Deps();
    expect(scopeDeps.isDisposed, isFalse);
    await scopeDeps.dispose();
    expect(scopeDeps.isDisposed, isTrue);
  });

  test(
      'debugOwnDependencies reports registration and resolution state, '
      'regardless of leanDiDiagnosticsMode', () {
    final scopeDeps = Deps()..add(Dependency<Bar>((_, __) => Bar()));

    final beforeResolve = scopeDeps.debugOwnDependencies.single;
    expect(beforeResolve.key, equals(Bar));
    expect(beforeResolve.isResolved, isFalse);
    expect(beforeResolve.value, isNull);

    final value = scopeDeps.get<Bar>();

    final afterResolve = scopeDeps.debugOwnDependencies.single;
    expect(afterResolve.isResolved, isTrue);
    expect(afterResolve.value, same(value));
  });

  test(
      'debugChildren tracks live fork()ed scopes, only when '
      'leanDiDiagnosticsMode is enabled', () {
    final root = Deps();
    expect(root.debugChildren, isEmpty);

    final child = root.fork();
    expect(
      root.debugChildren,
      leanDiDiagnosticsMode ? contains(child) : isEmpty,
    );
  });

  test('debugChildren drops a scope once it is disposed', () async {
    final root = Deps();
    final child = root.fork();
    await child.dispose();
    expect(root.debugChildren, isNot(contains(child)));
  });

  group('lazy', () {
    test('dependencies are lazy by default', () {
      var createCalls = 0;
      final scopeDeps = Deps()
        ..add(
          Dependency((deps, _) {
            createCalls++;
            return Bar();
          }),
        );

      expect(createCalls, equals(0));
      expect(scopeDeps.peek<Bar>(), isNull);

      scopeDeps.get<Bar>();
      expect(createCalls, equals(1));
    });

    test('lazy: false creates the dependency on registration', () {
      var createCalls = 0;
      final scopeDeps = Deps()
        ..add(
          Dependency(
            (deps, _) {
              createCalls++;
              return Bar();
            },
            lazy: false,
          ),
        );

      expect(createCalls, equals(1));
      expect(scopeDeps.get<Bar>(), same(scopeDeps.peek<Bar>()));
      expect(createCalls, equals(1));
    });

    test('Dependency.value is never lazy', () {
      final bar = Bar();
      final scopeDeps = Deps()..add(Dependency.value(bar));

      expect(scopeDeps.peek<Bar>(), same(bar));
    });

    test(
        'an eager dependency can read dependencies registered after it in the '
        'same call', () {
      final module = Module([
        Dependency<Foo>((deps, _) => Foo(bar: deps.get()), lazy: false),
        Dependency<Bar>((deps, _) => Bar()),
      ]);
      final moduleDeps = Deps()..add(module);
      final addAllDeps = Deps()
        ..addAll([
          Dependency((deps, _) => Foo(bar: deps.get()), lazy: false),
          Dependency((deps, _) => Bar()),
        ]);

      expect(moduleDeps.peek<Foo>()?.bar, same(moduleDeps.peek<Bar>()));
      expect(addAllDeps.peek<Foo>()?.bar, same(addAllDeps.peek<Bar>()));
    });

    test('an eager dependency is created after it is registered', () {
      final events = <DepsEvent>[];
      final scopeDeps = Deps();
      addTearDown(scopeDeps.addEventListener(events.add));

      scopeDeps.add(Dependency((deps, _) => Bar(), lazy: false));

      expect(
        events,
        equals([
          const DependencyRegistered(key: Bar),
          const DependencyChanged(key: Bar),
        ]),
      );
    });

    test(
        'an eager dependency replaced before its turn is not created - '
        'its replacement is left lazy', () {
      final scopeDeps = Deps();
      scopeDeps.addAll([
        Dependency<Baz>(
          (deps, _) {
            scopeDeps.replace(Dependency<Bar>((deps, _) => Bar()));
            return Baz(label: 'baz');
          },
          lazy: false,
        ),
        Dependency<Bar>(
          (deps, _) => fail('the replaced dependency must not be created'),
          lazy: false,
        ),
      ]);

      expect(scopeDeps.peek<Baz>(), isNotNull);
      expect(scopeDeps.isRegistered<Bar>(), isTrue);
      expect(scopeDeps.peek<Bar>(), isNull);
    });

    test(
        "add() keeping an unchanged entry applies the new dependency's lazy "
        'flag', () {
      var createCalls = 0;
      Bar create(DepsReader deps, Bar? _) {
        createCalls++;
        return Bar();
      }

      final scopeDeps = Deps()..add(Dependency<Bar>(create));
      expect(createCalls, equals(0));

      // Same key and cacheKey, so the entry above is kept, but eager now.
      scopeDeps.add(Dependency<Bar>(create, lazy: false));

      expect(createCalls, equals(1));
      expect(scopeDeps.peek<Bar>(), isNotNull);
    });

    test(
        'an error from an eager create() is reported to the zone, and the '
        'other dependencies are still registered and created', () {
      final errors = <Object>[];
      late final Deps scopeDeps;
      late final Unregister unregister;

      runZonedGuarded(
        () {
          scopeDeps = Deps();
          unregister = scopeDeps.addAll([
            // Bar isn't registered yet.
            Dependency<Foo>((deps, _) => Foo(bar: deps.get()), lazy: false),
            Dependency<Baz>((deps, _) => Baz(label: 'baz'), lazy: false),
          ]);
        },
        (error, _) => errors.add(error),
      );

      expect(errors, [isA<DependencyNotRegisteredError>()]);
      expect(unregister, isNotNull);
      expect(scopeDeps.isRegistered<Foo>(), isTrue);
      expect(scopeDeps.peek<Foo>(), isNull);
      expect(scopeDeps.peek<Baz>(), isNotNull);

      unregister();
      expect(scopeDeps.isRegistered<Foo>(), isFalse);
      expect(scopeDeps.isRegistered<Baz>(), isFalse);
    });
  });

  test(
      'add() keeping an unchanged entry keeps its value, but uses the new '
      "dependency's dispose", () async {
    final disposed = <String>[];
    final scopeDeps = Deps()
      ..add(
        Dependency<Bar>(
          (deps, _) => Bar(),
          dispose: (_) => disposed.add('first'),
        ),
      );
    final bar = scopeDeps.get<Bar>();

    scopeDeps.add(
      Dependency<Bar>(
        (deps, _) => Bar(),
        dispose: (_) => disposed.add('second'),
      ),
    );

    expect(scopeDeps.get<Bar>(), same(bar));

    await scopeDeps.dispose();
    expect(disposed, equals(['second']));
  });

  test('dispose() waits for async dependency disposal', () async {
    var disposed = false;
    final scopeDeps = Deps()
      ..add(
        Dependency<Bar>(
          (deps, _) => Bar(),
          dispose: (_) => scheduleMicrotask(() => disposed = true),
        ),
      )
      ..get<Bar>();

    await scopeDeps.dispose();

    expect(disposed, isTrue);
  });

  test('DependencyCycleException is thrown for a self-referential create()',
      () {
    final scopeDeps = Deps()
      ..add(Dependency<Bar>((deps, _) {
        deps.get<Bar>();
        return Bar();
      }));

    expect(
      () => scopeDeps.get<Bar>(),
      throwsA(isA<DependencyCycleError>()),
    );
  });

  test('a create() that threw is retried on the next get()', () {
    var shouldThrow = true;
    final scopeDeps = Deps()
      ..add(
        Dependency<Bar>((deps, _) {
          if (shouldThrow) {
            throw StateError('not ready');
          }
          return Bar();
        }),
      );

    expect(scopeDeps.get<Bar>, throwsStateError);

    shouldThrow = false;
    expect(scopeDeps.get<Bar>(), isA<Bar>());
  });

  test(
      'add() leaves the existing value in place when cacheKey matches '
      '(including both being null), and replaces when it differs', () {
    final scopeDeps = Deps()..add(Dependency<Bar>((_, __) => Bar()));
    final first = scopeDeps.get<Bar>();

    // No cacheKey on either side - null == null - left alone.
    scopeDeps.add(Dependency<Bar>((_, __) => Bar()));
    expect(scopeDeps.get<Bar>(), same(first));

    // Newly-specified, non-null cacheKey differs from the existing null -
    // replaced.
    scopeDeps.add(Dependency<Bar>((_, __) => Bar(), cacheKey: 'v1'));
    final second = scopeDeps.get<Bar>();
    expect(second, isNot(same(first)));

    // Same cacheKey as what's already there - left alone.
    scopeDeps.add(Dependency<Bar>((_, __) => Bar(), cacheKey: 'v1'));
    expect(scopeDeps.get<Bar>(), same(second));

    // Different cacheKey - replaced.
    scopeDeps.add(Dependency<Bar>((_, __) => Bar(), cacheKey: 'v2'));
    expect(scopeDeps.get<Bar>(), isNot(same(second)));
  });

  test('replace() always replaces, even when cacheKey matches', () {
    final scopeDeps = Deps()
      ..add(Dependency<Bar>((_, __) => Bar(), cacheKey: 'v1'));
    final first = scopeDeps.get<Bar>();

    scopeDeps.replace(Dependency<Bar>((_, __) => Bar(), cacheKey: 'v1'));

    expect(scopeDeps.get<Bar>(), isNot(same(first)));
  });

  test('remove() accepts a Module and removes every dependency it groups', () {
    final module = Module([
      Dependency<Bar>((_, __) => Bar()),
      Dependency<Foo>((deps, _) => Foo(bar: deps.get())),
    ]);
    final scopeDeps = Deps()..add(module);

    expect(scopeDeps.isRegistered<Bar>(), isTrue);
    expect(scopeDeps.isRegistered<Foo>(), isTrue);

    scopeDeps.remove(module);

    expect(scopeDeps.isRegistered<Bar>(), isFalse);
    expect(scopeDeps.isRegistered<Foo>(), isFalse);
  });

  test(
      'remove() accepts a Registerable describing the same dependency '
      'types, without needing the exact original instance', () {
    Module makeModule() => Module([
          Dependency<Bar>((_, __) => Bar()),
          Dependency<Foo>((deps, _) => Foo(bar: deps.get())),
        ]);
    final scopeDeps = Deps()
      ..add(makeModule())
      // A fresh Module instance describing the same dependency types
      // removes the same keys - lookup is by type, not Module identity.
      ..remove(makeModule());

    expect(scopeDeps.isRegistered<Bar>(), isFalse);
    expect(scopeDeps.isRegistered<Foo>(), isFalse);
  });

  test('remove() accepts a plain Dependency, equivalent to removing its key',
      () {
    final dependency = Dependency<Bar>((_, __) => Bar());
    final scopeDeps = Deps()
      ..add(dependency)
      ..remove(dependency);

    expect(scopeDeps.isRegistered<Bar>(), isFalse);
  });

  test(
      'remove() throws ArgumentError for a value that is neither a Type '
      'nor a Registerable', () {
    final scopeDeps = Deps()..add(Dependency<Bar>((_, __) => Bar()));

    expect(
      () => scopeDeps.remove(42),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('debugOwnDependencies reports isStandalone and module correctly', () {
    final module = Module([Dependency<Bar>((_, __) => Bar())], debugLabel: 'M');
    final scopeDeps = Deps()
      ..add(module)
      ..add(Dependency<Foo>((deps, _) => Foo(bar: deps.get())));

    final byKey = {
      for (final entry in scopeDeps.debugOwnDependencies) entry.key: entry,
    };

    final grouped = byKey[Bar]!;
    expect(grouped.isStandalone, isFalse);
    expect(grouped.module, same(module));

    final standalone = byKey[Foo]!;
    expect(standalone.isStandalone, isTrue);
    expect(standalone.module, isNull);
  });
}

class _TrackingObserver extends DependencyObserver<Bar> {
  _TrackingObserver({required this.onDispose});

  final void Function() onDispose;

  @override
  Future<void> dispose() async => onDispose();
}

/// A minimal mutable, observable value - the pure-Dart stand-in for a
/// ChangeNotifier, used to test [DependencyObserver.notifyStateChanged]
/// without depending on Flutter.
class Counter {
  Counter(this.value);

  int value;
  final List<void Function()> _listeners = [];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void set(int newValue) {
    value = newValue;
    for (final listener in [..._listeners]) {
      listener();
    }
  }
}

class _CounterObserver extends DependencyObserver<Counter> {
  _CounterObserver(this.counter, {this.onDispose}) {
    counter.addListener(_onChange);
  }

  final Counter counter;
  final void Function()? onDispose;

  void _onChange() => notifyStateChanged();

  @override
  Future<void> dispose() async {
    counter.removeListener(_onChange);
    onDispose?.call();
  }
}

class Bar {}

class Foo {
  Foo({required this.bar});

  final Bar bar;
}

class Baz {
  Baz({required this.label});

  final String label;
}

class Qux {
  Qux({required this.baz});

  Baz baz;

  String get label => baz.label;
}

class Corge {
  Corge(this.label);

  final String label;
}

class Grault {
  Grault(this.label);

  final String label;
}

class Waldo {
  Waldo({required this.label});

  final String label;
}
