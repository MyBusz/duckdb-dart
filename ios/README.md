# iOS native package

The release builder creates the device-arm64 and simulator-arm64/x86_64 slices
from the pinned local DuckDB source and packages them as
`duckdb-ios-xcframework.zip`. It does not download source or native artifacts.
Before CocoaPods evaluates the podspec, the offline bootstrap must install every
iOS member declared by `native/assets.lock.json`; podspec evaluation rechecks
each declared destination, byte size, and SHA-256 without a prepare command or
network access.

Executing DuckDB through an iOS Simulator remains a hosted **Phase 1B2** release
gate. This Phase 1B1 builder only performs package, Mach-O, architecture, symbol,
and metadata checks; it deliberately does not create, boot, or orchestrate a
simulator application.
