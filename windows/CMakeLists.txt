cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "dart_duckdb")
project(${PROJECT_NAME} LANGUAGES CXX)

cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "dart_duckdb_plugin")

list(APPEND PLUGIN_SOURCES
  "dart_duckdb_plugin.cpp"
  "dart_duckdb_plugin.h"
)

add_library(${PLUGIN_NAME} SHARED
  "include/dart_duckdb/dart_duckdb_plugin_c_api.h"
  "dart_duckdb_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

set(DUCKDB_DLL "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/release/duckdb.dll")
if(NOT EXISTS "${DUCKDB_DLL}" OR IS_DIRECTORY "${DUCKDB_DLL}")
  message(FATAL_ERROR
    "Missing prebootstrapped DuckDB library: ${DUCKDB_DLL}\n"
    "Run the native artifact bootstrap install for target windows before the "
    "Flutter build. Plugin build hooks are intentionally offline.")
endif()

# The plugin does not reference DuckDB at link time; Dart FFI loads duckdb.dll
# by name. Consequently no import library is required in the release package.
set(dart_duckdb_bundled_libraries
  "${DUCKDB_DLL}"
  PARENT_SCOPE
)
