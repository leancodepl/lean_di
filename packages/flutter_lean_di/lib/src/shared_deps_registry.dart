part of 'deps_provider.dart';

/// A [Deps] fork shared by every [DepsProvider] currently referencing the
/// same [DepsProvider.sharedKey] under the same nearest ancestor scope -
/// created when the first of them acquires it, disposed once the last one
/// releases it. See [_SharedDepsRegistry].
class _SharedDepsEntry {
  _SharedDepsEntry(this.deps);

  final Deps deps;

  /// How many [DepsProvider]s currently hold this entry (i.e. have acquired
  /// it and not yet released it).
  int refCount = 1;

  /// How many of those holders currently list a given key in [DepsProvider.
  /// register] - so one holder unmounting doesn't remove (and dispose) a
  /// dependency another holder sharing this scope still relies on.
  final Map<DependencyKey, int> registrationRefCounts = {};
}

/// Ref-counted cache of [_SharedDepsEntry]s, keyed by [DepsProvider.
/// sharedKey]. One lives per ancestor [DepsProvider] (handed down via
/// [_DepsInherited]) for its own descendants to share; [_rootFallbackRegistry]
/// covers the case where a [DepsProvider.sharedKey] is used with no ancestor
/// [DepsProvider] at all.
class _SharedDepsRegistry {
  final Map<Object, _SharedDepsEntry> _entries = {};

  _SharedDepsEntry acquire(Object key, Deps parentScope) {
    final existing = _entries[key];
    if (existing != null) {
      existing.refCount++;
      return existing;
    }
    final entry = _SharedDepsEntry(parentScope.fork());
    _entries[key] = entry;
    return entry;
  }

  void release(Object key) {
    final entry = _entries[key];
    if (entry == null) {
      return;
    }
    if (--entry.refCount <= 0) {
      _entries.remove(key);
      entry.deps.dispose();
    }
  }
}

/// Registry for use when a [DepsProvider.sharedKey] is acquired with no
/// ancestor [DepsProvider] to hold one - i.e. this [DepsProvider] is at the
/// root of its own tree, so there's exactly one such "no ancestor" bucket to
/// share. Expected to be rare - most shared scopes have a common ancestor
/// [DepsProvider] to hang off of.
final _rootFallbackRegistry = _SharedDepsRegistry();
