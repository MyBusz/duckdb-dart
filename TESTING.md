# Testing

Run commands from the repository root. Define `FLUTTER` as the path to the
Flutter executable; it defaults to `flutter` on `PATH`. Resolve `DART` from the
same SDK's `bin` directory so the two tools cannot silently come from different
SDK installations:

```sh
FLUTTER="${FLUTTER:-flutter}"
FLUTTER="$(command -v "$FLUTTER")"
DART="$(dirname "$FLUTTER")/dart"
```

Run `"$FLUTTER" pub get` first when `.dart_tool/package_config.json` is absent.

## Pure checks

Pure tests do not require downloaded native artifacts, bootstrap, or
`LD_LIBRARY_PATH`:

```sh
"$FLUTTER" analyze --no-pub
"$FLUTTER" test --no-pub test/types/date_test.dart
"$DART" test --help
```

## Full native tests

The full native suite requires the explicit native-artifact bootstrap to finish
successfully first. It is never run implicitly by Flutter, CMake, Gradle, or a
test hook. If the checkout does not yet contain the reviewed bootstrap entry
point, the full native suite is not runnable; do not report it as passing merely
because the pure tests pass.

After bootstrap materializes all verified platform artifacts, run:

```sh
"$FLUTTER" test --no-pub
```

On Linux, the loader in `lib/src/ffi/load_library.dart` expects
`libduckdb.so`. Point `LD_LIBRARY_PATH` at the bootstrapped release directory:

```sh
LD_LIBRARY_PATH="$PWD/linux/Libraries/release${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$FLUTTER" test --no-pub
```

## Browser tests

Browser tests are separate `package:test` invocations covering `test/web` and
the browser-only `test/types/boolean_test.dart`. Browser jobs must provision
Chrome or Chromium and set `CHROME_EXECUTABLE` to that executable when it is
not discoverable automatically. The test runner respects that environment
variable. Native and pure-test jobs do not require a browser.

As a discovery check, search for browser-only test declarations before changing
this scope:

```sh
find test -name '*_test.dart' -exec grep -l -E \
  "@TestOn\\(['\"]browser['\"]\\)|testOn:[[:space:]]*['\"]browser['\"]" {} +
```

Every discovered browser-only file outside `test/web` must be listed explicitly
in both compiler commands so a new `@TestOn('browser')` file is not omitted.

Run each browser compiler explicitly:

```sh
CHROME_EXECUTABLE="${CHROME_EXECUTABLE:-/path/to/chrome-or-chromium}" \
  "$DART" test --platform chrome --compiler dart2js \
    test/web test/types/boolean_test.dart
CHROME_EXECUTABLE="${CHROME_EXECUTABLE:-/path/to/chrome-or-chromium}" \
  "$DART" test --platform chrome --compiler dart2wasm \
    test/web test/types/boolean_test.dart
```
