import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

/// Callback returned by [EventNotifier.addEventListener] that removes the
/// listener it was returned for.
@internal
typedef RemoveListener = void Function();

/// A minimal synchronous event dispatcher - `Deps` extends this for its own
/// `DepsEvent`s. Package-internal; not exposed as part of the public API.
///
/// Listeners are called synchronously from [notify], so by the time the
/// call that caused an event (e.g. `Deps.replace`) returns, everything
/// reacting to it - including dependencies recomputing - has already run.
/// Listeners are allowed to [notify] again while handling an event: such
/// events are queued and delivered, in order, once the current event has
/// reached every listener. This keeps every listener seeing the same
/// sequence of events, which a synchronous [Stream] can't do - it throws
/// when an event is added while it's still delivering the previous one.
@internal
abstract class EventNotifier<E> {
  /// Creates an [EventNotifier] with no listeners.
  EventNotifier();

  final _listeners = <_Listener<E>>[];
  final _queue = Queue<E>();
  bool _isDispatching = false;

  /// Calls [listener] synchronously for every event passed to [notify] from
  /// now on, until the returned callback is called.
  @internal
  RemoveListener addEventListener(void Function(E event) listener) {
    final entry = _Listener(listener);
    _listeners.add(entry);
    return () {
      entry.isActive = false;
      _listeners.remove(entry);
    };
  }

  /// Delivers [event] to every current listener - see the class docs for
  /// what happens when called from within a listener.
  @protected
  @nonVirtual
  void notify(E event) {
    _queue.add(event);
    if (_isDispatching) {
      return;
    }

    _isDispatching = true;
    try {
      while (_queue.isNotEmpty) {
        final event = _queue.removeFirst();
        // Iterate over a copy, so listeners can add or remove listeners.
        for (final entry in [..._listeners]) {
          if (!entry.isActive) {
            continue;
          }
          try {
            entry.listener(event);
          } catch (error, stackTrace) {
            // Same as an error thrown by a stream listener - one failing
            // listener shouldn't prevent the rest from being notified.
            Zone.current.handleUncaughtError(error, stackTrace);
          }
        }
      }
    } finally {
      _isDispatching = false;
    }
  }

  /// Removes every listener - subclasses overriding this should call `super`.
  @mustCallSuper
  Future<void> dispose() async {
    for (final entry in _listeners) {
      entry.isActive = false;
    }
    _listeners.clear();
    _queue.clear();
  }
}

class _Listener<E> {
  _Listener(this.listener);

  // reason: only ever called with events of the notifier's own type E
  // ignore: unsafe_variance
  final void Function(E event) listener;

  /// Cleared on removal, so a listener removed by another listener during
  /// the same event isn't called anymore.
  bool isActive = true;
}
