# Flutter tooling requires CMake 3.10 or later for plugin packages.
cmake_minimum_required(VERSION 3.10)

project(local_audio_decoder_library VERSION 0.1.0 LANGUAGES C)

add_library(local_audio_decoder SHARED
  "local_audio_decoder.c"
)

set_target_properties(local_audio_decoder PROPERTIES
  PUBLIC_HEADER local_audio_decoder.h
  OUTPUT_NAME "local_audio_decoder"
)

target_compile_features(local_audio_decoder PRIVATE c_std_99)
target_compile_definitions(local_audio_decoder PUBLIC DART_SHARED_LIB)

if (ANDROID)
  target_link_options(local_audio_decoder PRIVATE "-Wl,-z,max-page-size=16384")
endif()
