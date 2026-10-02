// Example
// ignore_for_file: avoid_print

import 'package:lean_di/lean_di.dart';

Future<void> main() async {
  // App-wide dependencies live in the global scope.
  Deps.global.add(Dependency.value(Logger()));

  // A fork is a child scope, e.g. for a single user session. It can read
  // everything from its parent, but its own registrations stay local.
  final sessionDeps = Deps.global.fork(debugLabel: 'session')
    ..addAll([
      // Lazily created on first use, with access to parent dependencies.
      Dependency(
        (deps, _) => ApiClient('staging', deps.get()),
      ),
      Dependency(
        // Reading ApiClient via watchInstance() makes UserRepository be
        // recreated whenever ApiClient is replaced.
        (deps, _) => UserRepository(deps.watchInstance(), deps.get()),
        dispose: (client) => client.close(),
      ),
    ]);

  // Session dependencies are not visible in the global scope.
  print(Deps.global.tryGet<ApiClient>()); // null

  sessionDeps.get<UserRepository>().fetchUser(); // Getting user from staging...

  // Replacing ApiClient recreates UserRepository.
  sessionDeps.replace(
    Dependency((deps, _) => ApiClient('production', deps.get())),
  );
  sessionDeps
      .get<UserRepository>()
      .fetchUser(); // Getting user from production...

  // Disposing the fork disposes everything registered in it, while the
  // global scope is left untouched.
  await sessionDeps.dispose(); // UserRepository closed
}

class Logger {
  void log(String message) => print(message);
}

class ApiClient {
  ApiClient(this._environment, this._logger);

  final String _environment;
  final Logger _logger;

  void getUser() => _logger.log('Getting user from $_environment...');
}

class UserRepository {
  UserRepository(this._api, this._logger);

  final ApiClient _api;
  final Logger _logger;

  void fetchUser() => _api.getUser();

  void close() => _logger.log('UserRepository closed');
}
