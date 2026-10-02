import 'package:flutter/material.dart';
import 'package:flutter_lean_di/flutter_lean_di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'bench_stats.dart';
import 'services.dart';

/// Mounts a subtree with [serviceCount] eagerly-created services, then
/// unmounts it and measures teardown cost: removing N InheritedElement
/// subscriptions plus disposing N ChangeNotifiers.
///
/// Note: lean_di's `Deps.dispose()` fires off each dependency's disposal
/// without awaiting it (see `Deps.dispose`/`ManagedDependency.dispose` in
/// package:lean_di - each call is wrapped in `unawaited(...)`), so that
/// work can finish a microtask or two after `dispose()` returns. We pump
/// twice after disposing to let it settle before stopping the clock, for
/// both libraries symmetrically - otherwise this benchmark would make
/// lean_di look faster than it really is by not counting work it deferred.
///
/// Run with: flutter test test/benchmarks/dispose_benchmark.dart
void main() {
  const warmUp = 3;
  const runs = 10;

  testWidgets('Dispose: $serviceCount services', (tester) async {
    Deps? currentDeps;

    final leanDiStats = await runBenchmark(
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
                      Builder(builder: leanDiReaders[i]),
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

    final providerStats = await runBenchmark(
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
                      Builder(builder: providerReaders[i]),
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

    printComparison('Dispose ($serviceCount services)', {
      'lean_di': leanDiStats,
      'provider': providerStats,
    });
  });
}
