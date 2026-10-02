import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lean_di_bloc/flutter_lean_di_bloc.dart';

void main() {
  // App-wide dependencies can be regsitered in global scope and access outside
  // of the widget tree.
  Deps.global.addAll([
    Dependency((_, _) => GlobalKey<ScaffoldMessengerState>()),
    Dependency((deps, _) => Logger(deps.get())),
  ]);

  runApp(const App());
}

class CounterCubit extends Cubit<int> {
  CounterCubit(this.label, this._logger) : super(0) {
    _logger.log('CounterCubit ($label) created');
  }

  final String label;
  final Logger _logger;

  void increment() => emit(state + 1);

  @override
  Future<void> close() {
    _logger.log('CounterCubit ($label) closed');
    return super.close();
  }
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    // DepsProvider.global allows accessing to global dependencies via context
    // and enables observing changes with watch/watchInstance.
    return DepsProvider.global(
      builder: (context, _) => MaterialApp(
        scaffoldMessengerKey: context.get(),
        onGenerateRoute: onGenerateRoute,
      ),
    );
  }
}

Route<void>? onGenerateRoute(RouteSettings settings) {
  final screen = switch (Uri.parse(settings.name ?? '/').pathSegments) {
    [] => const HomeScreen(),
    ['single-screen'] => SingleScreen(),
    ['process', final processId, 'first-step'] => ProcessFirstStep(
      processId: processId,
    ),
    ['process', final processId, 'second-step'] => ProcessSecondStep(
      processId: processId,
    ),
    _ => null,
  };

  return screen == null
      ? null
      : MaterialPageRoute(settings: settings, builder: (_) => screen);
}

var processCount = 0;

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_lean_di')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).pushNamed('/single-screen'),
              child: const Text('Single screen'),
            ),
            ElevatedButton(
              onPressed: () {
                final processId = '${processCount++}';

                Navigator.of(
                  context,
                ).pushNamed('/process/$processId/first-step');
              },
              child: const Text('Process'),
            ),
          ],
        ),
      ),
    );
  }
}

class SingleScreen extends StatelessWidget {
  const SingleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // A per-screen dependency: the Counter is created with the screen and
    // disposed when it's popped.
    return DepsProvider(
      register: [
        BlocDependency((deps, _) => CounterCubit('single screen', deps.get())),
      ],
      child: const CounterScreen(title: 'Screen dependencies'),
    );
  }
}

// DepsProvider for the process dependencies. Provides the same Counter instance
// to all steps when created with the same process ID.
class ProcessDepsProvider extends StatelessWidget {
  const ProcessDepsProvider({
    super.key,
    required this.processId,
    required this.builder,
  });

  final String processId;
  final TransitionBuilder builder;

  @override
  Widget build(BuildContext context) {
    return DepsProvider.shared(
      ProcessId(processId),
      register: [
        BlocDependency(
          (deps, _) => CounterCubit('process #$processId', deps.get()),
        ),
      ],
      builder: builder,
    );
  }
}

// Dedicated type for process ID to ensure no collisions between different
// process types (recommended).
class ProcessId {
  const ProcessId(this.id);

  final String id;

  @override
  operator ==(Object other) => other is ProcessId && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class ProcessFirstStep extends StatelessWidget {
  const ProcessFirstStep({super.key, required this.processId});

  final String processId;

  @override
  Widget build(BuildContext context) {
    // Each step has to be wrapped with ProcessDepsProvider to provide the
    // shared Counter instance.
    return ProcessDepsProvider(
      processId: processId,
      builder: (context, _) => CounterScreen(
        title: 'Process $processId: first step',
        action: FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pushNamed('/process/$processId/second-step'),
          child: const Text('Second step'),
        ),
      ),
    );
  }
}

class ProcessSecondStep extends StatelessWidget {
  const ProcessSecondStep({super.key, required this.processId});

  final String processId;

  @override
  Widget build(BuildContext context) {
    // Each step has to be wrapped with ProcessDepsProvider to provide the
    // shared Counter instance.
    return ProcessDepsProvider(
      processId: processId,
      builder: (context, _) => CounterScreen(
        title: 'Process $processId: second step',
        action: FilledButton(
          onPressed: () =>
              Navigator.of(context).popUntil(ModalRoute.withName('/')),
          child: const Text('Finish'),
        ),
      ),
    );
  }
}

class CounterScreen extends StatelessWidget {
  const CounterScreen({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final counter = context.watch<CounterCubit>();

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            Text(
              '${counter.state}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            ?action,
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: counter.increment,
        child: const Icon(Icons.add),
      ),
    );
  }
}

class Logger {
  Logger(this._messengerKey);

  final GlobalKey<ScaffoldMessengerState> _messengerKey;

  void log(String message) {
    debugPrint(message);
    scheduleMicrotask(
      () => _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
      ),
    );
  }
}
