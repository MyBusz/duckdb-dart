# iOS native package

The release builder creates the device-arm64 and simulator-arm64/x86_64 slices
from the pinned local DuckDB source and packages them as
`duckdb-ios-xcframework.zip`. It does not download source or native artifacts.
The app and device deployment target remains iOS 13.0. The simulator Mach-O
slices encode their architecture-specific floors: arm64 uses 14.0 and x86_64
uses 13.0. Their universal framework keeps one standard scalar
`MinimumOSVersion` of 14.0, while the device framework uses 13.0.
Before CocoaPods evaluates the podspec, the offline bootstrap must install every
iOS member declared by `native/assets.lock.json`; podspec evaluation rechecks
each declared destination, byte size, and SHA-256 without a prepare command or
network access.

Executing DuckDB through an iOS Simulator remains a hosted **Phase 1B2** release
gate. This Phase 1B1 builder only performs package, Mach-O, architecture, symbol,
and metadata checks; it deliberately does not create, boot, or orchestrate a
simulator application.
