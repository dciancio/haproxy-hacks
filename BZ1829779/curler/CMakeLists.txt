cmake_minimum_required (VERSION 2.8.12)
project (CURLER)

enable_language(C)

set(CMAKE_MAKE_PROGRAM make)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(FindPkgConfig)
find_package(CURL REQUIRED)

add_executable (curler curler.c)
include_directories(${CURL_INCLUDE_DIR})
target_link_libraries(curler ${CURL_LIBRARIES} -lm)

message(STATUS "CMAKE_SYSTEM=${CMAKE_SYSTEM}")
message(STATUS "CMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}")
message(STATUS "CMAKE_SYSTEM_PROCESSOR=${CMAKE_SYSTEM_PROCESSOR}")
message(STATUS "CMAKE_GENERATOR=${CMAKE_GENERATOR}")
message(STATUS "CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}")
message(STATUS "CMAKE_C_COMPILER=${CMAKE_C_COMPILER}")
