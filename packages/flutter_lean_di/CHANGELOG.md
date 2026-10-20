## 0.1.1

- Fix a widget observing the same dependency in several ways (e.g. `select` and `watch`, two `select`s, or `watchInstance` and `watch`) only reacting to the first of them.
- Fix `select` using the selector from the widget's first build instead of its most recent one.

## 0.1.0

- Initial version
