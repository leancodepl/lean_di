import 'package:flutter/foundation.dart';
import 'package:lean_di/lean_di.dart';

/// Thrown when a `Deps` lookup through `DepsProvider.of`,
/// `DepsProvider.watch`, `DepsProvider.watchInstance`, or
/// `DepsProvider.select` (and the `DepsContext` shortcuts for those) finds
/// no `DepsProvider` above [widgetType] in the tree.
///
/// Use `DepsProvider.maybeOf` (or the `maybeWatch`/`maybeWatchInstance`/
/// `maybeSelect` variants) for a nullable result instead of throwing. If
/// this came from a watch/select, [requestedKey] is the dependency key
/// that was asked for.
class DepsProviderNotFoundError extends Error {
  /// Thrown for [widgetType], optionally naming [requestedKey] - see the
  /// class-level docs above.
  DepsProviderNotFoundError(this.widgetType, [this.requestedKey]);

  /// The type of the Widget requesting the value
  final Type widgetType;

  /// The key that was looked up.
  final DependencyKey? requestedKey;

  @override
  String toString() {
    if (!kDebugMode) {
      return '''
DepsProviderNotFoundError: DepsProvider not found above widget ($widgetType)${requestedKey != null ? ' for requested key ($requestedKey)' : ''}.
''';
    }

    return '''
DepsProviderNotFoundError: DepsProvider not found above widget ($widgetType)${requestedKey != null ? ' for requested key ($requestedKey)' : ''}.

Make sure to include DepsProvider in the widget tree above the widget ($widgetType).

If you have DepsProvider in the widget tree this issue may be caused by:

1. DepsProvider in a different different route. This also includes dialogs, modals, overlays.

2. Trying to access Deps.global dependency without DepsProvider.global in the root of the widget tree.

3. Using parent BuildContext. A common case is trying to access dependency while building a widget provided in child argument of DepsProvider. The builder argument should be used instead.

Bad:
@override
Widget build(BuildContext context) {
  return DepsProvider(
    register: [Dependency((deps, _) => Foo())],
    child: Text(context.get<Foo>()),
  );
}

Good:
@override
Widget build(BuildContext context) {
  return DepsProvider(
    register: [Dependency((deps, _) => Foo())],
    builder: (context, _) => Text(context.get<Foo>()),
  );
}
''';
  }
}
