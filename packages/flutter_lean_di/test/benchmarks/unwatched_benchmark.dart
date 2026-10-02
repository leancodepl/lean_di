import 'package:flutter/material.dart';
import 'package:flutter_lean_di/flutter_lean_di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'bench_stats.dart';
import 'services.dart';

/// Same shape as initial_build_benchmark.dart and dispose_benchmark.dart,
/// but every leaf does a plain, non-reactive read (`context.get`/
/// `context.read`) instead of `context.observe`/`context.watch`.
///
/// On the lean_di side this is the pure "service locator" usage pattern -
/// register N services, read them, never watch anything. Since
/// ManagedDependency now creates its DependencyObserver/BehaviorSubject
/// lazily on first `watch()` (see deps.dart), none of that machinery should
/// ever be built here at all, and this should be noticeably cheaper than
/// initial_build_benchmark/dispose_benchmark's fully-watched numbers -
/// especially on dispose, where there's nothing observer-related left to
/// tear down.
///
/// Run with: flutter test test/benchmarks/unwatched_benchmark.dart
void main() {
  const warmUp = 3;
  const runs = 10;

  testWidgets('Unwatched: $serviceCount services, plain reads only',
      (tester) async {
    Deps? currentDeps;

    final leanDiBuildStats = await runBenchmark(
      warmUpRuns: warmUp,
      measuredRuns: runs,
      setUp: () async {
        await tester.pumpWidget(const SizedBox());
        await currentDeps?.dispose();
        currentDeps = null;
      },
      body: () async {
        final scopeDeps = Deps.global.fork()
          ..addAll([
            for (var i = 0; i < serviceCount; i++) leanDiFactories[i](i),
          ])
          ..ensureResolved(serviceTypes);
        currentDeps = scopeDeps;

        await tester.pumpWidget(
          MaterialApp(
            home: DepsProvider.deps(
              scopeDeps,
              child: Builder(builder: leanDiNonReactiveReaders[0]),
            ),
          ),
        );
      },
    );

    final providerBuildStats = await runBenchmark(
      warmUpRuns: warmUp,
      measuredRuns: runs,
      setUp: () async {
        await tester.pumpWidget(const SizedBox());
      },
      body: () async {
        await tester.pumpWidget(
          MaterialApp(
            home: MultiProvider(
              providers: [
                for (var i = 0; i < serviceCount; i++) providerFactories[i](i),
              ],
              child: Builder(builder: providerNonReactiveReaders[0]),
            ),
          ),
        );
      },
    );

    await currentDeps?.dispose();

    printComparison('Unwatched initial build ($serviceCount services)', {
      'lean_di': leanDiBuildStats,
      'provider': providerBuildStats,
    });

    final leanDiDisposeStats = await runBenchmark(
      warmUpRuns: warmUp,
      measuredRuns: runs,
      setUp: () async {
        final scopeDeps = Deps.global.fork()
          ..addAll([
            for (var i = 0; i < serviceCount; i++) leanDiFactories[i](i),
          ])
          ..ensureResolved(serviceTypes);
        currentDeps = scopeDeps;

        await tester.pumpWidget(
          MaterialApp(
            home: DepsProvider.deps(
              scopeDeps,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < serviceCount; i++)
                      Builder(builder: leanDiNonReactiveReaders[i]),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      body: () async {
        await tester.pumpWidget(const SizedBox());
        await currentDeps!.dispose();
        await tester.pump();
        await tester.pump();
      },
    );

    final providerDisposeStats = await runBenchmark(
      warmUpRuns: warmUp,
      measuredRuns: runs,
      setUp: () async {
        await tester.pumpWidget(
          MaterialApp(
            home: MultiProvider(
              providers: [
                for (var i = 0; i < serviceCount; i++) providerFactories[i](i),
              ],
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < serviceCount; i++)
                      Builder(builder: providerNonReactiveReaders[i]),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      body: () async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await tester.pump();
      },
    );

    printComparison('Unwatched dispose ($serviceCount services)', {
      'lean_di': leanDiDisposeStats,
      'provider': providerDisposeStats,
    });

    // --- Re-registration: swap all N services for brand new instances,
    // with nothing watching. lean_di can do this as a pure registry
    // mutation - Deps is independent of the widget tree, so nothing needs
    // to be rebuilt. provider has no equivalent "swap this provider's value
    // for a new instance in place" operation - a provider's value only ever
    // changes by tearing down and re-inflating its element, so getting a
    // genuinely new instance (not just a mutated one) means forcing a
    // remount, here via a changing key around the whole subtree.
    var generation = 0;

    final scopeDeps = Deps.global.fork()
      ..addAll([
        for (var i = 0; i < serviceCount; i++) leanDiFactories[i](i),
      ])
      ..ensureResolved(serviceTypes);

    await tester.pumpWidget(
      MaterialApp(
        home: DepsProvider.deps(
          scopeDeps,
          child: Builder(builder: leanDiNonReactiveReaders[0]),
        ),
      ),
    );

    final leanDiReregisterStats = await runBenchmark(
      warmUpRuns: warmUp,
      measuredRuns: runs,
      body: () async {
        generation++;
        // replace(), not addAll: these factories carry no cacheKey, so
        // add() would now leave each service alone (null == null) instead
        // of swapping in the new instance - replace() forces it, as
        // intended for this "swap for a genuinely new instance" scenario.
        for (var i = 0; i < serviceCount; i++) {
          scopeDeps.replace(leanDiFactories[i](generation * 1000 + i));
        }
        await tester.pump();
      },
    );
    expect(scopeDeps.get<Svc0>().value, equals(generation * 1000));

    await tester.pumpWidget(const SizedBox());
    await scopeDeps.dispose();

    generation = 0;
    Widget buildProviderTree() => MaterialApp(
          home: KeyedSubtree(
            key: ValueKey(generation),
            child: MultiProvider(
              providers: [
                for (var i = 0; i < serviceCount; i++)
                  providerFactories[i](generation * 1000 + i),
              ],
              child: Builder(builder: providerNonReactiveReaders[0]),
            ),
          ),
        );

    await tester.pumpWidget(buildProviderTree());

    final providerReregisterStats = await runBenchmark(
      warmUpRuns: warmUp,
      measuredRuns: runs,
      body: () async {
        generation++;
        await tester.pumpWidget(buildProviderTree());
      },
    );
    expect(
      providerGetters[0](tester.element(find.byType(Text))).value,
      equals(generation * 1000),
    );

    await tester.pumpWidget(const SizedBox());

    printComparison('Unwatched re-register ($serviceCount services)', {
      'lean_di': leanDiReregisterStats,
      'provider': providerReregisterStats,
    });
  });
}
