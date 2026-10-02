import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_lean_di/src/errors.dart';
import 'package:lean_di/lean_di.dart';

import 'deps_context.dart';
import 'deps_diagnostics.dart';

part 'shared_deps_registry.dart';

/// Register on mount;  Unregister on unmount.
class DepsProvider extends StatefulWidget {
  /// Forks a fresh scope from the nearest ancestor one, or a fresh detached
  /// [Deps] if there is none. Use [DepsProvider.deps] to provide an existing
  /// [Deps] instance instead - e.g. [DepsProvider.global] for [Deps.global]
  /// - or [DepsProvider.shared] to share one ref-counted scope between
  /// several [DepsProvider]s.
  const DepsProvider({
    super.key,
    this.register,
    this.child,
    this.builder,
  })  : deps = null,
        sharedKey = null,
        assert(child != null || builder != null);

  /// Provide a custom [Deps] instance that dependencies listed in [register]
  /// should be added to. This will also influence the provided scope to the
  /// [child]/[builder] by [DepsProvider.of] and [DepsProvider.watch]. The
  /// caller remains responsible for eventually disposing [deps] - unlike the
  /// default constructor's forked scope, this widget never disposes it.
  const DepsProvider.deps(
    this.deps, {
    super.key,
    this.register,
    this.child,
    this.builder,
  })  : sharedKey = null,
        assert(child != null || builder != null);

  /// Provides the [Deps.global] scope.
  DepsProvider.global({super.key, this.child, this.builder})
      : deps = Deps.global,
        sharedKey = null,
        register = null,
        assert(child != null || builder != null);

  /// Every [DepsProvider] sharing this same [sharedKey] under the same
  /// nearest ancestor scope resolves to one underlying forked [Deps] -
  /// created when the first of them mounts, disposed once the last of them
  /// unmounts. Useful for a multi-screen flow that should share one scope
  /// without a single common ancestor widget spanning exactly its lifetime.
  ///
  /// [Dependency] keys registered via [register] are similarly shared: a key
  /// registered by more than one of these [DepsProvider]s is only actually
  /// removed - and disposed - once none of them still register it. This
  /// assumes a given key means the same thing (the same [Dependency.
  /// cacheKey], where used) across all of them.
  const DepsProvider.shared(
    this.sharedKey, {
    super.key,
    this.register,
    this.child,
    this.builder,
  })  : deps = null,
        assert(child != null || builder != null);

  /// See [DepsProvider.deps]. `null` unless this [DepsProvider] was created
  /// via that constructor (or [DepsProvider.global]).
  final Deps? deps;

  /// See [DepsProvider.shared]. `null` unless this [DepsProvider] was
  /// created via that constructor.
  final Object? sharedKey;

  /// A list of dependencies to register on mount and unregister on unmount.
  /// These dependencies will be bound to this widget, effectively.
  final Iterable<Registerable>? register;

  /// The widget below this widget in the tree. Use [builder] alternatively.
  /// If you're going to read the deps in the child widget, you should use
  /// [builder] or [Builder] instead to avoid reading stale context.
  final Widget? child;

  /// Alternative to [child]. A function that builds the child widget.
  final TransitionBuilder? builder;

  /// Obtain the nearest [Deps] scope.
  static Deps of(BuildContext context) {
    final inherited = context.getInheritedWidgetOfExactType<_DepsInherited>();

    if (inherited == null) {
      throw DepsProviderNotFoundError(context.widget.runtimeType);
    }

    return inherited.deps;
  }

  /// Obtain the nearest [Deps] scope or null if not found.
  static Deps? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<_DepsInherited>()?.deps;
  }

  /// Watch a dependency fully - see [DepsContext.watch].
  static T watch<T extends Object>(BuildContext context) {
    return _dependOnInheritedDeps(
        context, (T, const _ObserveOptions(observeState: true))).get<T>();
  }

  /// Like [watch], but returns `null` instead of throwing when [T] isn't
  /// registered.
  static T? maybeWatch<T extends Object>(BuildContext context) {
    return _dependOnInheritedDeps(
        context, (T, const _ObserveOptions(observeState: true))).tryGet<T>();
  }

  /// Watch a dependency's registration only - see
  /// [DepsContext.watchInstance].
  static T watchInstance<T extends Object>(BuildContext context) {
    return _dependOnInheritedDeps(
        context, (T, const _ObserveOptions(observeState: false))).get<T>();
  }

  /// Like [watchInstance], but returns `null` instead of throwing when [T]
  /// isn't registered.
  static T? maybeWatchInstance<T extends Object>(BuildContext context) {
    return _dependOnInheritedDeps(
        context, (T, const _ObserveOptions(observeState: false))).tryGet<T>();
  }

  /// Select a derived value - see [DepsContext.select].
  static R select<T extends Object, R>(
      BuildContext context, Selector<T, R> selector) {
    final value = _dependOnInheritedDeps(context,
        (T, _ObserveOptions(observeState: true, selector: selector))).get<T>();
    return selector(value);
  }

  /// Like [select], but returns `null` instead of throwing when [T] isn't
  /// registered.
  static R? maybeSelect<T extends Object, R>(
      BuildContext context, Selector<T, R> selector) {
    final value = _dependOnInheritedDeps(context, (
      T,
      _ObserveOptions(observeState: true, selector: selector)
    )).tryGet<T>();
    return value != null ? selector(value) : null;
  }

  static Deps _dependOnInheritedDeps<T extends Object>(
      BuildContext context, Object aspect) {
    final inherited = context
        .dependOnInheritedWidgetOfExactType<_DepsInherited>(aspect: aspect);

    if (inherited == null) {
      throw DepsProviderNotFoundError(context.widget.runtimeType, T);
    }

    return inherited.deps;
  }

  @override
  State<DepsProvider> createState() => _DepsProviderState();
}

class _DepsProviderState extends State<DepsProvider> {
  // The scope currently provided to descendants - either `widget.deps`, a
  // shared scope acquired via `widget.sharedKey`, or a fresh fork of the
  // parent scope (or a fresh detached `Deps()` if there is no ancestor
  // scope), depending on `widget.deps`/`widget.sharedKey`.
  Deps? _deps;

  // Non-null exactly when this widget forked its own private (non-shared)
  // scope and therefore owns its lifecycle outright.
  Deps? _ownedDeps;

  // Non-null exactly when `_deps` was acquired from a shared entry (via
  // `widget.sharedKey`), which this widget must eventually release rather
  // than dispose directly - other DepsProviders may still be using it.
  _SharedDepsEntry? _sharedEntry;
  _SharedDepsRegistry? _registry;
  Object? _sharedKeyHeld;

  // This widget's own registry, offered to its descendants (via
  // `_DepsInherited`) for their own `sharedKey` usage - independent of
  // whether this widget uses `sharedKey` itself.
  final _SharedDepsRegistry _ownRegistry = _SharedDepsRegistry();

  Deps? _lastDepsProp;
  Deps? _lastParentScope;
  Object? _lastSharedKey;

  Set<DependencyKey> _registeredKeys = const {};
  late Deps _registeredIn;

  // The shared entry `_registeredIn`'s keys' ref counts live in, if any -
  // tracked separately from `_sharedEntry` since the latter can already
  // point at a *new* target by the time registrations catch up to it.
  _SharedDepsEntry? _registeredInEntry;

  void _updateDeps(Deps? parentScope, _DepsInherited? inherited) {
    final depsProp = widget.deps;
    final sharedKey = widget.sharedKey;

    final unchanged = _deps != null &&
        identical(_lastDepsProp, depsProp) &&
        identical(_lastParentScope, parentScope) &&
        _lastSharedKey == sharedKey;
    if (unchanged) {
      return;
    }

    final previouslyOwnedDeps = _ownedDeps;
    final previousRegistry = _registry;
    final previousSharedKey = _sharedKeyHeld;

    _ownedDeps = null;
    _registry = null;
    _sharedEntry = null;
    _sharedKeyHeld = null;

    if (depsProp != null) {
      _deps = depsProp;
    } else if (sharedKey != null) {
      final registry = inherited?.registry ?? _rootFallbackRegistry;
      final entry = registry.acquire(sharedKey, parentScope ?? Deps());
      _deps = entry.deps;
      _sharedEntry = entry;
      _registry = registry;
      _sharedKeyHeld = sharedKey;
    } else {
      _deps = parentScope?.fork() ?? Deps();
      _ownedDeps = _deps;
    }

    _lastDepsProp = depsProp;
    _lastParentScope = parentScope;
    _lastSharedKey = sharedKey;

    // Acquire the replacement before releasing whatever we held before -
    // if they happen to resolve to the same shared entry, this avoids
    // transiently dropping its ref count to zero.
    if (previouslyOwnedDeps != null &&
        !identical(previouslyOwnedDeps, _ownedDeps)) {
      previouslyOwnedDeps.dispose();
    }
    if (previousRegistry != null && !identical(previousRegistry, _registry)) {
      previousRegistry.release(previousSharedKey!);
    }
  }

  void _updateRegistrations() {
    final deps = _deps!;
    final entry = _sharedEntry;

    if (_registeredKeys.isNotEmpty && !identical(_registeredIn, deps)) {
      // Switched to a different Deps instance entirely - whatever we
      // registered belongs to the old one, not this one.
      _releaseKeys(_registeredInEntry, _registeredIn, _registeredKeys);
      _registeredKeys = const {};
    }

    // [Dependency] is meant to be a lightweight, cheaply-recreated-every-
    // build config - like a [Widget] - so recreating it here shouldn't tear
    // down the service it describes by default. When an entry is registered
    // again under an unchanged [Dependency.cacheKey] (including both being
    // null), [Deps.add] already keeps its value and only takes on the new
    // [Dependency] - like Element keeping its State and updating its
    // Widget when a new one arrives with the same type+key - so calling it
    // for every current entry, every build, is enough. We still need to
    // watch keys ourselves for the one thing add() can't do - removing a
    // key that disappeared from the list entirely.
    final currentByKey = <DependencyKey, Dependency<Object>>{
      for (final registerable in widget.register ?? const <Registerable>[])
        for (final dependency in registerable.dependencies)
          dependency.key: dependency,
    };
    final currentKeys = currentByKey.keys.toSet();

    _releaseKeys(entry, deps, _registeredKeys.difference(currentKeys));
    _retainKeys(entry, currentKeys.difference(_registeredKeys));
    deps.addAll(currentByKey.values);

    _registeredKeys = currentKeys;
    _registeredIn = deps;
    _registeredInEntry = entry;
  }

  /// Removes [keys] from [deps] - or, when [entry] is non-null (i.e. [deps]
  /// is a shared scope), only once none of [entry]'s other holders still
  /// register that key.
  static void _releaseKeys(
    _SharedDepsEntry? entry,
    Deps deps,
    Iterable<DependencyKey> keys,
  ) {
    if (entry == null) {
      keys.forEach(deps.remove);
      return;
    }
    for (final key in keys) {
      final remaining = (entry.registrationRefCounts[key] ?? 1) - 1;
      if (remaining <= 0) {
        entry.registrationRefCounts.remove(key);
        deps.remove(key);
      } else {
        entry.registrationRefCounts[key] = remaining;
      }
    }
  }

  static void _retainKeys(
    _SharedDepsEntry? entry,
    Iterable<DependencyKey> keys,
  ) {
    if (entry == null) {
      return;
    }
    for (final key in keys) {
      entry.registrationRefCounts
          .update(key, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  @override
  void dispose() {
    final registeredIn = _registeredIn;
    final registeredKeys = _registeredKeys;
    final registeredInEntry = _registeredInEntry;
    final registry = _registry;
    final sharedKey = _sharedKeyHeld;

    if (registry != null) {
      // Deferred by a frame: if another DepsProvider mounts with the same
      // sharedKey before this runs - the common case for a same-frame
      // screen-transition handoff - it retains/acquires first, so this
      // release never actually reaches zero and the shared scope (and any
      // dependency both sides register) survives instead of being torn
      // down and immediately recreated.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _releaseKeys(registeredInEntry, registeredIn, registeredKeys);
        registry.release(sharedKey!);
      });
    } else {
      registeredKeys.forEach(registeredIn.remove);
      _ownedDeps?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inherited = context.getInheritedWidgetOfExactType<_DepsInherited>();
    final parentScope = inherited?.deps;
    _updateDeps(parentScope, inherited);
    _updateRegistrations();

    return _DepsInherited(
      deps: _deps!,
      registry: _ownRegistry,
      child: Builder(
        builder: (context) {
          var result = widget.child;
          if (widget.builder case final builder?) {
            result = builder(context, result);
          }
          return result ?? const SizedBox();
        },
      ),
    );
  }
}

class _DepsInherited extends InheritedWidget {
  const _DepsInherited({
    required super.child,
    required this.deps,
    required this.registry,
  });

  final Deps deps;

  /// The owning [DepsProvider]'s registry of [_SharedDepsEntry]s, offered to
  /// its descendants for their own [DepsProvider.sharedKey] usage.
  final _SharedDepsRegistry registry;

  @override
  bool updateShouldNotify(_DepsInherited oldWidget) {
    return deps != oldWidget.deps;
  }

  @override
  InheritedElement createElement() {
    return _DepsElement(this);
  }

  /// Surfaces [deps] - its own registered dependencies, and (with
  /// [leanDiDiagnosticsMode] enabled) every descendant scope - in the
  /// widget inspector/`debugDumpApp()`. This is on the internal
  /// `_DepsInherited` node one level below [DepsProvider], not
  /// [DepsProvider] itself - the live scope (possibly a fresh [Deps.fork])
  /// is only known once `build()` runs, and that's where it lives. In
  /// DevTools, turn off "Show only widgets created by user" to see it.
  @override
  List<DiagnosticsNode> debugDescribeChildren() => [
        deps.toDiagnosticsNode(name: 'deps'),
      ];
}

class _DepsElement extends InheritedElement {
  _DepsElement(_DepsInherited super.widget);

  @override
  _DepsInherited get widget => super.widget as _DepsInherited;

  /// One real [Deps.watch]/[Deps.watchInstance] subscription per (type,
  /// observeState) pair, shared by every dependent watching that
  /// combination - not one per dependent. Keyed on observeState too since
  /// two dependents can ask for the same type with different observeState
  /// values.
  final Map<(Type, bool), StreamSubscription<Object>> _subscriptions = {};

  /// Which dependents are watching a given type, and their per-dependent
  /// selector state - so dispatching a value only touches watchers of that
  /// type instead of every dependent of this element.
  final Map<Type, Map<Element, _Watcher>> _watchersByType = {};

  @override
  void updated(_DepsInherited oldWidget) {
    if (widget.deps != oldWidget.deps) {
      for (final sub in _subscriptions.values) {
        sub.cancel();
      }
      _subscriptions.clear();
      _watchersByType.clear();
    }
    super.updated(oldWidget);
  }

  @override
  void updateDependencies(Element dependent, Object? aspect) {
    setDependencies(dependent, aspect);
  }

  @override
  void setDependencies(Element dependent, Object? value) {
    if (value == null) {
      return;
    }
    if (value is! (Type, _ObserveOptions)) {
      throw ArgumentError.value(
          value, 'value', 'value must be a (Type, _ObserveOptions)');
    }
    final (type, options) = value;

    final watchers = _watchersByType.putIfAbsent(type, () => {});
    if (watchers.containsKey(dependent)) {
      // Already set up - matches the old map's `??=`, which likewise only
      // ever honored the first (dependent, type) registration.
      return;
    }
    final selector = options.selector;
    watchers[dependent] = _Watcher(
      observeState: options.observeState,
      selector: selector,
      // What the dependent's select()/maybeSelect() is about to return - it
      // reads the same instance right after this - so the next change is
      // compared against what it actually shows, whether or not the shared
      // subscription below already existed.
      lastSelected: selector == null
          ? null
          : _applySelector(selector, widget.deps.tryGet<Object>(type)),
    );

    final subscriptionKey = (type, options.observeState);
    _subscriptions.putIfAbsent(subscriptionKey, () {
      final deps = widget.deps;
      final stream = options.observeState
          ? deps.watch(key: type)
          : deps.watchInstance(key: type);
      // Both replay the current value on listen when there is one, which the
      // dependent has just read - so only later emissions are changes. When
      // the type isn't registered yet there's no replay, and the first
      // emission is its registration.
      return stream
          .skip(deps.isRegistered<Object>(type) ? 1 : 0)
          .listen((value) => _dispatch(subscriptionKey, value));
    });
  }

  static Object? _applySelector(Function selector, Object? value) =>
      // reason: selector is stored as a bare Function to keep _Watcher
      // non-generic.
      value == null ? null : (selector as dynamic)(value);

  /// Called for every change of a subscribed dependency - never for the
  /// value its dependents were built with, see [setDependencies].
  void _dispatch((Type, bool) subscriptionKey, Object value) {
    final (type, observeState) = subscriptionKey;
    final watchers = _watchersByType[type];
    if (watchers == null) {
      return;
    }
    for (final MapEntry(key: dependent, value: watcher) in watchers.entries) {
      if (watcher.observeState != observeState) {
        continue;
      }
      if (watcher.selector case final selector?) {
        final selected = _applySelector(selector, value);
        if (selected == watcher.lastSelected) {
          continue;
        }
        watcher.lastSelected = selected;
      }
      dependent.markNeedsBuild();
    }
  }

  @override
  void removeDependent(Element dependent) {
    for (final type in [..._watchersByType.keys]) {
      final watchers = _watchersByType[type];
      if (watchers == null || watchers.remove(dependent) == null) {
        continue;
      }
      _pruneSubscriptionsIfUnused(type, watchers);
    }
    super.removeDependent(dependent);
  }

  void _pruneSubscriptionsIfUnused(Type type, Map<Element, _Watcher> watchers) {
    if (watchers.isEmpty) {
      _watchersByType.remove(type);
      _subscriptions.remove((type, true))?.cancel();
      _subscriptions.remove((type, false))?.cancel();
      return;
    }
    if (!watchers.values.any((w) => w.observeState)) {
      _subscriptions.remove((type, true))?.cancel();
    }
    if (!watchers.values.any((w) => !w.observeState)) {
      _subscriptions.remove((type, false))?.cancel();
    }
  }

  @override
  void unmount() {
    for (final sub in _subscriptions.values) {
      sub.cancel();
    }
    _subscriptions.clear();
    _watchersByType.clear();
    super.unmount();
  }
}

class _Watcher {
  _Watcher({required this.observeState, this.selector, this.lastSelected});

  final bool observeState;
  final Function? selector;

  /// The last value [selector] returned that the dependent was built with.
  Object? lastSelected;
}

@immutable
class _ObserveOptions {
  const _ObserveOptions({required this.observeState, this.selector});

  final bool observeState;
  final Function? selector;
}
