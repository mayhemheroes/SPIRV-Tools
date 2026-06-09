#!/usr/bin/env bash
#
# Copyright (c) 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPIRV-Tools/mayhem/build.sh — fetch pinned deps, build the project + the libFuzzer harnesses
# (instrumented with $SANITIZER_FLAGS so the FUZZED code is sanitized), produce a standalone
# (non-fuzzer) reproducer per harness, and build SPIRV-Tools' own ctest suite with NORMAL flags.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/mayhemheroes/base) exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each libFuzzer harness)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g
#   STANDALONE_FUZZ_MAIN  LLVM run-once driver (C) for the standalone reproducers
#   SRC                 /mayhem (the repo source)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# value (--build-arg SANITIZER_FLAGS=) is honored and builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: explicit DWARF-3 so Mayhem triage can read symbols (clang-19 defaults to DWARF-5).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# 1) Fetch the pinned dependencies (spirv-headers is REQUIRED; effcee/re2/abseil/googletest are
#    needed for the test suite). git-sync-deps reads DEPS and checks each out at its pinned commit,
#    so this is hermetic given the network available at image-build time.
python3 utils/git-sync-deps

# 2) Build the PROJECT + the libFuzzer harnesses, instrumented with $SANITIZER_FLAGS so the fuzzed
#    code (not just the harness) is sanitized. We add libFuzzer coverage instrumentation to the
#    project compile flags (-fsanitize=fuzzer-no-link) and pass $LIB_FUZZING_ENGINE as the harness
#    LINK options via SPIRV_LIB_FUZZING_ENGINE_LINK_OPTIONS (the OSS-Fuzz integration point in
#    test/fuzzers/CMakeLists.txt). ENABLE_RTTI is required when UBSan's vptr check is on.
FUZZ_INSTR=""
case "$SANITIZER_FLAGS" in
  *fuzzer*) ;;                              # caller already asked for fuzzer instrumentation
  "") ;;                                    # sanitizers off -> no fuzzer coverage either
  *) FUZZ_INSTR="-fsanitize=fuzzer-no-link" ;;
esac

# UBSan's `nonnull-attribute` check fires on the well-known benign zero-length libc call
# `memcpy(dst, NULL, 0)` that spvtools_as_fuzzer makes on the empty input libFuzzer always tries
# first — aborting the harness on input #0 before it can fuzz. Drop ONLY that one UBSan sub-check
# (everything else in ASan+UBSan stays on and halting) so the harness fuzzes real inputs. Additive
# build-side fix; we do not touch the upstream harness or the base SANITIZER_FLAGS default.
SAN_COMPAT=""
case "$SANITIZER_FLAGS" in *undefined*) SAN_COMPAT="-fno-sanitize=nonnull-attribute" ;; esac

PROJECT_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $SAN_COMPAT $FUZZ_INSTR"

RTTI_ARG=""
case "$SANITIZER_FLAGS" in *undefined*) RTTI_ARG="-DENABLE_RTTI=ON" ;; esac

# NB: the libFuzzer targets live under test/fuzzers/, which test/CMakeLists.txt skips when
# SPIRV_SKIP_TESTS=ON — so we must leave tests enabled here for the harnesses to build. We build
# only the 7 fuzzer targets (not the whole gtest suite) so this stays fast. googletest must be
# present (fetched in step 1) for test/CMakeLists.txt to descend into fuzzers/.
cmake -G Ninja -B build -S . \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$PROJECT_FLAGS" -DCMAKE_CXX_FLAGS="$PROJECT_FLAGS" \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" \
  -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" \
  -DSPIRV_BUILD_LIBFUZZER_TARGETS=ON \
  -DSPIRV_LIB_FUZZING_ENGINE_LINK_OPTIONS="$LIB_FUZZING_ENGINE" \
  $RTTI_ARG
# Build the harness targets (and their library deps) only.
FUZZERS="spvtools_as_fuzzer \
         spvtools_binary_parser_fuzzer \
         spvtools_dis_fuzzer \
         spvtools_opt_legalization_fuzzer \
         spvtools_opt_performance_fuzzer \
         spvtools_opt_size_fuzzer \
         spvtools_val_fuzzer"
cmake --build build -j"$MAYHEM_JOBS" --target $FUZZERS

# CMake produces the libFuzzer harness binaries under build/test/fuzzers/. Copy them to /mayhem/.
for f in $FUZZERS; do
  cp "build/test/fuzzers/$f" "/mayhem/$f"
done

# 3) Standalone (non-fuzzer) reproducer per harness: harness + random_generator + LLVM run-once
#    main + the SPIRV-Tools static libs, no libFuzzer runtime. Compile the standalone main as C
#    first ($CC) so its LLVMFuzzerTestOneInput reference keeps C linkage (clang++ would mangle it).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

# Static libs produced by the build (full-visibility static lib + the opt lib for the opt fuzzers).
LIB_CORE="$(find build -name 'libSPIRV-Tools.a' | head -1)"
LIB_OPT="$(find build -name 'libSPIRV-Tools-opt.a' | head -1)"
INCS="-I$SRC -Iinclude -Ibuild -Iexternal/spirv-headers/include"
STD_CXX="$SANITIZER_FLAGS $DEBUG_FLAGS $SAN_COMPAT -std=c++17 -DSPIRV_CHECK_CONTEXT $INCS"

# Each harness: SRCS + random_generator.cpp, plus the opt common file for opt fuzzers.
build_standalone() {
  local target="$1" ; shift
  $CXX $STD_CXX "$@" test/fuzzers/random_generator.cpp \
    /tmp/standalone_main.o "$LIB_OPT" "$LIB_CORE" \
    -o "/mayhem/${target}-standalone"
}
build_standalone spvtools_as_fuzzer            test/fuzzers/spvtools_as_fuzzer.cpp
build_standalone spvtools_binary_parser_fuzzer test/fuzzers/spvtools_binary_parser_fuzzer.cpp
build_standalone spvtools_dis_fuzzer           test/fuzzers/spvtools_dis_fuzzer.cpp
build_standalone spvtools_val_fuzzer           test/fuzzers/spvtools_val_fuzzer.cpp
build_standalone spvtools_opt_legalization_fuzzer \
  test/fuzzers/spvtools_opt_legalization_fuzzer.cpp test/fuzzers/spvtools_opt_fuzzer_common.cpp
build_standalone spvtools_opt_performance_fuzzer \
  test/fuzzers/spvtools_opt_performance_fuzzer.cpp test/fuzzers/spvtools_opt_fuzzer_common.cpp
build_standalone spvtools_opt_size_fuzzer \
  test/fuzzers/spvtools_opt_size_fuzzer.cpp test/fuzzers/spvtools_opt_fuzzer_common.cpp

# 4) Build SPIRV-Tools' OWN ctest suite with NORMAL flags (independent of the sanitized build) so
#    mayhem/test.sh only RUNS it and stays an honest PATCH oracle. Needs effcee/re2/googletest
#    (fetched in step 1).
cmake -G Ninja -B build-tests -S . \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DSPIRV_SKIP_TESTS=OFF
cmake --build build-tests -j"$MAYHEM_JOBS"
