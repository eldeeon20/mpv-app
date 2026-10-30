# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "rust_lib_pr_app")
project(${PROJECT_NAME} LANGUAGES CXX)

# RUST_PREBUILT=1: el workflow build-app NO compila Rust. Solo empaqueta la
# DLL que dejó el workflow rust-lib en windows/prebuilt/.
if(DEFINED ENV{RUST_PREBUILT} AND "$ENV{RUST_PREBUILT}" STREQUAL "1")
  set(PREBUILT_LIB "${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/rust_lib_pr_app.dll")
  if(NOT EXISTS "${PREBUILT_LIB}")
    message(FATAL_ERROR
      "RUST_PREBUILT=1 pero falta ${PREBUILT_LIB}. "
      "Corré primero el workflow 'rust-lib'.")
  endif()
  set(rust_lib_pr_app_bundled_libraries
    "${PREBUILT_LIB}"
    PARENT_SCOPE
  )
else()
  include("../cargokit/cmake/cargokit.cmake")
  apply_cargokit(${PROJECT_NAME} ../../../../../../rust rust_lib_pr_app "")

  # List of absolute paths to libraries that should be bundled with the plugin.
  # This list could contain prebuilt libraries, or libraries created by an
  # external build triggered from this build file.
  set(rust_lib_pr_app_bundled_libraries
    "${${PROJECT_NAME}_cargokit_lib}"
    PARENT_SCOPE
  )
endif()
