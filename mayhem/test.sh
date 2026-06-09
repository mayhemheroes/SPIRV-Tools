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
# SPIRV-Tools/mayhem/test.sh — RUN SPIRV-Tools' own ctest suite (built by mayhem/build.sh into
# build-tests/ with NORMAL flags) → CTRF. PATCH-grade oracle: after an agent patches the source,
# the grader rebuilds (build.sh) then runs this. This script only RUNS the pre-built tests.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

[ -d build-tests ] || { echo "missing build-tests/ — run mayhem/build.sh first" >&2; exit 2; }

# Run ctest. Summary line: "X% tests passed, Y tests failed out of Z".
out="$(ctest --test-dir build-tests --output-on-failure -j"$MAYHEM_JOBS" 2>&1)"; echo "$out"

total=$( printf '%s\n' "$out" | sed -n 's/.* failed out of \([0-9][0-9]*\).*/\1/p'        | tail -1)
failed=$(printf '%s\n' "$out" | sed -n 's/.*tests* passed, \([0-9][0-9]*\) tests* failed out of.*/\1/p' | tail -1)
: "${total:=0}" "${failed:=0}"
passed=$(( total - failed )); [ "$passed" -lt 0 ] && passed=0

emit_ctrf "cmake-ctest" "$passed" "$failed"
