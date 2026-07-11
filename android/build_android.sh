#!/usr/bin/env bash
set -euo pipefail

readonly DUCKDB_COMMIT="68d7555f68bd25c1a251ccca2e6338949c33986a"
readonly NDK_VERSION="28.2.13676358"
readonly CMAKE_VERSION="3.22.1"
readonly ARCHIVE_NAME="duckdb-android-arm64-v8a-x86_64.zip"
readonly -a ABIS=("arm64-v8a" "x86_64")

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    "Usage: $0 --source-commit COMMIT --output-dir DIR [--work-dir DIR] [--jobs COUNT]" \
    '       DUCKDB_DART_SOURCE_COMMIT=COMMIT may be used instead of --source-commit.'
}

assert_pristine_source() {
  local actual_commit wrapper_changes duckdb_changes pinned_duckdb_commit

  actual_commit="$(git -C "$repo_dir" rev-parse HEAD)"
  [[ "$actual_commit" == "$source_commit" ]] ||
    fail "wrapper HEAD is $actual_commit; expected source commit $source_commit"
  pinned_duckdb_commit="$(git -C "$repo_dir" rev-parse "$source_commit:vendor/duckdb")"
  [[ "$pinned_duckdb_commit" == "$DUCKDB_COMMIT" ]] ||
    fail "source commit pins DuckDB $pinned_duckdb_commit; expected $DUCKDB_COMMIT"

  wrapper_changes="$(
    git -C "$repo_dir" status --porcelain=v1 --untracked-files=all -- \
      . ':(exclude)vendor/duckdb'
  )"
  [[ -z "$wrapper_changes" ]] ||
    fail "wrapper source has tracked, staged, or untracked changes:${wrapper_changes//$'\n'/$'\n  '}"

  actual_commit="$(git -C "$duckdb_dir" rev-parse HEAD)"
  [[ "$actual_commit" == "$DUCKDB_COMMIT" ]] ||
    fail "DuckDB submodule is $actual_commit; expected $DUCKDB_COMMIT"
  duckdb_changes="$(
    git -C "$duckdb_dir" status --porcelain=v1 --ignored=matching --untracked-files=all
  )"
  [[ -z "$duckdb_changes" ]] ||
    fail "DuckDB source has tracked, staged, untracked, or ignored changes:${duckdb_changes//$'\n'/$'\n  '}"
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_dir="$(cd -- "$script_dir/.." && pwd -P)"
duckdb_dir="$repo_dir/vendor/duckdb"
output_dir=""
work_dir=""
jobs=""
source_commit="${DUCKDB_DART_SOURCE_COMMIT:-}"

while (($#)); do
  case "$1" in
    --source-commit)
      (($# >= 2)) || fail "--source-commit requires a value"
      if [[ -n "$source_commit" && "$source_commit" != "$2" ]]; then
        fail "--source-commit and DUCKDB_DART_SOURCE_COMMIT disagree"
      fi
      source_commit="$2"
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || fail "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --work-dir)
      (($# >= 2)) || fail "--work-dir requires a value"
      work_dir="$2"
      shift 2
      ;;
    --jobs)
      (($# >= 2)) || fail "--jobs requires a value"
      jobs="$2"
      [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || fail "--jobs must be a positive integer"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] ||
  fail "--source-commit or DUCKDB_DART_SOURCE_COMMIT must provide the expected 40-character source commit S"
[[ -n "$output_dir" ]] || fail "--output-dir is required"
[[ -f "$duckdb_dir/CMakeLists.txt" ]] || fail "missing initialized DuckDB submodule at $duckdb_dir"
command -v git >/dev/null 2>&1 || fail "git is required to validate the pinned source"
assert_pristine_source

mkdir -p -- "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd -P)"
if [[ -z "$work_dir" ]]; then
  work_dir="$output_dir/.android-work"
fi
mkdir -p -- "$work_dir"
work_dir="$(cd -- "$work_dir" && pwd -P)"
run_dir="$(mktemp -d "$work_dir/android-build.XXXXXX")"
trap 'rm -rf -- "$run_dir"' EXIT

ndk_dir=""
ndk_candidates=()
[[ -n "${ANDROID_NDK_HOME:-}" ]] && ndk_candidates+=("$ANDROID_NDK_HOME")
[[ -n "${ANDROID_NDK_ROOT:-}" ]] && ndk_candidates+=("$ANDROID_NDK_ROOT")
for sdk_root in \
  "${ANDROID_SDK_ROOT:-}" \
  "${ANDROID_HOME:-}" \
  "$HOME/Android/Sdk" \
  "$HOME/Library/Android/sdk"; do
  [[ -n "$sdk_root" ]] && ndk_candidates+=("$sdk_root/ndk/$NDK_VERSION")
done
for candidate in "${ndk_candidates[@]}"; do
  if [[ -f "$candidate/source.properties" ]]; then
    ndk_dir="$(cd -- "$candidate" && pwd -P)"
    break
  fi
done
[[ -n "$ndk_dir" ]] ||
  fail "Android NDK $NDK_VERSION is unavailable; set ANDROID_NDK_HOME to a local installation"

ndk_revision=""
while IFS='=' read -r key value; do
  key="${key//[[:space:]]/}"
  value="${value//[[:space:]]/}"
  if [[ "$key" == "Pkg.Revision" ]]; then
    ndk_revision="$value"
  fi
done < "$ndk_dir/source.properties"
[[ "$ndk_revision" == "$NDK_VERSION" ]] ||
  fail "Android NDK is $ndk_revision; expected $NDK_VERSION"

cmake_bin="${CMAKE:-}"
if [[ -n "$cmake_bin" ]]; then
  cmake_bin="$(command -v "$cmake_bin" || true)"
fi
if [[ -z "$cmake_bin" ]]; then
  for sdk_root in \
    "${ANDROID_SDK_ROOT:-}" \
    "${ANDROID_HOME:-}" \
    "$HOME/Android/Sdk" \
    "$HOME/Library/Android/sdk"; do
    if [[ -n "$sdk_root" && -x "$sdk_root/cmake/$CMAKE_VERSION/bin/cmake" ]]; then
      cmake_bin="$sdk_root/cmake/$CMAKE_VERSION/bin/cmake"
      break
    fi
  done
fi
[[ -n "$cmake_bin" && -x "$cmake_bin" ]] ||
  fail "CMake $CMAKE_VERSION is unavailable; install it in the Android SDK or set CMAKE"
actual_cmake_version="$("$cmake_bin" --version | while IFS= read -r line; do
  case "$line" in
    'cmake version '*) printf '%s\n' "${line#cmake version }"; break ;;
  esac
done)"
[[ "${actual_cmake_version%%-*}" == "$CMAKE_VERSION" ]] ||
  fail "CMake is $actual_cmake_version; expected $CMAKE_VERSION"

ninja_bin="${NINJA:-$(dirname -- "$cmake_bin")/ninja}"
if [[ -n "${NINJA:-}" ]]; then
  ninja_bin="$(command -v "$ninja_bin" || true)"
fi
[[ -x "$ninja_bin" ]] ||
  fail "Ninja is unavailable beside the pinned CMake; set NINJA to an executable"
python_bin="${PYTHON:-python3}"
python_bin="$(command -v "$python_bin" || true)"
[[ -x "$python_bin" ]] || fail "Python 3 is required for packaging and ELF validation"
python_version="$(
  "$python_bin" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
)"
python_major="${python_version%%.*}"
python_minor="${python_version#*.}"
if ((python_major != 3 || python_minor < 8)); then
  fail "Python 3.8 or newer is required; found $python_version"
fi

prebuilt_dir=""
for candidate in "$ndk_dir"/toolchains/llvm/prebuilt/*; do
  if [[ -x "$candidate/bin/llvm-strip" && \
        -x "$candidate/bin/llvm-readelf" && \
        -x "$candidate/bin/llvm-nm" ]]; then
    prebuilt_dir="$candidate"
    break
  fi
done
[[ -n "$prebuilt_dir" ]] || fail "the pinned NDK LLVM host toolchain is unavailable"

stage_dir="$run_dir/package"
mkdir -- "$stage_dir"

printf 'DuckDB: %s\nNDK: %s\nCMake: %s\nNinja: %s\n' \
  "$DUCKDB_COMMIT" "$ndk_revision" "$actual_cmake_version" "$("$ninja_bin" --version)"

for abi in "${ABIS[@]}"; do
  build_dir="$run_dir/$abi"
  library_dir="$stage_dir/$abi"
  mkdir -- "$build_dir" "$library_dir"

  "$cmake_bin" -S "$duckdb_dir" -B "$build_dir" -G Ninja \
    -DCMAKE_MAKE_PROGRAM:FILEPATH="$ninja_bin" \
    -DCMAKE_TOOLCHAIN_FILE:FILEPATH="$ndk_dir/build/cmake/android.toolchain.cmake" \
    -DCMAKE_BUILD_TYPE:STRING=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE:BOOL=ON \
    -DCMAKE_SHARED_LINKER_FLAGS:STRING='-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384' \
    -DANDROID_ABI:STRING="$abi" \
    -DANDROID_PLATFORM:STRING=android-21 \
    -DANDROID_STL:STRING=c++_static \
    -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES:BOOL=ON \
    -DBUILD_UNITTESTS:BOOL=OFF \
    -DBUILD_SHELL:BOOL=OFF \
    -DBUILD_EXTENSIONS:STRING='icu;parquet;json' \
    -DEXTENSION_STATIC_BUILD:BOOL=ON \
    -DDISABLE_EXTENSION_LOAD:BOOL=ON \
    -DENABLE_EXTENSION_AUTOLOADING:BOOL=OFF \
    -DENABLE_EXTENSION_AUTOINSTALL:BOOL=OFF \
    -DSET_DUCKDB_LIBRARY_VERSION:BOOL=OFF \
    -DOVERRIDE_GIT_DESCRIBE:STRING=v1.4.2 \
    -DDUCKDB_EXPLICIT_PLATFORM:STRING="android_$abi"

  build_command=("$cmake_bin" --build "$build_dir" --target duckdb)
  [[ -n "$jobs" ]] && build_command+=(--parallel "$jobs")
  "${build_command[@]}"

  library="$build_dir/src/libduckdb.so"
  [[ -f "$library" ]] || fail "DuckDB did not produce $library"
  "$prebuilt_dir/bin/llvm-strip" --strip-unneeded "$library"
  "$cmake_bin" -E copy "$library" "$library_dir/libduckdb.so"
done

assert_pristine_source

archive="$output_dir/$ARCHIVE_NAME"
"$python_bin" "$script_dir/validate_android.py" \
  --archive "$archive" \
  --ndk "$ndk_dir" \
  --build-root "$run_dir" \
  --library-root "$stage_dir" \
  --create

printf 'Created %s\n' "$archive"
