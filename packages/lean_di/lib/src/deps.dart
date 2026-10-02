import 'dart:async';

import 'package:lean_di/src/event_notifier.dart';
import 'package:lean_di/src/is_debug_mode.dart';
import 'package:rxdart/rxdart.dart';

import 'dependency.dart';
import 'deps_events.dart';
import 'errors.dart';
import 'managed_dependency.dart';
import 'types.dart';

/// Enables tracking of a [Deps] scope's child scopes (created via
/// [Deps.fork]) purely for inspection - see [Deps.debugChildren], and
/// flutter_lean_di's diagnostics extensions for viewing a whole hierarchy.
///
/// This has a real, if small, cost: while enabled, every [Deps] holds a
/// strong reference to each of its live child scopes for as long as they
/// exist, purely so they can be found again for inspection - not something
/// worth paying for by default outside of debugging. It's on by default in
/// debug builds and off in profile/release builds, but it's a compile-time
/// `const`, so:
///  - force it on in profile/release with
///    `--dart-define=lean_di.diagnosticsMode=true`, e.g. to diagnose a
///    scope leak that doesn't reproduce in debug mode;
///  - force it off in debug with
///    `--dart-define=lean_di.diagnosticsMode=false`;
///  - and because it's `const`, whichever branch ends up unreachable is
///    removed entirely by tree shaking - disabled diagnostics tracking
///    costs nothing in the built app.
const bool leanDiDiagnosticsMode = bool.fromEnvironment(
  'lean_di.diagnosticsMode',
  defaultValue: kIsDebugBuild,
);

/// A box that contains dependencies. Deps can also form a tree-like hierarchy
/// to allow for scoping and overriding dependencies. Reading values from
/// a deps object that it doesn't contain but its ancestors will return
/// the value from the nearest ancestor.
class Deps extends EventNotifier<DepsEvent> {
  /// Creates empty [Deps]
  Deps({String? debugLabel}) : this._(parent: null, debugLabel: debugLabel);

  Deps._({
    required this.parent,
    this.debugLabel,
  }) {
    _setupParentSubscription();
    if (leanDiDiagnosticsMode) {
      parent?._children.add(this);
    }
  }

  /// The global [Deps] instance
  static final global = Deps(debugLabel: 'global');

  /// A label to help identify this scope in logs, error messages, and
  /// diagnostics - e.g. flutter_lean_di's diagnostics extensions, which
  /// prefer it over this scope's identity hash when set. Purely cosmetic;
  /// has no effect on lookup, scoping, or anything else.
  final String? debugLabel;

  void _setupParentSubscription() {
    _removeParentListener = parent?.addEventListener((event) {
      if (_isNotShadowedEvent(event)) {
        notify(event);
      }
    });
  }

  bool _isNotShadowedEvent(DepsEvent e) {
    // Events are shadowed when this scope already has the specified key.
    return switch (e) {
      DependencyRegistered(:final key) => !_isRegisteredHere<Object>(key),
      DependencyUnregistered(:final key) => !_isRegisteredHere<Object>(key),
      DependencyChanged(:final key) => !_isRegisteredHere<Object>(key),
    };
  }

  /// Creates a child scope of this [Deps].
  Deps fork({String? debugLabel}) =>
      Deps._(parent: this, debugLabel: debugLabel);

  /// The scope this one was [fork]ed from, or `null` for [Deps.global] or a
  /// scope created via [Deps()].
  final Deps? parent;

  /// Whether this scope has no [parent]
  bool get isRoot => parent == null;
  RemoveListener? _removeParentListener;
  bool _isDisposed = false;

  @override
  String toString() {
    if (debugLabel case final label?) {
      return "Deps('$label')";
    }
    return isRoot ? 'Deps(root)' : 'Deps(#${identityHashCode(this)})';
  }

  /// Whether [dispose] has already been called on this scope.
  bool get isDisposed => _isDisposed;

  final Map<Object, ManagedDependency> _values = {};

  /// Live child scopes created via [fork] - only tracked when
  /// [leanDiDiagnosticsMode] is enabled, so this is otherwise always
  /// empty. See [debugChildren].
  final Set<Deps> _children = {};

  /// Snapshot of this scope's direct child scopes created via [fork] that
  /// are still alive - for inspection/diagnostics only, e.g.
  /// flutter_lean_di's diagnostics extensions. Requires
  /// [leanDiDiagnosticsMode] to be enabled; otherwise always empty. See
  /// also [scopeChain] to walk upward (ancestors) instead.
  Iterable<Deps> get debugChildren => List.unmodifiable(_children);

  /// Snapshot of the dependencies registered directly in this scope (not
  /// its ancestors - see [ownEntries]/[getAllEntries]), together with
  /// their current resolution state and whether each was registered
  /// standalone or as part of a group like a [Module] - for
  /// inspection/diagnostics only. Always available regardless of
  /// [leanDiDiagnosticsMode], since it only reflects state this scope
  /// already keeps.
  Iterable<DependencyDiagnostics> get debugOwnDependencies =>
      _values.values.map(
        (managed) => DependencyDiagnostics(
          dependency: managed.dependency,
          value: managed.currentValue,
          origin: managed.origin,
        ),
      );

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw DepsDisposedError();
    }
  }

  /// Iterate over the scope ancestor chain, starting from this [Deps]
  /// (inclusive) and ending with the root scope.
  Iterable<Deps> get scopeChain sync* {
    Deps? scope = this;
    while (scope != null) {
      yield scope;
      scope = scope.parent;
    }
  }

  /// Gathers all entries accessible from this deps. Potentially expensive,
  /// depending on how deep the tree is and how many entries there are.
  Iterable<Dependency<Object>> getAllEntries() {
    final map = <Type, Dependency<Object>>{};
    for (final scope in scopeChain.toList().reversed) {
      for (final entry in scope.ownEntries) {
        map[entry.key] = entry;
      }
    }
    return map.values;
  }

  /// The [Dependency] descriptors registered directly in this scope - not
  /// its ancestors. See [getAllEntries] to include inherited ones too.
  Iterable<Dependency<Object>> get ownEntries =>
      _values.values.map((e) => e.dependency);

  /// Every entry accessible from this scope (see [getAllEntries]) whose
  /// [Dependency.tags] contains [tag].
  Iterable<Dependency<Object>> getEntriesWithTag(Object tag) =>
      getAllEntries().where((e) => e.tags?.contains(tag) ?? false);

  /// Add or update a dependency.
  ///
  /// If a dependency is already registered under the same [Dependency.key]
  /// with an equal [Dependency.cacheKey] (`null` counts as equal to
  /// `null`), the existing value is kept rather than disposed and
  /// recreated, and the entry takes on the new dependency - including its
  /// [Dependency.lazy], and the [Dependency.create] and
  /// [Dependency.dispose] used from then on. Use [replace] to force a
  /// replacement unconditionally.
  ///
  /// Dependencies that aren't [Dependency.lazy] are created once all of
  /// [registerable]'s dependencies have been registered.
  Unregister add(Registerable registerable) => addAll([registerable]);

  /// Helper method for adding multiple dependencies at once if you find
  /// calling `deps..add()..add()...` too verbose.
  ///
  /// Dependencies that aren't [Dependency.lazy] are created once all of
  /// [registerables] have been registered.
  Unregister addAll(Iterable<Registerable> registerables) {
    // Read registerables and their dependencies exactly once.
    final entries = [
      for (final registerable in registerables)
        for (final dependency in registerable.dependencies)
          (dependency: dependency, origin: registerable),
    ];

    final unregister = _register(entries);
    _resolveEager(entries.map((entry) => entry.dependency));
    return unregister;
  }

  /// Registers [entries] without creating any of them.
  Unregister _register(
    List<({Dependency<Object> dependency, Registerable origin})> entries,
  ) {
    _checkNotDisposed();
    for (final (:dependency, :origin) in entries) {
      final existing = _values[dependency.key];
      if (existing != null &&
          existing.dependency.cacheKey == dependency.cacheKey) {
        existing.update(dependency, origin);
        continue;
      }

      final managed = dependency.toManaged(this, origin);

      remove(managed.key);
      _values[managed.key] = managed;
      notify(DependencyRegistered(key: managed.key));
    }

    final keys = [for (final entry in entries) entry.dependency.key];
    return () {
      keys.forEach(remove);
    };
  }

  /// Creates the [dependencies] that aren't [Dependency.lazy] - only if
  /// they're still what's registered under their key, i.e. skipping ones
  /// removed or replaced in the meantime, e.g. by another eager
  /// dependency's create().
  ///
  /// An error thrown by one of them is reported to the current [Zone]
  /// instead of being thrown, so the rest are still created and [add]/
  /// [addAll] still return their [Unregister]. The failed dependency stays
  /// registered and is created again on its next [get].
  void _resolveEager(Iterable<Dependency<Object>> dependencies) {
    for (final dependency in dependencies.where((d) => !d.lazy)) {
      final managed = _values[dependency.key];
      if (managed == null || !identical(managed.dependency, dependency)) {
        continue;
      }
      try {
        managed.resolve();
      } catch (error, stackTrace) {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }
  }

  /// Replaces the dependency registered under [Dependency.key], disposing
  /// the previous value and installing [dependency] - unlike [add], this
  /// always replaces, regardless of [Dependency.cacheKey].
  Unregister replace<T extends Object>(Dependency<T> dependency) {
    // Keyed off dependency.key, not the inferred T - when a Dependency<T>
    // flows through an Object-typed reference (e.g. stored in a
    // heterogeneous list), T infers to Object at this call site even though
    // the dependency's own reified type parameter - and thus its key - is
    // still the real one.
    remove<Object>(dependency.key);
    return add(dependency);
  }

  /// Remove the dependency under the specified key - or, for a
  /// [Registerable] (a [Module] or a [Dependency]), every dependency it
  /// describes, as a single unit.
  ///
  /// [keyOrRegisterable] can be:
  ///  - omitted, to remove the dependency registered under [T];
  ///  - a [Type], to remove the dependency registered under that type
  ///    without needing the generic parameter - e.g. `deps.remove(Foo)`;
  ///  - a [Registerable], to remove every dependency it groups - e.g.
  ///    `deps.remove(myModule)` removes every dependency that module lists.
  ///    This doesn't require holding onto the [Unregister] callback
  ///    returned by [add]/[addAll]: any [Registerable] describing the same
  ///    dependency types removes the same keys, since dependencies are
  ///    looked up by type, not by the identity of the [Registerable] that
  ///    originally registered them.
  ///
  /// A no-op once this [Deps] has been disposed - same as removing a key
  /// that was never registered - rather than throwing, since callers doing
  /// their own cleanup (e.g. a widget's unmount effect calling an
  /// [Unregister] callback) shouldn't have to carefully order that against
  /// [dispose] to avoid a crash.
  void remove<T extends Object>([Object? keyOrRegisterable]) {
    if (_isDisposed) {
      return;
    }
    if (keyOrRegisterable is Registerable) {
      for (final dependency in keyOrRegisterable.dependencies) {
        remove<Object>(dependency.key);
      }
      return;
    }
    if (keyOrRegisterable != null && keyOrRegisterable is! Type) {
      throw ArgumentError.value(
        keyOrRegisterable,
        'keyOrRegisterable',
        'must be a Type, a Registerable (e.g. a Module or Dependency), or '
            'omitted',
      );
    }
    final effectiveKey = (keyOrRegisterable as Type?) ?? T;
    final value = _values.remove(effectiveKey);
    unawaited(Future.sync(() => value?.dispose()));
    if (value != null) {
      notify(DependencyUnregistered(key: effectiveKey));
    }
  }

  /// Checks whether a dependency with the given key is registered in this
  /// [Deps] or any of its ancestors.
  bool isRegistered<T>([Type? key]) {
    final effectiveKey = key ?? T;

    return scopeChain.any((scope) => scope._values.containsKey(effectiveKey));
  }

  /// Unlike [isRegistered] this method only checks if the dependency is
  /// registered in this [Deps] instance, not its ancestors.
  bool _isRegisteredHere<T>([DependencyKey? key]) {
    final effectiveKey = key ?? T;

    return _values.containsKey(effectiveKey);
  }

  /// Helper method for obtaining a [ManagedDependency] instance backing
  /// the dependency of the specified type.
  ManagedDependency<T>? _tryGetDependency<T extends Object>([
    DependencyKey? key,
  ]) {
    final effectiveKey = key ?? T;
    for (final scope in scopeChain) {
      final value = scope._values[effectiveKey];
      if (value != null) {
        return value as ManagedDependency<T>;
      }
    }
    return null;
  }

  /// {@template lean_di_deps_get}
  /// Returns the resolved value of the specified dependency. If the dependency
  /// is not registered, this method will throw a
  /// [DependencyNotRegisteredError]. To see if a dependency is registered, use
  /// [isRegistered].
  /// {@endtemplate}
  T get<T extends Object>([DependencyKey? key]) {
    final effectiveKey = key ?? T;
    final dependency = _tryGetDependency<T>(key);
    if (dependency == null) {
      throw DependencyNotRegisteredError(effectiveKey);
    }
    return dependency.resolve();
  }

  /// Returns the resolved value of the specified dependency, or `null` if
  /// it isn't registered - unlike [get], which throws
  /// [DependencyNotRegisteredError] in that case. Like [get], this
  /// triggers creation of the dependency if it hasn't been created yet.
  ///
  /// To read a value without triggering creation as a side effect, use
  /// [peek] instead.
  T? tryGet<T extends Object>([DependencyKey? key]) {
    return _tryGetDependency<T>(key)?.resolve();
  }

  /// Returns the current value of the specified dependency if it's already
  /// been created, or `null` otherwise - whether because it isn't
  /// registered or because it's registered but hasn't been resolved yet.
  /// Unlike [get] and [tryGet], this never triggers creation.
  T? peek<T extends Object>([DependencyKey? key]) =>
      _tryGetDependency<T>(key)?.currentValue;

  /// Calls [onRegistration] whenever the [ManagedDependency] backing
  /// [effectiveKey] might have appeared, been replaced, or moved - i.e.
  /// registration events, not internal state changes. These are rare
  /// compared to state changes, so it's fine for every subscriber of
  /// [watch]/[watchInstance] to filter the shared events individually.
  RemoveListener _addRegistrationListener(
    DependencyKey effectiveKey,
    void Function() onRegistration,
  ) {
    return addEventListener((event) {
      final matches = switch (event) {
        DependencyChanged(:final key) => key == effectiveKey,
        DependencyRegistered(:final key) => key == effectiveKey,
        DependencyUnregistered() => false,
      };
      if (matches) {
        onRegistration();
      }
    });
  }

  /// Watch a dependency's registration only - for watching multiple
  /// dependencies at once see extensions [watch2], [watch3] etc. Emits
  /// whenever the dependency itself is (re-)registered, i.e. when
  /// [Deps.add] or [Deps.replace] installs a new value under this key - but
  /// NOT when a value that happens to be a `ChangeNotifier`/`Listenable`
  /// fires its own internal notifications. See [watch] for that.
  ///
  /// Cheaper than [watch] when you only care which instance is currently
  /// registered, not what it's internally doing - e.g. watching which auth
  /// service is active without rebuilding on its every internal tick.
  Stream<T> watchInstance<T extends Object>({DependencyKey? key}) {
    final effectiveKey = key ?? T;
    late final StreamController<T> controller;
    RemoveListener? removeListener;
    T? lastValue;

    void emitCurrent() {
      final value = tryGet<T>(key);
      // A lazily-created dependency's first resolution fires both
      // DependencyRegistered and DependencyChanged for the same instance.
      if (value != null && !identical(value, lastValue)) {
        lastValue = value;
        controller.add(value);
      }
    }

    controller = StreamController<T>.broadcast(
      onListen: () {
        removeListener = _addRegistrationListener(effectiveKey, emitCurrent);
        emitCurrent();
      },
      onCancel: () {
        removeListener?.call();
        unawaited(controller.close());
      },
    );

    return controller.stream;
  }

  /// Watch a dependency fully. Emits both when the dependency is
  /// (re-)registered (see [watchInstance]) AND whenever the resolved
  /// value's `DependencyObserver` (see [Dependency.createObserver]) reports
  /// an internal state change - e.g. a wrapped `ChangeNotifier`/`Listenable`
  /// firing its own notifications. Internal state changes are delivered by
  /// subscribing directly to the backing [ManagedDependency]'s own stream
  /// (shared by every subscriber of this key), not by broadcasting through
  /// every dependency's shared events - so watching this key doesn't cost
  /// anything when an unrelated dependency's state changes.
  Stream<T> watch<T extends Object>({DependencyKey? key}) {
    final effectiveKey = key ?? T;
    late final StreamController<T> controller;
    RemoveListener? removeListener;
    StreamSubscription<T>? innerSub;
    Object? lastId;

    void resubscribe() {
      final managed = _tryGetDependency<T>(key);
      if (identical(managed, lastId)) {
        // Registration events can fire more than once for what's really
        // the same underlying value becoming available - e.g. a
        // lazily-created dependency's first resolution fires both
        // DependencyRegistered and DependencyChanged. Resolving to the same
        // ManagedDependency twice means nothing actually changed, so skip
        // re-subscribing - a `watch()` BehaviorSubject replays its current
        // value to every fresh subscriber, so a redundant resubscribe here
        // would double-deliver.
        return;
      }
      lastId = managed;
      unawaited(innerSub?.cancel());
      innerSub =
          managed?.watch().listen(controller.add, onError: controller.addError);
    }

    controller = StreamController<T>.broadcast(
      onListen: () {
        removeListener = _addRegistrationListener(effectiveKey, resubscribe);
        resubscribe();
      },
      onCancel: () {
        removeListener?.call();
        unawaited(innerSub?.cancel());
        unawaited(controller.close());
      },
    );

    return controller.stream;
  }

  /// Creates all the specified dependencies right away, instead of lazily
  /// on their first [get].
  ///
  /// This method is useful e.g. when you want to ensure certain services
  /// are initialized before the application starts.
  ///
  /// ```dart
  /// void main() {
  ///   // register deps here
  ///   deps.add(/* ... */);
  ///   // ...
  ///
  ///   deps.ensureResolved([ServiceA, ServiceB]);
  ///
  ///   runApp(MyApp());
  /// }
  /// ```
  void ensureResolved(Iterable<DependencyKey> keys) {
    keys.forEach(get);
  }

  /// Dispose of the [Deps] instance and all dependencies it contains.
  ///
  /// All async [Dependency.dispose] callbacks are executed concurrently. The
  /// returned future completes once every callback has completed.
  @override
  Future<void> dispose() async {
    _isDisposed = true;
    if (leanDiDiagnosticsMode) {
      parent?._children.remove(this);
    }
    _removeParentListener?.call();
    await Future.wait(_values.values.map((value) => value.dispose()));
    await super.dispose();
  }
}

/// [Deps.watchInstance]-based helpers for watching several dependencies at
/// once - [watch2] through [watch5] cover the common fixed-arity cases;
/// [watchMany] is the general, dynamic-arity version they're built on.
extension DepsWatchMany on Deps {
  /// Combines the latest [watchInstance] value of each of [types]. Uses
  /// [watchInstance], not [watch] - each type's own internal state
  /// changes are ignored, only registration-level changes are combined.
  /// This is also what powers [Dependency.create] recomputing for computed
  /// dependencies (via `DepsReader.watchInstance`, internally): a computed
  /// value recomputes when an upstream dependency is replaced, not on
  /// every tick of an upstream `ChangeNotifier`.
  Stream<List<Object>> watchMany(List<Type> types) => Rx.combineLatest(
        types.map((type) => watchInstance(key: type)),
        (values) => values,
      );

  /// Combines the latest [watchInstance] value of [A] and [B] - see
  /// [watchMany].
  Stream<(A, B)> watch2<A, B>() =>
      watchMany([A, B]).map((list) => (list[0] as A, list[1] as B));

  /// Combines the latest [watchInstance] value of [A], [B] and [C] - see
  /// [watchMany].
  Stream<(A, B, C)> watch3<A, B, C>() => watchMany([A, B, C])
      .map((list) => (list[0] as A, list[1] as B, list[2] as C));

  /// Combines the latest [watchInstance] value of [A] through [D] - see
  /// [watchMany].
  Stream<(A, B, C, D)> watch4<A, B, C, D>() => watchMany([A, B, C, D])
      .map((list) => (list[0] as A, list[1] as B, list[2] as C, list[3] as D));

  /// Combines the latest [watchInstance] value of [A] through [E] - see
  /// [watchMany].
  Stream<(A, B, C, D, E)> watch5<A, B, C, D, E>() =>
      watchMany([A, B, C, D, E]).map(
        (list) => (
          list[0] as A,
          list[1] as B,
          list[2] as C,
          list[3] as D,
          list[4] as E
        ),
      );
}
