import 'dart:async';

import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';

import 'dependency.dart';
import 'dependency_observer.dart';
import 'deps.dart';
import 'deps_events.dart';
import 'deps_reader.dart';
import 'errors.dart';
import 'event_notifier.dart';
import 'types.dart';

/// This class helps manage lifecycle of a single dependency. It is tightly
/// coupled with [Deps]. It's an internal structure and it should never be
/// exposed as part of the public API.
@internal
class ManagedDependency<T extends Object> {
  ManagedDependency(this._dependency, this.deps, this._origin);

  /// The latest [Dependency] registered for this entry - see [update].
  Dependency<T> get dependency => _dependency;
  Dependency<T> _dependency;

  final Deps deps;

  /// The [Registerable] that was actually passed to
  /// [Deps.add]/[Deps.addAll] - see [DependencyDiagnostics.origin].
  Registerable get origin => _origin;
  Registerable _origin;

  /// Called by [Deps.add] when it keeps this entry, because [dependency] has
  /// the same key and [Dependency.cacheKey]: the current value stays, but
  /// from now on this entry uses [dependency] - its [Dependency.lazy],
  /// [Dependency.create] for later re-runs, [Dependency.dispose] and so on.
  void update(Dependency<T> dependency, Registerable origin) {
    _dependency = dependency;
    _origin = origin;
  }

  DependencyKey get key => dependency.key;

  /// This dependency's own value stream, shared by every subscriber that
  /// watches this key with [Deps.watch] - see also [watch] below. Created
  /// lazily, on the first call to [watch], so a dependency that's only ever
  /// plain-read via [Deps.get] - the common "just a service locator" case -
  /// never pays for a [DependencyObserver] or a [BehaviorSubject] it doesn't
  /// need.
  BehaviorSubject<T>? _controller;
  RemoveListener? _removeTrackingListener;
  T? _currentValue;

  /// One observer for the current [_currentValue], not one per subscriber -
  /// see [DependencyObserver]. Only created once [watch] has been called at
  /// least once (see [_controller]); recreated whenever [_currentValue]
  /// itself is replaced (either by re-registration or by a reactive
  /// [_runCreate] run).
  DependencyObserver<T>? _stateObserver;

  /// Set only while the initial [Dependency.create] is running, so that
  /// resolving [key] again from within it is detected as a cycle - and a
  /// create() that threw can be retried on the next [resolve].
  bool _isCreating = false;
  bool _isDisposed = false;

  /// The keys [Dependency.create] read via [DepsReader.watchInstance] on
  /// its last run, with the instance each resolved to - i.e. what
  /// [_removeTrackingListener] is currently listening for. Rediscovered on
  /// every run of [_runCreate], since which keys it reads can depend on
  /// `oldValue` and change between runs.
  Map<DependencyKey, Object> _tracked = const {};

  /// The currently resolved value, if any - without triggering creation.
  /// Package-internal - not `_`-private only because [Deps.peek] and
  /// [Deps.debugOwnDependencies] (a different library, now that lean_di's
  /// source is split across files) need to read it too.
  @internal
  T? get currentValue => _currentValue;

  /// No-op unless [watch] has already been called at least once for this
  /// dependency - see [_controller].
  void _attachStateObserverIfTracked(T value) {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    _stateObserver = dependency.createObserver(value)
      ?..attach(() => controller.add(value));
  }

  void _ensureInitialized() {
    if (_isDisposed) {
      throw DepsDisposedError(key: key);
    }
    if (_currentValue != null) {
      return;
    }
    if (_isCreating) {
      throw DependencyCycleError(key);
    }
    _isCreating = true;
    try {
      _runCreate();
    } finally {
      _isCreating = false;
    }
  }

  /// Runs [Dependency.create], applies its result, and re-subscribes to
  /// whatever it read via [DepsReader.watchInstance] this time - called
  /// once for the initial value (with `oldValue: null`), and again,
  /// synchronously, every time one of the keys tracked on the *previous*
  /// run is re-registered under a new instance.
  void _runCreate() {
    if (_isDisposed) {
      return;
    }

    final reader = _TrackingDepsReader(deps);
    final newValue = dependency.create(reader, _currentValue);
    _applyTracked(reader.tracked);

    if (newValue != _currentValue) {
      final oldObserver = _stateObserver;
      _currentValue = newValue;
      _stateObserver = null;
      unawaited(oldObserver?.dispose());
      _attachStateObserverIfTracked(newValue);
      _controller?.add(newValue);
      // reason: ManagedDependency and Deps work in tandem
      // ignore: invalid_use_of_protected_member
      deps.notify(DependencyChanged(key: key));
    }
  }

  void _applyTracked(Map<DependencyKey, Object> newTracked) {
    final hadTracked = _tracked.isNotEmpty;
    _tracked = newTracked;
    if (newTracked.isEmpty) {
      _removeTrackingListener?.call();
      _removeTrackingListener = null;
    } else if (!hadTracked) {
      _removeTrackingListener = deps.addEventListener(_onDepsEvent);
    }
  }

  void _onDepsEvent(DepsEvent event) {
    final key = switch (event) {
      DependencyRegistered(:final key) || DependencyChanged(:final key) => key,
      DependencyUnregistered() => null,
    };
    if (key == null || !_tracked.containsKey(key)) {
      return;
    }
    // Only re-run if the key now resolves to a different instance than the
    // one create() read - e.g. a replaced lazy dependency fires both
    // DependencyRegistered and, once create() below resolves it,
    // DependencyChanged, but only the first one is an actual change. A
    // `null` peek means a new, not yet resolved dependency was registered.
    final current = deps.peek<Object>(key);
    if (current == null || !identical(current, _tracked[key])) {
      _runCreate();
    }
  }

  T resolve() {
    _ensureInitialized();
    return switch (_currentValue) {
      final T value => value,
      null => throw StateError('Initialization error. This is a bug.'),
    };
  }

  Stream<T> watch() {
    _ensureInitialized();
    var controller = _controller;
    if (controller == null) {
      controller = _controller = BehaviorSubject<T>();
      _attachStateObserverIfTracked(_currentValue!);
      controller.add(_currentValue!);
    }
    return controller.stream;
  }

  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _removeTrackingListener?.call();
    await _controller?.close();
    await _stateObserver?.dispose();
    if ((dependency.dispose, _currentValue)
        case (final dispose?, final value?)) {
      final resolvedValue = value;
      await dispose(resolvedValue);
    }
  }
}

/// The [DepsReader] passed to [Dependency.create] - a thin wrapper around
/// the real [Deps] that records every key read via [watchInstance], and the
/// instance it resolved to, into [tracked], so [ManagedDependency._applyTracked]
/// can listen for exactly those keys afterward. [get] is a plain, unrecorded
/// passthrough.
class _TrackingDepsReader implements DepsReader {
  _TrackingDepsReader(this._deps);

  final Deps _deps;
  final Map<DependencyKey, Object> tracked = {};

  @override
  T get<T extends Object>([DependencyKey? key]) => _deps.get<T>(key);

  @override
  T watchInstance<T extends Object>([DependencyKey? key]) {
    final value = _deps.get<T>(key);
    tracked[key ?? T] = value;
    return value;
  }
}
