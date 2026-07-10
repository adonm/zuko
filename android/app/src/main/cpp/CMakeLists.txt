cmake_minimum_required(VERSION 3.22.1)
project(zuko_terminal C)

set(GHOSTTY_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/../../../../native/ghostty/${ANDROID_ABI}")
set(GHOSTTY_ARCHIVE "${GHOSTTY_PREFIX}/lib/libghostty-vt.a")

if(NOT EXISTS "${GHOSTTY_ARCHIVE}")
    message(FATAL_ERROR
        "Missing ${GHOSTTY_ARCHIVE}. Run 'mise run build-android-native' before Gradle.")
endif()

add_library(ghostty-vt STATIC IMPORTED)
set_target_properties(ghostty-vt PROPERTIES IMPORTED_LOCATION "${GHOSTTY_ARCHIVE}")

add_library(zuko_terminal SHARED zuko_terminal_jni.c)
target_compile_features(zuko_terminal PRIVATE c_std_11)
target_compile_definitions(zuko_terminal PRIVATE GHOSTTY_STATIC=1)
target_compile_options(zuko_terminal PRIVATE -Wall -Wextra -Werror)
target_include_directories(zuko_terminal PRIVATE "${GHOSTTY_PREFIX}/include")
target_link_libraries(zuko_terminal PRIVATE ghostty-vt log)
target_link_options(zuko_terminal PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384")
