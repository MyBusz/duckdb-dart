# Native artifact contract

This directory defines the shared DuckDB 1.4.2 native release contract. Native
builds produce five ZIP files. The bootstrap validates those ZIPs from a local
candidate directory or from the published immutable GitHub release, caches the
selected bytes, and installs exact members without downloading during a build.

## Release identity

- Repository: `MyBusz/duckdb-dart`
- Final tag: `native-duckdb-1.4.2-r1`
- Wrapper baseline: `9643f1116ccbc76f7aaf35da62014b49e963770d`
- DuckDB commit: `68d7555f68bd25c1a251ccca2e6338949c33986a`
- Flutter: `3.41.3`
- Dart: `3.11.1`
- Android NDK: `28.2.13676358`
- Static extensions: `icu`, `parquet`, `json`

The ordered native build-tool identity set is platform-qualified so different
runner tools are never collapsed into one ambiguous version: `android-cmake`,
`android-ninja`, `linux-cmake`, `linux-ninja`, `linux-clang`, `apple-cmake`,
`apple-ninja`, `xcode`, `apple-clang`, `windows-cmake`, `visual-studio`, and
`msvc`. Their exact hosted-runner versions are release data recorded in
`assets.lock.json`.

The `sourceCommit` in `assets.lock.json` is the reviewed wrapper source commit
`S` used to build every ZIP. It is based on the wrapper baseline above. Final
metadata is added after the ZIP lengths, checksums, and members are known.

## Exact seven assets

The immutable release contains exactly:

1. `duckdb-android-arm64-v8a-x86_64.zip`
2. `duckdb-ios-xcframework.zip`
3. `duckdb-macos-universal.zip`
4. `duckdb-linux-x86_64.zip`
5. `duckdb-windows-x64.zip`
6. `assets.lock.json`
7. `SHA256SUMS`

`SHA256SUMS` contains exactly six ordered entries: the five ZIPs followed by
`assets.lock.json`. It cannot contain an entry for itself.

## Lock metadata

`assets.lock.json` validates against `native-artifacts.schema.json`. It records
only the schema version, final tag, source and DuckDB commits, pinned Flutter,
Dart, Android NDK, and native build-tool versions, static extension set, and
the exact ordered native build tools, two license records, and five ordered
artifact records. The license records are exactly wrapper `LICENSE` (`MIT`) and
DuckDB `licenses/duckdb/LICENSE` (`MIT`). Each artifact
record contains its exact file name, byte size, SHA-256, supported
platform/architectures/minimum OS where applicable, and exact members. Each
member contains its archive path, byte size, SHA-256, and package-relative
install destination.

The fixed platform mapping is:

| Target | Required architectures | Install root |
| --- | --- | --- |
| Android | `arm64-v8a`, `x86_64`, API 21+ | `android/src/main/jniLibs` |
| iOS | device `arm64` 13.0+; simulator `arm64` 14.0+, `x86_64` 13.0+ | `ios/Libraries/release` |
| macOS | `x86_64` 10.15+; `arm64` 11.0+ | `macos/Libraries/release` |
| Linux | `x86_64` | `linux/Libraries/release` |
| Windows | `x64` | `windows/Libraries/release` |

The essential member set is `arm64-v8a/libduckdb.so` and
`x86_64/libduckdb.so` for Android; `duckdb.xcframework/Info.plist` plus the
device and simulator `duckdb.framework/duckdb` binaries for iOS;
`libduckdb.dylib` for macOS; `libduckdb.so` for Linux; and `duckdb.dll` for
Windows. Real packages may declare additional exact members after these
ordered essential members. Every declared member is verified and installed at
the fixed install root plus its unchanged archive path.

The iOS manifest uses three ordered platform records because simulator slices
have different encoded Mach-O minimum versions: device `arm64`/13.0, simulator
`arm64`/14.0, then simulator `x86_64`/13.0. The two simulator records describe
the architecture union in the single universal simulator XCFramework member;
its framework `MinimumOSVersion` is the conservative scalar aggregate 14.0.

Archive member paths and install destinations are normalized relative POSIX
paths. Absolute paths, drive paths, backslashes, empty segments, `.` and `..`
segments, duplicate paths, and destinations that do not equal the fixed install
root plus the member path are rejected.

## Candidate generation

Each hosted native job emits its ZIPs plus one strict metadata file named
`android-tools.json`, `linux-tools.json`, `apple-tools.json`, or
`windows-tools.json`. Metadata records the platform, source and DuckDB commits,
and that platform's exact tool identities in the order above. The generator
rejects missing, extra, duplicate, malformed, unknown, or source-mismatched
inputs and derives all archive/member sizes and SHA-256 values from bytes:

```sh
python3 tool/native_artifacts/generate_candidate.py generate \
  --input-dir /path/to/five-zips-and-four-tool-files \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --output-dir /path/to/new-seven-asset-candidate
```

`record-tools` is the workflow-facing companion. It requires the exact tools
for one platform as ordered `--tool NAME=VERSION` arguments. Candidate output is
created in a new directory and contains unchanged ZIP bytes plus deterministic
`assets.lock.json` and six-line `SHA256SUMS` files. The workflow then runs the
authoritative Dart `seed-local` bootstrap over those seven files.

Before Archive 4.0.9 sees any entry, the bootstrap performs a small ZIP-feature
preflight. It bounds and exactly parses the EOCD and central directory, rejects
EOCD archive comments, ZIP64 and multi-disk archives, validates every referenced
local header and compressed range, and enforces entry, size, ratio, required
ZIP version, method, flag, mode, path, collision, and local/central consistency
limits. Data descriptors are deliberately unsupported: every local header must
carry the same CRC and sizes as its central record. Member names are restricted
to normalized printable ASCII, an unambiguous UTF-8 subset. The central-header
creator version does not select a required producer or limit otherwise supported
ZIP features. Archive remains responsible for decompression; output is counted
and checked against CRC, SHA-256, and manifest sizes.

## Bootstrap commands

Run with the repository's pinned Dart SDK:

```bash
dart run tool/native_artifacts.dart seed-local \
  --release-dir /path/to/seven-assets \
  --cache-root /path/to/cache

dart run tool/native_artifacts.dart fetch \
  --target linux \
  --cache-root /path/to/cache

dart run tool/native_artifacts.dart verify-cache \
  --target linux \
  --cache-root /path/to/cache \
  --offline

dart run tool/native_artifacts.dart install \
  --target linux \
  --cache-root /path/to/cache \
  --package-root /path/to/duckdb-dart \
  --offline
```

`seed-local` verifies a local candidate and makes no statement about GitHub
release immutability. `fetch` asks GitHub CLI for the exact tag's
`isImmutable` field, requires the exact seven asset names, downloads only the
manifest, checksum file, and selected platform ZIP, and then performs the same
checksum/member validation before caching.

`verify-cache` and `install` make no downloader call. They revalidate cached
manifest identity, checksum coverage, ZIP size/SHA-256, exact member set, member
size/SHA-256, and safe install destinations. Cache and install updates use a
same-parent stage followed by rename, remove failed stages, and verify copied
output. Symlinked roots and path components are rejected.

Cache and package roots must be caller-owned directories that are not writable
by untrusted users. Temporary directories are uniquely created beneath those
roots and component types are rechecked immediately before writes and rename
promotion where portable Dart permits. Portable Dart cannot prevent a
concurrent same-user process from replacing filesystem components between
checks; shared roots exposed to such a process are unsupported.

Build hooks are offline consumers and remain outside this shared-contract
slice. They must fail when their exact installed files are absent or corrupt.

## Source documentation

Source licensing and origin records remain in `LICENSE`,
`THIRD_PARTY_NOTICES.md`, and `licenses/`. Native archives and installed native
files are generated materializations and are not committed or included in the
Pub archive.
