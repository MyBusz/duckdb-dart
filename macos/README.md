# macOS native package

The release builder creates x86_64 and arm64 slices from the pinned local DuckDB
source and packages their universal library as `duckdb-macos-universal.zip`. It
does not download source or native artifacts. Before CocoaPods evaluates the
podspec, the offline bootstrap must install every macOS member declared by
`native/assets.lock.json`; podspec evaluation rechecks each declared destination,
byte size, and SHA-256 without a prepare command or network access.

Runtime execution checks on **both** macOS architectures remain hosted
**Phase 1B2** release gates. Phase 1B1 only runs the build-host smoke check and
static package/Mach-O/symbol validation; it does not orchestrate cross-host
runtime execution.
