import 'package:bloc/bloc.dart';
import 'package:flutter_lean_di_bloc/flutter_lean_di_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class Counter extends Cubit<int> {
  Counter(super.initialState);
}

void main() {
  late Deps deps;

  setUp(() => deps = Deps());

  tearDown(() => deps.dispose());

  test(
      'a changed cacheKey closes the old bloc/cubit and creates a new '
      'one', () async {
    deps.add(BlocDependency<Counter>((_, __) => Counter(0), cacheKey: 1));
    final first = deps.get<Counter>();

    deps.add(BlocDependency<Counter>((_, __) => Counter(0), cacheKey: 2));
    await Future<void>.delayed(Duration.zero);

    expect(first.isClosed, isTrue);
    expect(deps.get<Counter>(), isNot(same(first)));
  });

  test(
      'the bloc/cubit is closed automatically when removed, via '
      'BlocBase.close()', () async {
    deps.add(BlocDependency<Counter>((_, __) => Counter(0)));

    final counter = deps.get<Counter>();
    expect(counter.isClosed, isFalse);

    deps.remove<Counter>();
    await Future<void>.delayed(Duration.zero);

    expect(counter.isClosed, isTrue);
  });

  test('an explicit dispose overrides the default close()', () async {
    var customDisposeCalls = 0;
    deps.add(
      BlocDependency<Counter>(
        (_, __) => Counter(0),
        dispose: (counter) {
          customDisposeCalls++;
          return counter.close();
        },
      ),
    );

    final counter = deps.get<Counter>();
    deps.remove<Counter>();
    await Future<void>.delayed(Duration.zero);

    expect(customDisposeCalls, equals(1));
    expect(counter.isClosed, isTrue);
  });
}
