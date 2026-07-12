#!/usr/bin/env bash
set -euo pipefail

readonly minimum_ios_device="13.0"
readonly minimum_ios_simulator_arm64="14.0"
readonly minimum_ios_simulator_x86_64="13.0"

fail() {
  echo "build_duckdb.sh: $*" >&2
  exit 1
}

assert_architectures() {
  local binary="$1"
  shift
  local actual
  actual="$(xcrun lipo -archs "$binary")"
  for architecture in "$@"; do
    [[ " $actual " == *" $architecture "* ]] || fail "$binary is missing $architecture (found: $actual)"
  done
  [[ $(wc -w <<<"$actual") -eq $# ]] || fail "$binary has unexpected architectures: $actual"
}

assert_macho() {
  local binary="$1" architecture="$2" platform="$3" minimum="$4" install_name="$5"
  local build_info
  if ! build_info="$(xcrun vtool -show-build -arch "$architecture" "$binary" 2>&1)"; then
    printf 'vtool -show-build output for %s (%s):\n%s\n' \
      "$binary" "$architecture" "$build_info" >&2
    fail "$binary ($architecture) could not be inspected with vtool"
  fi
  if [[ $(grep -Ec '^[[:space:]]*platform[[:space:]]+' <<<"$build_info") -ne 1 ]] || \
      ! grep -Eq "^[[:space:]]*platform[[:space:]]+$platform([[:space:]]|$)" <<<"$build_info"; then
    printf 'vtool -show-build output for %s (%s):\n%s\n' \
      "$binary" "$architecture" "$build_info" >&2
    fail "$binary ($architecture) has the wrong Mach-O platform"
  fi
  if [[ $(grep -Ec '^[[:space:]]*minos[[:space:]]+' <<<"$build_info") -ne 1 ]] || \
      ! grep -Eq "^[[:space:]]*minos[[:space:]]+$minimum(\.0)?([[:space:]]|$)" <<<"$build_info"; then
    printf 'vtool -show-build output for %s (%s):\n%s\n' \
      "$binary" "$architecture" "$build_info" >&2
    fail "$binary ($architecture) has the wrong minimum OS version"
  fi
  xcrun otool -D -arch "$architecture" "$binary" | grep -Fq "$install_name" || \
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
  local name="$1" sdk="$2" architecture="$3" minimum="$4" explicit_platform="$5"
  local build_dir="$work_dir/build-$name"
  local configure_log="$work_dir/configure-$name.log"
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
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
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
  assert_sanitized_cmake_cache "$build_dir" "$architecture" "$sdk" "$minimum"
  grep -q 'CMAKE_CXX_COMPILER_ID "AppleClang"' \
    "$build_dir"/CMakeFiles/*/CMakeCXXCompiler.cmake || \
    fail "CMake did not select Apple Clang for $name"
  run_sanitized_cmake_build "$build_dir" --target duckdb --parallel "${JOBS:-3}"
  [[ -f "$build_dir/src/libduckdb.dylib" ]] || fail "DuckDB did not produce $name"
  assert_duckdb_symbols "$build_dir/src/libduckdb.dylib" "$architecture"
  cp "$build_dir/src/libduckdb.dylib" "$work_dir/$name.dylib"
  xcrun install_name_tool -id '@rpath/duckdb.framework/duckdb' "$work_dir/$name.dylib"
  remove_signature "$work_dir/$name.dylib"
}

make_framework() {
  local destination="$1" platform_name="$2" minimum="$3" binary="$4"
  mkdir -p "$destination/Headers" "$destination/Modules"
  cp "$binary" "$destination/duckdb"
  chmod 755 "$destination/duckdb"
  cp "$duckdb_source/src/include/duckdb.h" "$destination/Headers/duckdb.h"
  cat >"$destination/Modules/module.modulemap" <<'MODULEMAP'
framework module duckdb {
  umbrella header "duckdb.h"
  export *
  module * { export * }
}
MODULEMAP
  cat >"$destination/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>duckdb</string>
  <key>CFBundleIdentifier</key><string>org.duckdb.duckdb</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>duckdb</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.4.2</string>
  <key>CFBundleVersion</key><string>1.4.2</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform_name</string></array>
  <key>MinimumOSVersion</key><string>$minimum</string>
</dict>
</plist>
PLIST
  plutil -lint "$destination/Info.plist" >/dev/null
}

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <expected-wrapper-source-commit-S> <output-directory>" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
duckdb_source="$repo_root/vendor/duckdb"
source "$script_dir/apple_build_common.sh"
assert_pristine_release_sources "$1"
capture_and_validate_apple_tools
require_tool plutil
output_dir="$(prepare_fresh_output_directory "$2")"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/duckdb-ios.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

build_slice device-arm64 iphoneos arm64 "$minimum_ios_device" osx_arm64
build_slice simulator-arm64 iphonesimulator arm64 "$minimum_ios_simulator_arm64" osx_arm64
build_slice simulator-x86_64 iphonesimulator x86_64 "$minimum_ios_simulator_x86_64" osx_amd64

frameworks="$work_dir/frameworks"
device_framework="$frameworks/device/duckdb.framework"
simulator_framework="$frameworks/simulator/duckdb.framework"
make_framework "$device_framework" iPhoneOS "$minimum_ios_device" "$work_dir/device-arm64.dylib"
make_framework "$simulator_framework" iPhoneSimulator "$minimum_ios_simulator_arm64" "$work_dir/simulator-arm64.dylib"
xcrun lipo -create \
  "$work_dir/simulator-arm64.dylib" \
  "$work_dir/simulator-x86_64.dylib" \
  -output "$simulator_framework/duckdb"
remove_signature "$simulator_framework/duckdb"

assert_architectures "$device_framework/duckdb" arm64
assert_architectures "$simulator_framework/duckdb" arm64 x86_64
assert_macho "$device_framework/duckdb" arm64 IOS "$minimum_ios_device" '@rpath/duckdb.framework/duckdb'
assert_macho "$simulator_framework/duckdb" arm64 IOSSIMULATOR "$minimum_ios_simulator_arm64" '@rpath/duckdb.framework/duckdb'
assert_macho "$simulator_framework/duckdb" x86_64 IOSSIMULATOR "$minimum_ios_simulator_x86_64" '@rpath/duckdb.framework/duckdb'

xcframework="$work_dir/package/duckdb.xcframework"
mkdir -p "$(dirname "$xcframework")"
xcodebuild -create-xcframework \
  -framework "$device_framework" \
  -framework "$simulator_framework" \
  -output "$xcframework"

python3 - \
  "$xcframework/Info.plist" \
  "$xcframework/ios-arm64/duckdb.framework/Info.plist" \
  "$xcframework/ios-arm64_x86_64-simulator/duckdb.framework/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as source:
    plist = plistlib.load(source)
libraries = {item["LibraryIdentifier"]: item for item in plist["AvailableLibraries"]}
expected = {
    "ios-arm64": ("ios", None, {"arm64"}),
    "ios-arm64_x86_64-simulator": ("ios", "simulator", {"arm64", "x86_64"}),
}
if set(libraries) != set(expected):
    raise SystemExit(f"unexpected XCFramework identifiers: {sorted(libraries)}")
for identifier, (platform, variant, architectures) in expected.items():
    item = libraries[identifier]
    if item.get("LibraryPath") != "duckdb.framework":
        raise SystemExit(f"wrong LibraryPath for {identifier}")
    if item.get("SupportedPlatform") != platform:
        raise SystemExit(f"wrong SupportedPlatform for {identifier}")
    if item.get("SupportedPlatformVariant") != variant:
        raise SystemExit(f"wrong SupportedPlatformVariant for {identifier}")
    if set(item.get("SupportedArchitectures", [])) != architectures:
        raise SystemExit(f"wrong SupportedArchitectures for {identifier}")
frameworks = {
    sys.argv[2]: ("iPhoneOS", "13.0"),
    sys.argv[3]: ("iPhoneSimulator", "14.0"),
}
for path, (platform, minimum) in frameworks.items():
    with open(path, "rb") as source:
        framework = plistlib.load(source)
    if framework.get("CFBundleSupportedPlatforms") != [platform]:
        raise SystemExit(f"wrong CFBundleSupportedPlatforms in {path}")
    if framework.get("MinimumOSVersion") != minimum:
        raise SystemExit(f"wrong MinimumOSVersion in {path}")
print("XCFramework identifiers, architectures, and framework minima verified")
PY

final_device="$xcframework/ios-arm64/duckdb.framework/duckdb"
final_simulator="$xcframework/ios-arm64_x86_64-simulator/duckdb.framework/duckdb"
assert_architectures "$final_device" arm64
assert_architectures "$final_simulator" arm64 x86_64
assert_macho "$final_device" arm64 IOS "$minimum_ios_device" '@rpath/duckdb.framework/duckdb'
assert_macho "$final_simulator" arm64 IOSSIMULATOR "$minimum_ios_simulator_arm64" '@rpath/duckdb.framework/duckdb'
assert_macho "$final_simulator" x86_64 IOSSIMULATOR "$minimum_ios_simulator_x86_64" '@rpath/duckdb.framework/duckdb'
[[ ! -e "$xcframework/ios-arm64/duckdb.framework/_CodeSignature" ]] || fail "device framework is signed"
[[ ! -e "$xcframework/ios-arm64_x86_64-simulator/duckdb.framework/_CodeSignature" ]] || fail "simulator framework is signed"

archive="$output_dir/duckdb-ios-xcframework.zip"
python3 "$script_dir/create_contract_zip.py" \
  "$archive" \
  "$work_dir/package" \
  duckdb.xcframework/Info.plist \
  duckdb.xcframework/ios-arm64/duckdb.framework/duckdb \
  duckdb.xcframework/ios-arm64_x86_64-simulator/duckdb.framework/duckdb \
  duckdb.xcframework/ios-arm64/duckdb.framework/Headers/duckdb.h \
  duckdb.xcframework/ios-arm64/duckdb.framework/Info.plist \
  duckdb.xcframework/ios-arm64/duckdb.framework/Modules/module.modulemap \
  duckdb.xcframework/ios-arm64_x86_64-simulator/duckdb.framework/Headers/duckdb.h \
  duckdb.xcframework/ios-arm64_x86_64-simulator/duckdb.framework/Info.plist \
  duckdb.xcframework/ios-arm64_x86_64-simulator/duckdb.framework/Modules/module.modulemap

echo "Created $archive"
