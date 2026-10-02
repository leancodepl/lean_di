import 'package:lean_di/lean_di.dart';

void main() {
  Deps.global.add(Dependency.value(Greeter()));

  final greeter = Deps.global.get<Greeter>();

  greeter.greet();
}

class Greeter {
  void greet() {
    print('Hello world!');
  }
}
