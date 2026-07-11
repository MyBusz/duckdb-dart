# Compatibility wrapper for direct CMake callers. build_android.sh validates the
# exact NDK revision and invokes the NDK toolchain file directly.
if(NOT DEFINED ENV{ANDROID_NDK_HOME})
  message(FATAL_ERROR "ANDROID_NDK_HOME must point to Android NDK 28.2.13676358")
endif()

set(ANDROID_PLATFORM android-21 CACHE STRING "Android minimum API" FORCE)
set(ANDROID_STL c++_static CACHE STRING "Android C++ runtime" FORCE)
set(ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES ON CACHE BOOL "16 KiB pages" FORCE)
set(CMAKE_SHARED_LINKER_FLAGS
    "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
    CACHE STRING "Shared-library linker flags" FORCE)

include("$ENV{ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake")
