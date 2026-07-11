# Android native package

This directory builds DuckDB from the initialized `vendor/duckdb` submodule. It
does not clone source, download a native archive, or install tools. The build
requires these already-local tools:

- Android NDK `28.2.13676358`
- Android SDK CMake `3.22.1` and its Ninja executable
- Python 3.8+ and Git

Build both required API 21 ABIs and emit the release-contract archive:

```sh
./android/build_android.sh \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --output-dir /absolute/output/directory
```

`ANDROID_NDK_HOME` can select the NDK. `CMAKE`, `NINJA`, and `PYTHON` can select
the corresponding local executables; the script rejects a different NDK or
CMake version. The required `--source-commit` is the reviewed release source
commit S; `DUCKDB_DART_SOURCE_COMMIT` is the equivalent environment input. The
script requires wrapper HEAD to equal S and rejects wrapper or nested DuckDB
changes, including untracked and ignored DuckDB extension configuration. It
creates a fresh temporary build directory under `--work-dir` for every run;
`--jobs` limits parallel compilation. Prefer output and work directories outside
the source checkout.

The result is
`duckdb-android-arm64-v8a-x86_64.zip`, containing exactly:

- `arm64-v8a/libduckdb.so`
- `x86_64/libduckdb.so`

The validator creates and validates a same-directory unique temporary ZIP before
atomically replacing the final archive. It checks the ZIP feature subset,
ET_DYN/ELF architecture, power-of-two and congruent 16 KiB PT_LOAD alignment,
SONAME, dependencies, exported DuckDB C API symbols, and linked-extension/static
loader symbols in each packaged library. Build-tree extension checks are only
supplemental. DuckDB's `icu`, `parquet`, and `json` extensions are linked in;
runtime extension loading, autoloading, and autoinstalling are off.

Gradle reads only `src/main/jniLibs`. Before a Flutter/Gradle build, use the
repository native-artifact bootstrap to install the verified archive there.
The offline Gradle pre-build check parses `native/assets.lock.json` from the
plugin checkout, requires the exact Android artifact/member/destination mapping,
and verifies each installed library's byte size and SHA-256 before packaging. It
fails if metadata or libraries are absent or malformed and never attempts to
obtain native bytes itself.
