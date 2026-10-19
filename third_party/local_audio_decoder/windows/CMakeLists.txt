# Flutter tooling requires CMake 3.14 or later for Windows plugin packages.
cmake_minimum_required(VERSION 3.14)

project(local_audio_decoder LANGUAGES CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(local_audio_decoder_bundled_libraries
  $<TARGET_FILE:local_audio_decoder>
  PARENT_SCOPE
)
