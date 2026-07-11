# Optional toolchain for manual CMake invocation. build_duckdb.sh passes the
# same values directly so every device/simulator architecture has a clean cache.
set(CMAKE_SYSTEM_NAME iOS)

set(IOS_SDK "" CACHE STRING "iphoneos or iphonesimulator")
set(IOS_ARCHITECTURES "" CACHE STRING "One or more iOS architectures")

if(NOT IOS_SDK STREQUAL "iphoneos" AND
   NOT IOS_SDK STREQUAL "iphonesimulator")
    message(FATAL_ERROR "IOS_SDK must be iphoneos or iphonesimulator")
endif()
if(IOS_ARCHITECTURES STREQUAL "")
    message(FATAL_ERROR "IOS_ARCHITECTURES must be set")
endif()

set(CMAKE_OSX_SYSROOT "${IOS_SDK}" CACHE STRING "iOS SDK" FORCE)
set(CMAKE_OSX_ARCHITECTURES "${IOS_ARCHITECTURES}" CACHE STRING "iOS architectures" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "Minimum iOS version" FORCE)
