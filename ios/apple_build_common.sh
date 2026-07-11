#!/usr/bin/env bash

# Shared release gates for the iOS and macOS native builders. The caller must
# set repo_root and duckdb_source before invoking these functions.

readonly EXPECTED_DUCKDB_COMMIT="68d7555f68bd25c1a251ccca2e6338949c33986a"
readonly EXPECTED_DART_SYMBOL_COUNT=109

apple_fail() {
  printf 'apple native build: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || apple_fail "required tool is unavailable: $1"
}

assert_version_at_least() {
  local label="$1" value="$2" minimum_major="$3" minimum_minor="$4"
  [[ "$value" =~ ([0-9]+)\.([0-9]+) ]] || \
    apple_fail "could not parse $label version from: $value"
  local actual_major="${BASH_REMATCH[1]}" actual_minor="${BASH_REMATCH[2]}"
  ((actual_major > minimum_major || \
    (actual_major == minimum_major && actual_minor >= minimum_minor))) || \
    apple_fail "$label $minimum_major.$minimum_minor or newer is required; found $actual_major.$actual_minor"
}

capture_and_validate_apple_tools() {
  local tool
  for tool in cmake ninja git python3 xcodebuild xcrun codesign grep; do
    require_tool "$tool"
  done

  local cmake_line ninja_line xcode_output xcode_line clang_line python_version
  APPLE_CLANG="$(xcrun --find clang)"
  APPLE_CLANGXX="$(xcrun --find clang++)"
  APPLE_NINJA="$(command -v ninja)"
  [[ -x "$APPLE_CLANG" && -x "$APPLE_CLANGXX" ]] || \
    apple_fail "the selected Xcode command-line C/C++ compilers are unavailable"
  cmake_line="$(cmake --version | while IFS= read -r line; do printf '%s\n' "$line"; break; done)"
  ninja_line="$(ninja --version)"
  xcode_output="$(xcodebuild -version)"
  xcode_line="$(while IFS= read -r line; do printf '%s\n' "$line"; break; done <<<"$xcode_output")"
  clang_line="$("$APPLE_CLANG" --version | while IFS= read -r line; do printf '%s\n' "$line"; break; done)"
  python_version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')"

  # These are compatibility floors, not the final release identities. Phase V
  # records the exact versions printed by the hosted release build.
  assert_version_at_least "CMake" "$cmake_line" 3 20
  assert_version_at_least "Ninja" "$ninja_line" 1 10
  assert_version_at_least "Xcode" "$xcode_line" 14 0
  [[ "$clang_line" == *"Apple clang version"* ]] || \
    apple_fail "xcrun clang is not Apple Clang: $clang_line"
  assert_version_at_least "Apple Clang" "$clang_line" 14 0
  assert_version_at_least "Python" "$python_version" 3 10

  printf 'Tool: %s\n' "$cmake_line"
  printf 'Tool: Ninja %s\n' "$ninja_line"
  printf 'Tool: %s\n' "$xcode_line"
  while IFS= read -r line; do
    [[ "$line" == "$xcode_line" ]] || printf 'Tool: %s\n' "$line"
  done <<<"$xcode_output"
  printf 'Tool: %s\n' "$clang_line"
  printf 'Tool: Python %s\n' "$python_version"
}

run_sanitized_cmake_configure() {
  # CMake initializes compiler, flags, toolchain, and launcher cache entries from
  # these environment variables on the first configure. Release configuration
  # must only use the SDK/compiler/architecture/minimum values passed by us.
  env \
    -u CMAKE_TOOLCHAIN_FILE \
    -u CMAKE_GENERATOR \
    -u CMAKE_GENERATOR_INSTANCE \
    -u CMAKE_GENERATOR_PLATFORM \
    -u CMAKE_GENERATOR_TOOLSET \
    -u CMAKE_C_COMPILER_LAUNCHER \
    -u CMAKE_CXX_COMPILER_LAUNCHER \
    -u CMAKE_C_LINKER_LAUNCHER \
    -u CMAKE_CXX_LINKER_LAUNCHER \
    -u CC -u CXX -u CPP \
    -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
    -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u LIBRARY_PATH \
    -u SDKROOT -u MACOSX_DEPLOYMENT_TARGET -u ARCHFLAGS \
    -u AR -u AS -u LD -u NM -u RANLIB -u STRIP \
    -u CCACHE_DIR -u CCACHE_BASEDIR -u CCACHE_CONFIGPATH \
    -u CCACHE_PREFIX -u CCACHE_PATH -u CCACHE_COMPILERCHECK \
    -u SCCACHE_DIR -u SCCACHE_CACHE_SIZE -u SCCACHE_ERROR_LOG \
    -u SCCACHE_LOG -u SCCACHE_RECACHE \
    cmake "$@"
}

run_sanitized_cmake_build() {
  # Compiler include/library search variables are consulted while Ninja invokes
  # the compiler, so the build must use the same closed environment as configure.
  env \
    -u CMAKE_TOOLCHAIN_FILE \
    -u CMAKE_GENERATOR \
    -u CMAKE_GENERATOR_INSTANCE \
    -u CMAKE_GENERATOR_PLATFORM \
    -u CMAKE_GENERATOR_TOOLSET \
    -u CMAKE_C_COMPILER_LAUNCHER \
    -u CMAKE_CXX_COMPILER_LAUNCHER \
    -u CMAKE_C_LINKER_LAUNCHER \
    -u CMAKE_CXX_LINKER_LAUNCHER \
    -u CC -u CXX -u CPP \
    -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
    -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u LIBRARY_PATH \
    -u SDKROOT -u MACOSX_DEPLOYMENT_TARGET -u ARCHFLAGS \
    -u AR -u AS -u LD -u NM -u RANLIB -u STRIP \
    -u CCACHE_DIR -u CCACHE_BASEDIR -u CCACHE_CONFIGPATH \
    -u CCACHE_PREFIX -u CCACHE_PATH -u CCACHE_COMPILERCHECK \
    -u SCCACHE_DIR -u SCCACHE_CACHE_SIZE -u SCCACHE_ERROR_LOG \
    -u SCCACHE_LOG -u SCCACHE_RECACHE \
    cmake --build "$@"
}

assert_cmake_cache_entry() {
  local cache="$1" key="$2" expected="$3" line
  line="$(grep -E "^${key}(:[^=]*)?=" "$cache" || true)"
  [[ -n "$line" ]] || apple_fail "CMake cache is missing $key"
  [[ "$line" != *$'\n'* ]] || apple_fail "CMake cache has duplicate $key entries"
  [[ "${line#*=}" == "$expected" ]] || \
    apple_fail "CMake cache has unexpected $key: ${line#*=}"
}

assert_sanitized_cmake_cache() {
  local build_dir="$1" architecture="$2" sdk="$3" minimum="$4"
  local cache="$build_dir/CMakeCache.txt"
  [[ -f "$cache" ]] || apple_fail "CMake did not create a cache in $build_dir"

  assert_cmake_cache_entry "$cache" CMAKE_C_COMPILER "$APPLE_CLANG"
  assert_cmake_cache_entry "$cache" CMAKE_CXX_COMPILER "$APPLE_CLANGXX"
  assert_cmake_cache_entry "$cache" CMAKE_MAKE_PROGRAM "$APPLE_NINJA"
  assert_cmake_cache_entry "$cache" CMAKE_TOOLCHAIN_FILE ""
  assert_cmake_cache_entry "$cache" CMAKE_C_COMPILER_LAUNCHER ""
  assert_cmake_cache_entry "$cache" CMAKE_CXX_COMPILER_LAUNCHER ""
  assert_cmake_cache_entry "$cache" CMAKE_C_FLAGS ""
  assert_cmake_cache_entry "$cache" CMAKE_CXX_FLAGS ""
  assert_cmake_cache_entry "$cache" CMAKE_EXE_LINKER_FLAGS ""
  assert_cmake_cache_entry "$cache" CMAKE_MODULE_LINKER_FLAGS ""
  assert_cmake_cache_entry "$cache" CMAKE_SHARED_LINKER_FLAGS ""
  assert_cmake_cache_entry "$cache" CMAKE_OSX_ARCHITECTURES "$architecture"
  assert_cmake_cache_entry "$cache" CMAKE_OSX_SYSROOT "$sdk"
  assert_cmake_cache_entry "$cache" CMAKE_OSX_DEPLOYMENT_TARGET "$minimum"
}

assert_pristine_release_sources() {
  local expected_wrapper_commit="$1"
  [[ "$expected_wrapper_commit" =~ ^[0-9a-f]{40}$ ]] || \
    apple_fail "expected wrapper source commit S must be a full lowercase 40-character SHA"
  [[ "$(git -C "$repo_root" rev-parse --show-toplevel)" == "$repo_root" ]] || \
    apple_fail "repository root could not be verified"

  local wrapper_head wrapper_status duckdb_head duckdb_status gitlink_commit
  wrapper_head="$(git -C "$repo_root" rev-parse HEAD)"
  [[ "$wrapper_head" == "$expected_wrapper_commit" ]] || \
    apple_fail "wrapper HEAD is $wrapper_head; expected source commit S $expected_wrapper_commit"
  wrapper_status="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all --ignore-submodules=none)"
  [[ -z "$wrapper_status" ]] || \
    apple_fail "wrapper checkout has tracked, staged, untracked, or dirty-submodule changes"

  [[ -f "$duckdb_source/CMakeLists.txt" ]] || \
    apple_fail "vendor/duckdb is not initialized"
  duckdb_head="$(git -C "$duckdb_source" rev-parse HEAD)"
  [[ "$duckdb_head" == "$EXPECTED_DUCKDB_COMMIT" ]] || \
    apple_fail "DuckDB HEAD is $duckdb_head; expected $EXPECTED_DUCKDB_COMMIT"
  gitlink_commit="$(git -C "$repo_root" ls-tree HEAD vendor/duckdb | while read -r _type _mode commit _path; do printf '%s\n' "$commit"; done)"
  [[ "$gitlink_commit" == "$EXPECTED_DUCKDB_COMMIT" ]] || \
    apple_fail "wrapper commit does not pin DuckDB $EXPECTED_DUCKDB_COMMIT"

  # --ignored=matching deliberately rejects ignored extension_config_local.cmake,
  # external extension sources, and ignored build/configuration material too.
  duckdb_status="$(git -C "$duckdb_source" status --porcelain=v1 --untracked-files=all --ignored=matching)"
  [[ -z "$duckdb_status" ]] || \
    apple_fail "DuckDB checkout has tracked, staged, untracked, or ignored files"

  printf 'Wrapper source S: %s\nDuckDB source: %s\n' "$wrapper_head" "$duckdb_head"
}

prepare_fresh_output_directory() {
  local requested="$1"
  [[ -n "$requested" ]] || apple_fail "output directory is required"
  if [[ -e "$requested" && ! -d "$requested" ]] || [[ -L "$requested" ]]; then
    apple_fail "output path must be a real directory"
  fi
  mkdir -p "$requested"
  local absolute
  absolute="$(cd "$requested" && pwd -P)"
  local -a contents
  shopt -s nullglob dotglob
  contents=("$absolute"/*)
  shopt -u nullglob dotglob
  ((${#contents[@]} == 0)) || apple_fail "output directory must be fresh and empty: $absolute"
  printf '%s\n' "$absolute"
}

assert_static_extensions_configured() {
  local configure_log="$1" linked_line extension
  linked_line="$(grep 'Extensions linked into DuckDB:' "$configure_log" || true)"
  [[ -n "$linked_line" ]] || apple_fail "CMake did not report statically linked extensions"
  for extension in icu parquet json; do
    [[ "$linked_line" =~ (^|[^[:alnum:]_])$extension([^[:alnum:]_]|$) ]] || \
      apple_fail "CMake did not report $extension as statically linked"
  done
}

required_dart_symbols() {
  python3 - "$repo_root" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
symbols = {"duckdb_library_version", "duckdb_open"}
for source in (root / "lib" / "src" / "ffi" / "impl").rglob("*.dart"):
    symbols.update(re.findall(r"\.(duckdb_[a-z0-9_]+)\s*\(", source.read_text(encoding="utf-8")))
if len(symbols) < 80:
    raise SystemExit("Dart FFI symbol discovery produced an implausibly small set")
print("\n".join(sorted(symbols)))
PY
}

assert_duckdb_symbols() {
  local binary="$1" architecture="$2" required_symbols symbol_status=0 symbol_count
  required_symbols="$(required_dart_symbols)" || symbol_status=$?
  ((symbol_status == 0)) || \
    apple_fail "Dart FFI symbol derivation failed with status $symbol_status"
  [[ -n "$required_symbols" ]] || apple_fail "Dart FFI symbol derivation returned no symbols"
  symbol_count="$(grep -c '^' <<<"$required_symbols")"
  ((symbol_count == EXPECTED_DART_SYMBOL_COUNT)) || \
    apple_fail "Dart FFI symbol derivation returned $symbol_count symbols; expected $EXPECTED_DART_SYMBOL_COUNT"

  local exports symbol count=0
  exports="$(xcrun nm -arch "$architecture" -gU "$binary")"
  while IFS= read -r symbol; do
    grep -Eq "[[:space:]]_${symbol}$" <<<"$exports" || \
      apple_fail "$binary ($architecture) does not export required Dart FFI symbol $symbol"
    ((count += 1))
  done <<<"$required_symbols"
  printf 'Verified %d Dart FFI C API exports in %s (%s)\n' "$count" "$binary" "$architecture"

  local all_symbols visible_init=0 extension
  all_symbols="$(xcrun nm -arch "$architecture" "$binary")"
  for extension in icu json parquet; do
    if grep -Eq "[[:space:]]_${extension}_duckdb_cpp_init$" <<<"$all_symbols"; then
      ((visible_init += 1))
    fi
  done
  printf 'Observed %d visible ICU/JSON/Parquet init symbols in %s (%s); the CMake link report is authoritative\n' \
    "$visible_init" "$binary" "$architecture"

  if grep -q 'LoadStaticExtension' <<<"$all_symbols"; then
    printf 'Observed visible static-loader symbols in %s (%s)\n' "$binary" "$architecture"
  fi
}
