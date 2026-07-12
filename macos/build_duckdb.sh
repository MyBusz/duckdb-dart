#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "build_duckdb.sh: $*" >&2
  exit 1
}

assert_architectures() {
  local binary="$1"
  local actual
  actual="$(xcrun lipo -archs "$binary")"
  [[ " $actual " == *" x86_64 "* && " $actual " == *" arm64 "* ]] || \
    fail "$binary does not contain x86_64 and arm64 (found: $actual)"
  [[ $(wc -w <<<"$actual") -eq 2 ]] || fail "$binary has unexpected architectures: $actual"
}

assert_macho() {
  local binary="$1" architecture="$2" minimum="$3"
  local build_info
  build_info="$(xcrun vtool -show-build -arch "$architecture" "$binary")"
  grep -Eq 'platform[[:space:]]+MACOS([[:space:]]|$)' <<<"$build_info" || \
    fail "$binary ($architecture) has the wrong Mach-O platform"
  grep -Eq "minos[[:space:]]+$minimum(\.0)?([[:space:]]|$)" <<<"$build_info" || \
    fail "$binary ($architecture) has the wrong minimum macOS version"
  xcrun otool -D -arch "$architecture" "$binary" | grep -Fq '@rpath/libduckdb.dylib' || \
    fail "$binary ($architecture) has the wrong install name"
  xcrun nm -arch "$architecture" -gU "$binary" | grep -E '[[:space:]]_duckdb_open$' >/dev/null || \
    fail "$binary ($architecture) does not export duckdb_open"
  xcrun nm -arch "$architecture" -gU "$binary" | grep -E '[[:space:]]_duckdb_query$' >/dev/null || \
    fail "$binary ($architecture) does not export duckdb_query"
  assert_duckdb_symbols "$binary" "$architecture"
}

remove_signature() {
  local binary="$1"
  if codesign -dv "$binary" >/dev/null 2>&1; then
    codesign --remove-signature "$binary"
  fi
  if codesign -dv "$binary" >/dev/null 2>&1; then
    fail "$binary remains signed"
  fi
}

build_slice() {
  local architecture="$1" minimum="$2" explicit_platform="$3"
  local build_dir="$work_dir/build-$architecture"
  local configure_log="$work_dir/configure-$architecture.log"
  run_sanitized_cmake_configure \
    -S "$duckdb_source" \
    -B "$build_dir" \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$APPLE_CLANG" \
    -DCMAKE_CXX_COMPILER="$APPLE_CLANGXX" \
    -DCMAKE_MAKE_PROGRAM="$APPLE_NINJA" \
    -DCMAKE_TOOLCHAIN_FILE:FILEPATH= \
    -DCMAKE_C_COMPILER_LAUNCHER:STRING= \
    -DCMAKE_CXX_COMPILER_LAUNCHER:STRING= \
    -DCMAKE_C_FLAGS:STRING= \
    -DCMAKE_CXX_FLAGS:STRING= \
    -DCMAKE_EXE_LINKER_FLAGS:STRING= \
    -DCMAKE_MODULE_LINKER_FLAGS:STRING= \
    -DCMAKE_SHARED_LINKER_FLAGS:STRING= \
    -DCMAKE_OSX_SYSROOT=macosx \
    -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
    -DCMAKE_INSTALL_NAME_DIR=@rpath \
    -DDUCKDB_EXPLICIT_PLATFORM="$explicit_platform" \
    '-DBUILD_EXTENSIONS=icu;parquet;json' \
    -DBUILD_SHELL=OFF \
    -DBUILD_UNITTESTS=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_TESTING=OFF \
    -DEXTENSION_STATIC_BUILD=ON \
    -DENABLE_EXTENSION_AUTOLOADING=OFF \
    -DENABLE_EXTENSION_AUTOINSTALL=OFF \
    -DDISABLE_EXTENSION_LOAD=ON \
    -DLOCAL_EXTENSION_REPO= \
    -DSET_DUCKDB_LIBRARY_VERSION=OFF \
    -DOVERRIDE_GIT_DESCRIBE=v1.4.2 2>&1 | tee "$configure_log"
  assert_static_extensions_configured "$configure_log"
  assert_sanitized_cmake_cache "$build_dir" "$architecture" macosx "$minimum"
  grep -q 'CMAKE_CXX_COMPILER_ID "AppleClang"' \
    "$build_dir"/CMakeFiles/*/CMakeCXXCompiler.cmake || \
    fail "CMake did not select Apple Clang for $architecture"
  run_sanitized_cmake_build "$build_dir" --target duckdb --parallel "${JOBS:-3}"
  [[ -f "$build_dir/src/libduckdb.dylib" ]] || fail "DuckDB did not produce $architecture"
  assert_duckdb_symbols "$build_dir/src/libduckdb.dylib" "$architecture"
  cp "$build_dir/src/libduckdb.dylib" "$work_dir/libduckdb-$architecture.dylib"
}

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <expected-wrapper-source-commit-S> <output-directory>" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
duckdb_source="$repo_root/vendor/duckdb"
source "$repo_root/ios/apple_build_common.sh"
assert_pristine_release_sources "$1"
capture_and_validate_apple_tools
output_dir="$(prepare_fresh_output_directory "$2")"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/duckdb-macos.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

build_slice x86_64 10.15 osx_amd64
build_slice arm64 11.0 osx_arm64

universal="$work_dir/package/libduckdb.dylib"
mkdir -p "$(dirname "$universal")"
xcrun lipo -create \
  "$work_dir/libduckdb-x86_64.dylib" \
  "$work_dir/libduckdb-arm64.dylib" \
  -output "$universal"
xcrun install_name_tool -id '@rpath/libduckdb.dylib' "$universal"
chmod 755 "$universal"
remove_signature "$universal"

assert_architectures "$universal"
assert_macho "$universal" x86_64 10.15
assert_macho "$universal" arm64 11.0

smoke_binary="$work_dir/duckdb-macos-smoke"
macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
"$APPLE_CLANG" -std=c11 -Wall -Wextra -Werror \
  -isysroot "$macos_sdk" \
  -arch x86_64 \
  -mmacosx-version-min=10.15 \
  -I"$duckdb_source/src/include" \
  "$script_dir/smoke_duckdb.c" \
  -o "$smoke_binary"
"$smoke_binary" "$universal"

archive="$output_dir/duckdb-macos-universal.zip"
python3 "$repo_root/ios/create_contract_zip.py" \
  "$archive" \
  "$work_dir/package" \
  libduckdb.dylib

echo "Created $archive"
