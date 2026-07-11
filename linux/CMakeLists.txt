cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "dart_duckdb")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "dart_duckdb_plugin")

set(DUCKDB_LIBRARY
  "${CMAKE_CURRENT_SOURCE_DIR}/Libraries/release/libduckdb.so")
if(NOT EXISTS "${DUCKDB_LIBRARY}" OR IS_DIRECTORY "${DUCKDB_LIBRARY}")
  message(FATAL_ERROR
    "Missing prebootstrapped DuckDB library: ${DUCKDB_LIBRARY}\n"
    "Run the native artifact bootstrap install for target linux before the "
    "Flutter build. Plugin build hooks are intentionally offline.")
endif()

add_library(${PLUGIN_NAME} SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/include/dart_duckdb/dart_duckdb_plugin.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/dart_duckdb_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter PkgConfig::GTK)

# The Dart FFI layer opens libduckdb.so by name. Flutter installs every path in
# this list into the application's lib directory, whose rpath is $ORIGIN/lib.
set(dart_duckdb_bundled_libraries
  "${DUCKDB_LIBRARY}"
  PARENT_SCOPE
)
