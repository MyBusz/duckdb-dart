# Native artifact contract

This directory defines the shared release contract for DuckDB 1.4.2 native
artifacts. Platform build implementations consume this contract; they do not
define or relax it.

## One release sequence

The following is the only permitted sequence. A tag is a Git reference to a
commit; tags do not contain release assets.

1. Finish and review all source, native-affecting logic, schemas, build code,
   and release automation. Call that reviewed source commit `S`, then create
   candidate tag `native-candidate-duckdb-1.4.2-r1` pointing exactly to `S`.
2. Build all five payload ZIPs from `S` into CI artifacts, not into a GitHub
   release. For each payload, generate its three required companions from the
   same build. No executable or native-affecting behavior may first appear
   after `S`.
3. Aggregate the five payloads and fifteen companions and verify that the set
   is complete, internally consistent, and built from `S`.
4. Create verifier commit `V` from `S`. Relative to `S`, `V` changes only
   `native/assets.lock.json` and `native/SHA256SUMS`. Neither file
   self-references `V`.
5. Create final tag `native-duckdb-1.4.2-r1` pointing exactly to `V`. Create
   one draft final release targeting `V`, then upload the exact assets built
   from `S`, plus the two verifier files from `V`, exactly once. Uploads must
   not clobber, rebuild, replace, or mutate any asset.
6. In parallel, every platform consumer validates the complete draft release
   set. Consumers must not use a partial set, a mutable upload session, or an
   independently rebuilt asset.
7. Publish the draft unchanged only after every checker passes. After
   publication, verify release immutability and the external attestations that
   bind the final tag and full verifier commit `V` to the verified assets.

## Exact release asset set

The release repository is `MyBusz/duckdb-dart`. The final release has exactly
22 assets: five payload ZIPs, three companions for each payload, and the two
verifier files. The payloads are:

| Target | Payload ZIP | Required architectures | Materialized install destination |
| --- | --- | --- | --- |
| Android | `duckdb-android-arm64-v8a-x86_64.zip` | `arm64-v8a`, `x86_64` in one archive | `android/src/main/jniLibs/arm64-v8a/libduckdb.so`; `android/src/main/jniLibs/x86_64/libduckdb.so` |
| iOS | `duckdb-ios-xcframework.zip` | device `arm64`; simulator `arm64`, `x86_64` | `ios/Libraries/release/duckdb.xcframework` |
| macOS | `duckdb-macos-universal.zip` | `arm64`, `x86_64` | `macos/Libraries/release/libduckdb.dylib` |
| Linux | `duckdb-linux-x86_64.zip` | `x86_64` | `linux/Libraries/release/libduckdb.so` |
| Windows | `duckdb-windows-x64.zip` | `x64` (`AMD64`) | `windows/Libraries/release/duckdb.dll` |

For each payload named `<payload>`, exactly these three companions exist:

- `<payload>.spdx.json`: the SPDX JSON SBOM document;
- `<payload>.provenance.intoto.jsonl`: the SLSA provenance attestation;
- `<payload>.sbom.intoto.jsonl`: the attestation for that SPDX document.

The remaining assets are `assets.lock.json` and `SHA256SUMS`. `SHA256SUMS`
contains exactly 21 entries: the five payloads, all fifteen companions, and
`assets.lock.json`. It does not contain an entry for itself. The release asset
list in `native/native-artifacts.schema.json` fixes every filename and order;
release verification rejects missing, extra, duplicate, or renamed assets.

## Manifest and relationship validation

`native/assets.lock.json` must validate against
`native/native-artifacts.schema.json`. Schema version 2 fixes the five ordered
targets, exact archive/member/install paths, companion filenames, structured
per-build variants, packaging steps, binary-inspection records, toolchains, and
compile/link flags. All recorded paths are normalized relative POSIX paths:
absolute and drive paths, backslashes, empty segments, `.`/`..` segments, NUL,
and traversal are forbidden.

The following equality and content checks are mandatory domain validation
because Draft 2020-12 JSON Schema cannot compare values at different instance
locations or inspect the contents of referenced blobs:

- candidate ref `refs/tags/native-candidate-duckdb-1.4.2-r1` resolves exactly
  to top-level `sourceCommit` (`S`), and the unmodified trusted signer workflow
  is `MyBusz/duckdb-dart/.github/workflows/native-build.yml` at `S`;
- each provenance `sourceRef` is that candidate ref; each provenance
  `sourceCommit` and source-material commit equals top-level `sourceCommit`;
  each source material names `MyBusz/duckdb-dart` and that same ref; and each
  DuckDB core material equals top-level `coreCommit`, exactly
  `68d7555f68bd25c1a251ccca2e6338949c33986a`;
- each provenance subject name and SHA-256 equal its payload filename and
  `archive.sha256`, and the verified in-toto/SLSA statement content agrees with
  every manifest provenance field rather than merely copying manifest data;
- each SBOM-attestation subject name and SHA-256 equal the same payload and
  payload SHA-256;
- each SBOM-attestation predicate names and hashes that payload's SPDX document;
- each SPDX document's described payload name and SHA-256 equal the archive,
  its source repository/commit/core commit equal the manifest, and its
  components/extensions describe that same payload, source, and exactly
  `icu`, `parquet`, and `json`;
- every member `installPath` has the exact target prefix and the bootstrap
  additionally correlates its suffix to the archive member `path`; and
- `SHA256SUMS` has exactly the coverage described above and every digest equals
  the corresponding release asset.

Signer identity, candidate-ref resolution, attestation verification, and all
cross-field comparisons are mandatory even when the JSON Schema accepts the
individual field shapes. A checker must not infer equality simply because two
independently valid values have the same type.

## ZIP preflight and extraction

Every payload ZIP is untrusted until the complete release and its attestations
pass verification. Before extracting any entry, the verifier must parse the
entire ZIP directory and require the entry path set to equal the artifact's
`members[*].path` set exactly. It rejects extra, missing, or duplicate entries,
including byte-distinct paths that collide under Unicode normalization or
case-insensitive comparison. Directory placeholder entries are not implicit
exceptions to the exact set.

Preflight also rejects absolute or drive paths, traversal, `.` or `..` path
segments, empty segments, backslashes, NUL, and paths that normalize to a
different value. Local headers and central-directory records must agree. Every
entry must be a regular file: symbolic links, hard links, devices, sockets,
FIFOs, and all other special file types are forbidden. Encrypted entries,
multi-disk archives, unsupported compression methods or ZIP features, and any
metadata the verifier cannot interpret safely are rejected rather than
ignored.

Expansion is bounded by both implementation-owned limits and the signed
manifest. The compressed archive byte count must equal `archive.size`; each
declared and streamed uncompressed entry size must equal its member `size`;
the total declared and streamed output must equal the sum of all member sizes.
The verifier additionally applies reviewed nonzero caps for compressed bytes,
per-entry bytes, total expanded bytes, entry count, and compression ratio.
Neither ZIP metadata nor the manifest may raise those caps. Extraction stops
and removes its staging directory on any counter, ratio, or disk-space
violation. Only a fully verified staging tree may be atomically materialized at
the fixed install destinations.

## Structured native build variants

Every `buildVariants` entry independently records the exact native options;
there is no artifact-wide bag of CMake `KEY=value` strings. Every variant has
target `duckdb`, configuration `Release`, source root `vendor/duckdb`, static
extensions `[icu, parquet, json]`, internal ICU enabled, and extension loading,
autoloading, and autoinstalling disabled. Shells, unit tests, and benchmarks are
disabled. Compile and link arrays are nonempty and unique, and the schema
allows only the exact reviewed, ordered flags for that target. A producer may
not append an unreviewed flag.

The exact ordered variants are:

| Target | Variant | Required target settings |
| --- | --- | --- |
| Android | `arm64-v8a` | system `Android`; ABI `arm64-v8a`; API `android-21`; NDK `28.2.13676358`; STL `c++_static` |
| Android | `x86_64` | system `Android`; ABI `x86_64`; API `android-21`; NDK `28.2.13676358`; STL `c++_static` |
| iOS | `device-arm64` | SDK `iphoneos`; architecture `arm64`; minimum iOS `13.0` |
| iOS | `simulator-arm64` | SDK `iphonesimulator`; architecture `arm64`; minimum iOS `13.0` |
| iOS | `simulator-x86_64` | SDK `iphonesimulator`; architecture `x86_64`; minimum iOS `13.0` |
| macOS | `x86_64` | SDK `macosx`; architecture `x86_64`; minimum macOS `10.15` |
| macOS | `arm64` | SDK `macosx`; architecture `arm64`; minimum macOS `11.0` |
| Linux | `x86_64` | system `Linux`; architecture `x86_64` |
| Windows | `x64` | system `Windows`; architecture `AMD64`; generator platform `x64` |

Both Android variants use the reviewed 16 KiB maximum/common page-size linker
flags. API 23, a second or conflicting API field, iOS 11, a mixed device and
simulator SDK variant, macOS 10.13, and an arm64 macOS 10.15 variant are invalid.

Toolchain arrays have exact target-specific tool names. Versions are numeric or
semver-like, not free-form descriptions; Android NDK remains exactly
`28.2.13676358`. The exact discovered tool versions are recorded in
`assets.lock.json` at `V`. Mandatory domain validation compares each recorded
version to the corresponding immutable constant in
`.github/workflows/native-build.yml` at `S`; a schema-valid version that differs
from the workflow constant is rejected.

## Apple packaging and binary inspection

iOS packaging has exactly two ordered steps: merge the two simulator variants
with `lipo`, then create the XCFramework from the device and merged simulator
frameworks. The root XCFramework `Info.plist` must contain exactly the recorded
library identifiers `ios-arm64` and `ios-arm64_x86_64-simulator`, their exact
architectures and library paths, platform `ios`, no device platform variant,
and simulator platform variant `simulator`.

The checker must inspect the actual Mach-O files, not trust names or plist
claims. The device binary contains exactly arm64 with `LC_BUILD_VERSION`
platform iOS and minimum 13.0. The simulator binary contains exactly arm64 and
x86_64, each with platform iOS Simulator and minimum 13.0. The schema's three
slice records must match those observations and the member paths. A simulator
slice labeled as device, a device slice labeled as simulator, an incomplete
XCFramework, or an extra/missing architecture fails validation.

macOS packaging records one `lipo` merge of x86_64 and arm64. Inspection of the
actual universal dylib must find exactly those slices. Their
`LC_BUILD_VERSION` platform is macOS; the x86_64 minimum is 10.15 and the arm64
minimum is 11.0. The manifest inspection records must equal the observed load
commands.

## Native build policy

- `icu`, `parquet`, and `json` are linked statically into every target.
- Extension autoload, extension autoinstall, and loadable extensions are
  disabled; internal ICU is enabled; shell, unit-test, and benchmark binaries
  are disabled.
- Bootstrap is an explicit command that completes before any platform build.
- Gradle, CMake, CocoaPods, and other build hooks are offline consumers. They
  never access the network and fail immediately when a required verified
  materialization is missing.

## Ownership and packaging

Shared-contract owners control `native/**`, root release metadata, bootstrap
entry points, and release verification. Platform owners control only their
assigned implementation under `android/**`, `ios/**`, `macos/**`, `linux/**`,
or `windows/**`; they must preserve this contract.

Native archives, extracted libraries, frameworks, and DLLs are generated
materializations. They must not be committed to Git or included in the Pub
archive. Source licensing remains packaged through `LICENSE`,
`THIRD_PARTY_NOTICES.md`, and `licenses/**`; vendored native source remains
excluded from the Pub archive.
