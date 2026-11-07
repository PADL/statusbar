cmake_minimum_required(VERSION 3.31)
project(statusbar-umbrella LANGUAGES CXX)

# Unified build of every exported statusbar-* package as one CMake project. Each
# package still builds standalone; this umbrella sets STATUSBAR_AGGREGATE_BUILD
# so the per-package aggregate targets, install/export rules and find_package()
# calls defer to the shared ones created here.
set(STATUSBAR_AGGREGATE_BUILD ON)
include(CTest)

# The shared build machinery: cmake/module.cmake (a symlink into core/cmake, the
# single source of truth) defines statusbar_add_module, the package boilerplate
# helpers and — via its own guarded includes — the whole-build switches
# (ENABLE_NO_EXCEPTIONS, ENABLE_HARDENING, ENABLE_PACKET_QDISC_BYPASS; see
# core/cmake/build_switches.cmake) and the sanitizer/coverage/fuzzing/clang-tidy
# options. Included HERE, at the top scope, so the option modules' flag appends
# apply to every aggregated package. Standalone dependents get the very same
# file from find_package(statusbar-core) instead (installed, or staged in core's
# build tree); no toolchain includes it (toolchains are compiler selection
# only).
if(NOT COMMAND statusbar_register_fuzz_targets)
  include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/module.cmake)
endif()

define_property(
  GLOBAL
  PROPERTY STATUSBAR_TEST_FILES
  BRIEF_DOCS "test sources"
  FULL_DOCS "accumulated test sources")
set_property(GLOBAL PROPERTY STATUSBAR_TEST_FILES "")
define_property(
  GLOBAL
  PROPERTY STATUSBAR_INSTALL_TARGETS
  BRIEF_DOCS "install targets"
  FULL_DOCS "accumulated install targets")
set_property(GLOBAL PROPERTY STATUSBAR_INSTALL_TARGETS "")

# Discover every package directory up front: the four exported packages plus any
# nested extension — a private tree dropped into the umbrella (NOT a submodule)
# that looks like a statusbar package, i.e. a top-level CMakeLists.txt beside a
# statusbar/ module directory. This one _packages list drives the find_package()
# redirects, the add_subdirectory() calls and the aggregate header install
# below, so no later block carries its own copy of the package set. Sorted for a
# deterministic configure. The glob is evaluated at configure time only (no
# CONFIGURE_DEPENDS): after dropping in or removing a nested package, re-run
# cmake by hand.
set(_packages core crypto audio avb)
file(
  GLOB _extra_dirs
  RELATIVE "${CMAKE_SOURCE_DIR}"
  "${CMAKE_SOURCE_DIR}/*")
list(SORT _extra_dirs)
foreach(_d ${_extra_dirs})
  if(_d MATCHES "^(core|crypto|audio|avb)$")
    continue()
  endif()
  if(EXISTS "${CMAKE_SOURCE_DIR}/${_d}/CMakeLists.txt"
     AND IS_DIRECTORY "${CMAKE_SOURCE_DIR}/${_d}/statusbar")
    list(APPEND _packages ${_d})
  endif()
endforeach()

# Satisfy each package's find_package(statusbar-<dep>) from the in-tree build:
# write an empty redirect config that find_package() resolves before searching
# anywhere else (the mechanism FetchContent uses). Written for EVERY discovered
# package (package name convention: statusbar-<directory>), before any
# add_subdirectory(), so a nested extension may depend on the exported packages
# AND on sibling extensions.
foreach(_pkg ${_packages})
  file(WRITE
       "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}/statusbar-${_pkg}-config.cmake"
       "# satisfied in-tree by the statusbar-umbrella aggregate build\n")
endforeach()

# Shared aggregate targets — one each, replacing the per-package versions
# (guarded off when STATUSBAR_AGGREGATE_BUILD is set).
add_custom_target(run-all-benches)
add_library(statusbar INTERFACE)

# Packages in dependency order: the exported four first (the fixed head of
# _packages), then nested extensions in sorted order.
foreach(_pkg ${_packages})
  if(NOT _pkg MATCHES "^(core|crypto|audio|avb)$")
    message(STATUS "aggregate: including nested package ${_pkg}")
  endif()
  add_subdirectory(${_pkg})
endforeach()

# Populate the umbrella interface library once every module target exists.
# STATUSBAR_INSTALL_TARGETS accumulated every module's target, including tool
# executables — link only the library targets.
get_property(_all_targets GLOBAL PROPERTY STATUSBAR_INSTALL_TARGETS)
set(_lib_targets "")
foreach(_t ${_all_targets})
  if(TARGET ${_t})
    get_target_property(_t_type ${_t} TYPE)
    if(NOT _t_type STREQUAL "EXECUTABLE")
      list(APPEND _lib_targets ${_t})
    endif()
  endif()
endforeach()
if(_lib_targets)
  target_link_libraries(statusbar INTERFACE ${_lib_targets})
endif()

# Combined install — per-package install/export rules are deferred under
# STATUSBAR_AGGREGATE_BUILD, so `cmake --install` on this aggregate build
# installs every package's libraries, tools and headers under one prefix.
# Per-package find_package() configs and CPack archives are produced only by
# standalone package builds — build packages individually for those.
include(GNUInstallDirs)
install(
  TARGETS ${_all_targets}
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR} COMPONENT devel
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR} COMPONENT runtime
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR} COMPONENT runtime)
# Headers for every discovered package (see the _packages discovery above). The
# previous version iterated PACKAGE names ("statusbar-core") against a tree of
# DIRECTORY names ("core/"), so its IS_DIRECTORY guard was never true and the
# aggregate install silently shipped no headers at all. No guard here: _packages
# entries were validated at discovery (and the exported four always have
# statusbar/), so a missing directory should fail loudly, not skip.
foreach(_pkg ${_packages})
  install(
    DIRECTORY "${_pkg}/statusbar/"
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/statusbar
    COMPONENT devel
    FILES_MATCHING
    PATTERN "*.hpp"
    PATTERN "*.h")
endforeach()

# Single aggregate test binary built from every package's test sources.
# create_test_sourcelist derives each test's entry-function name from its path;
# the test sources define that name relative to their own package root, so strip
# the leading statusbar-<pkg>/ component to match.
get_property(STATUSBAR_TEST_FILES_ABS GLOBAL PROPERTY STATUSBAR_TEST_FILES)
set(STATUSBAR_TEST_FILES "")
foreach(TEST_FILE_ABS ${STATUSBAR_TEST_FILES_ABS})
  file(RELATIVE_PATH TEST_FILE_REL "${PROJECT_SOURCE_DIR}" "${TEST_FILE_ABS}")
  string(REGEX REPLACE "^[^/]+/(.*)" "\\1" TEST_FILE_REL "${TEST_FILE_REL}")
  list(APPEND STATUSBAR_TEST_FILES "${TEST_FILE_REL}")
endforeach()
list(SORT STATUSBAR_TEST_FILES)
if(STATUSBAR_TEST_FILES AND ENABLE_NO_EXCEPTIONS)
  message(
    STATUS "ENABLE_NO_EXCEPTIONS: skipping the aggregate statusbar_test binary "
           "(the test harness requires exceptions)")
endif()
if(STATUSBAR_TEST_FILES AND NOT ENABLE_NO_EXCEPTIONS)
  # With no arguments the binary runs every test (-A) instead of CMake's prompt
  # for a test number, which waits on stdin (statusbar/test/test_driver.hpp).
  create_test_sourcelist(
    STATUSBAR_TEST_SOURCES statusbar_test.cpp ${STATUSBAR_TEST_FILES}
    EXTRA_INCLUDE statusbar/test/test_driver.hpp
    FUNCTION statusbar::test::run_all_without_arguments)
  add_executable(statusbar_test ${CMAKE_CURRENT_BINARY_DIR}/statusbar_test.cpp
                                ${STATUSBAR_TEST_FILES_ABS})
  target_link_libraries(statusbar_test PRIVATE statusbar)
  foreach(TEST_FILE ${STATUSBAR_TEST_FILES})
    string(REPLACE ".cpp" "" TEST_NAME "${TEST_FILE}")
    add_test(NAME ${TEST_NAME} COMMAND statusbar_test ${TEST_NAME})
  endforeach()
  add_test(NAME statusbar_all_test COMMAND statusbar_test -A)
  # The -A run-all branch of CMake's create_test_sourcelist driver cannot fail:
  # it `return 0`s unconditionally, and it only prints "not ok" when a test
  # function returns -1 -- but TestRegister::run_section() returns 1. So the
  # aggregate run reported "ok" for failing sections and exited 0, making this a
  # permanently-green gate. Judge it by the harness's own output instead of the
  # driver's exit code: no FAIL: line, and the run must reach the end (so a
  # crash part-way through cannot pass either).
  set_tests_properties(
    statusbar_all_test
    PROPERTIES FAIL_REGULAR_EXPRESSION "FAIL: " PASS_REGULAR_EXPRESSION
               "All tests finished\\.")
  statusbar_register_coverage_targets(statusbar_test)
endif()

# Auto-discovering fuzz-smoke / fuzz-all targets (no-op unless ENABLE_FUZZING).
statusbar_register_fuzz_targets()

# Python crypto cross-validation target. Registered here (rather than from
# crypto/CMakeLists.txt) because avtp_crypto_tool is declared by avb, which is
# add_subdirectory()'d after crypto.
find_program(UV uv)
if(UV
   AND EXISTS
       ${CMAKE_CURRENT_SOURCE_DIR}/crypto/python/crypto/statusbar_crypto_test.py
   AND TARGET avtp_crypto_tool)
  set(_pycrypto "${CMAKE_CURRENT_SOURCE_DIR}/crypto/python/crypto")
  add_custom_target(
    python-crypto-tests
    COMMAND ${UV} run ${_pycrypto}/statusbar_crypto_test.py
    COMMAND ${UV} run ${_pycrypto}/avtp_crypto_cross_check.py --build-dir
            ${CMAKE_BINARY_DIR}
    DEPENDS avtp_crypto_tool
    COMMENT
      "Python crypto self-tests + cross-check against C++ avtp_crypto_tool"
    VERBATIM USES_TERMINAL)
endif()

# clang-tidy aggregate target (no-op unless clang-tidy is on PATH).
statusbar_register_clang_tidy_target()

# docs-sm: regenerate per-state-machine Markdown + SVG in each package's
# docs/sm/ tree (written into the source tree intentionally — the outputs are
# committed beside the SM definitions). Packages registered their SM tools +
# docs directories via statusbar_register_sm_doc() while their subdirectories
# configured; building the target from that registry means this file needs no
# knowledge of which package owns which tool. The include() takes this
# workspace's own module.cmake definition of the registry helpers, independent
# of whichever package copy loaded last.
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/module.cmake)
statusbar_register_sm_docs_target()
