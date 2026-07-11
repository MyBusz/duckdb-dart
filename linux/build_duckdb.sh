#!/usr/bin/env bash

set -euo pipefail

readonly EXPECTED_DUCKDB_COMMIT="68d7555f68bd25c1a251ccca2e6338949c33986a"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly SOURCE_DIR="${REPOSITORY_ROOT}/vendor/duckdb"
readonly BUILD_ROOT="${SCRIPT_DIR}/.build"
readonly BUILD_DIR="${BUILD_ROOT}/release"
readonly STAGE_DIR="${BUILD_ROOT}/stage"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "required tool not found: $1"
}

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
  fail "usage: $0 EXPECTED_WRAPPER_COMMIT OUTPUT_DIRECTORY"
fi

expected_wrapper_commit="$1"
output_dir="$2"
[[ "${expected_wrapper_commit}" =~ ^[0-9a-f]{40}$ ]] ||
  fail "EXPECTED_WRAPPER_COMMIT must be a lowercase 40-character Git commit"

require_tool git
require_tool cmake
require_tool ninja
require_tool python3
require_tool readelf
require_tool nm

[[ "$(uname -m)" == "x86_64" ]] || fail "Linux build host must be x86_64"
[[ -r /etc/os-release ]] || fail "Linux release baseline requires /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]] ||
  fail "Linux releases require the GitHub-hosted ubuntu-22.04 baseline; found ${ID:-unknown} ${VERSION_ID:-unknown}"

require_tool clang-14
require_tool clang++-14
clang_version="$(clang-14 --version | while IFS= read -r line; do printf '%s\n' "${line}"; break; done)"
clangxx_version="$(clang++-14 --version | while IFS= read -r line; do printf '%s\n' "${line}"; break; done)"
[[ "${clang_version}" =~ clang[[:space:]]version[[:space:]]14([.[:space:]]|$) ]] ||
  fail "Linux releases require Clang 14: ${clang_version}"
[[ "${clangxx_version}" =~ clang[[:space:]]version[[:space:]]14([.[:space:]]|$) ]] ||
  fail "Linux releases require Clang++ 14: ${clangxx_version}"
[[ "$(clang-14 -dumpmachine)" == x86_64-* ]] ||
  fail "Clang target must be x86_64, got $(clang-14 -dumpmachine)"

[[ -f "${SOURCE_DIR}/CMakeLists.txt" ]] || fail "pinned DuckDB submodule is absent"

actual_wrapper_commit="$(git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"
[[ "${actual_wrapper_commit}" == "${expected_wrapper_commit}" ]] ||
  fail "wrapper commit ${actual_wrapper_commit} does not match required ${expected_wrapper_commit}"
wrapper_changes="$(git -C "${REPOSITORY_ROOT}" status --porcelain=v1 --untracked-files=all --ignore-submodules=none)"
[[ -z "${wrapper_changes}" ]] ||
  fail "wrapper repository has tracked, staged, or untracked changes"

actual_commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
[[ "${actual_commit}" == "${EXPECTED_DUCKDB_COMMIT}" ]] ||
  fail "DuckDB commit ${actual_commit} does not match ${EXPECTED_DUCKDB_COMMIT}"
duckdb_changes="$(git -C "${SOURCE_DIR}" status --porcelain=v1 --untracked-files=all --ignored)"
[[ -z "${duckdb_changes}" ]] ||
  fail "DuckDB submodule has tracked, staged, untracked, or ignored changes"

cmake_version="$(cmake --version | while IFS= read -r line; do printf '%s\n' "${line}"; break; done)"
ninja_version="$(ninja --version)"
python_version="$(python3 --version 2>&1)"
[[ "${cmake_version}" =~ cmake\ version\ ([0-9]+)\.([0-9]+) ]] ||
  fail "could not parse CMake version: ${cmake_version}"
(( BASH_REMATCH[1] > 3 || (BASH_REMATCH[1] == 3 && BASH_REMATCH[2] >= 14) )) ||
  fail "CMake 3.14 or newer is required"
[[ "${ninja_version}" =~ ^([0-9]+)\.([0-9]+) ]] ||
  fail "could not parse Ninja version: ${ninja_version}"
(( BASH_REMATCH[1] > 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] >= 10) )) ||
  fail "Ninja 1.10 or newer is required"
printf 'Wrapper source: %s\n' "${actual_wrapper_commit}"
printf 'DuckDB source: %s\n' "${actual_commit}"
printf 'Baseline: GitHub-hosted ubuntu-22.04 x86_64\n'
printf 'Tool: %s\n' "${cmake_version}"
printf 'Tool: Ninja %s\n' "${ninja_version}"
printf 'Tool: %s\n' "${clang_version}"
printf 'Tool: %s\n' "${python_version}"

rm -rf -- "${BUILD_ROOT}"
mkdir -p -- "${BUILD_DIR}" "${STAGE_DIR}"

configure_log="${BUILD_DIR}/configure.log"
cmake -S "${SOURCE_DIR}" -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang-14 \
  -DCMAKE_CXX_COMPILER=clang++-14 \
  '-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -march=x86-64 -mtune=generic' \
  '-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -march=x86-64 -mtune=generic' \
  -DCMAKE_SKIP_RPATH=ON \
  -DBUILD_EXTENSIONS="icu;parquet;json" \
  -DEXTENSION_STATIC_BUILD=ON \
  -DBUILD_SHELL=OFF \
  -DBUILD_UNITTESTS=OFF \
  -DENABLE_UNITTEST_CPP_TESTS=OFF \
  -DDISABLE_EXTENSION_LOAD=ON \
  -DENABLE_EXTENSION_AUTOLOADING=OFF \
  -DENABLE_EXTENSION_AUTOINSTALL=OFF \
  -DNATIVE_ARCH=OFF \
  -DLOCAL_EXTENSION_REPO= \
  -DSET_DUCKDB_LIBRARY_VERSION=OFF \
  -DDUCKDB_EXPLICIT_PLATFORM=linux_amd64 \
  -DOVERRIDE_GIT_DESCRIBE=v1.4.2 2>&1 | tee "${configure_log}"

grep -q 'CMAKE_CXX_COMPILER_ID "Clang"' \
  "${BUILD_DIR}"/CMakeFiles/*/CMakeCXXCompiler.cmake ||
  fail "CMake did not select Clang for C++"
linked_line="$(grep 'Extensions linked into DuckDB:' "${configure_log}" || true)"
for extension in icu parquet json; do
  [[ "${linked_line}" =~ (^|[^[:alnum:]_])${extension}([^[:alnum:]_]|$) ]] ||
    fail "${extension} was not reported as statically linked"
done

cmake --build "${BUILD_DIR}" --target duckdb --parallel

library="${BUILD_DIR}/src/libduckdb.so"
[[ -f "${library}" && ! -L "${library}" ]] ||
  fail "expected regular shared library is absent: ${library}"
staged_library="${STAGE_DIR}/libduckdb.so"
cmake -E copy "${library}" "${staged_library}"
[[ -f "${staged_library}" && ! -L "${staged_library}" ]] ||
  fail "fresh staging copy is absent: ${staged_library}"

python3 "${SCRIPT_DIR}/validate_elf.py" "${staged_library}"

cat >"${BUILD_DIR}/inspect_duckdb.c" <<'EOF'
#include <duckdb.h>
#include <stdint.h>
#include <stdio.h>

static int query_int64(duckdb_connection connection, const char *sql,
                       int64_t expected) {
  duckdb_result result;
  if (duckdb_query(connection, sql, &result) == DuckDBError) {
    fprintf(stderr, "query failed: %s\n", duckdb_result_error(&result));
    duckdb_destroy_result(&result);
    return 1;
  }
  int failed = duckdb_row_count(&result) != 1 ||
               duckdb_value_int64(&result, 0, 0) != expected;
  duckdb_destroy_result(&result);
  return failed;
}

int main(void) {
  duckdb_database database = NULL;
  duckdb_connection connection = NULL;
  if (duckdb_open(NULL, &database) == DuckDBError ||
      duckdb_connect(database, &connection) == DuckDBError) {
    return 1;
  }
  int failed = query_int64(
      connection,
      "SELECT count(*) FROM duckdb_extensions() "
      "WHERE extension_name IN ('icu', 'parquet', 'json') AND loaded",
      3);
  failed |= query_int64(
      connection,
      "SELECT count(*) FROM duckdb_settings() WHERE "
      "(name = 'autoload_known_extensions' OR "
      " name = 'autoinstall_known_extensions') AND value = 'false'",
      2);
  duckdb_disconnect(&connection);
  duckdb_close(&database);
  return failed;
}
EOF

clang-14 -std=c11 -Wall -Wextra -Werror \
  -I"${SOURCE_DIR}/src/include" "${BUILD_DIR}/inspect_duckdb.c" \
  -L"${STAGE_DIR}" -lduckdb -o "${BUILD_DIR}/inspect_duckdb"
LD_LIBRARY_PATH="${STAGE_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
  "${BUILD_DIR}/inspect_duckdb"

mkdir -p -- "${output_dir}"
python3 "${SCRIPT_DIR}/package_zip.py" "${staged_library}" "${output_dir}"
printf 'Created %s/duckdb-linux-x86_64.zip\n' "$(cd -- "${output_dir}" && pwd -P)"
