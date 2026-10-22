#!/usr/bin/env bash

# Copyright 2025 The Kubernetes Authors.
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

# This script verifies if the golang linker is eliminating dead code in
# various components we care about, such as kube-apiserver, kubelet and others
# Usage: `hack/verify-deadcode-elimination.sh`.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_ROOT=$(dirname "${BASH_SOURCE[0]}")/..
cd "${SCRIPT_ROOT}"
COMPONENTS=("admission-controller" "recommender" "updater")
FAILED=false

# Install whydeadcode
go install github.com/aarzilli/whydeadcode@latest

# Prefer full path for running zeitgeist
WHYDEADCODE_BIN="$(which whydeadcode)"

for binary in "${COMPONENTS[@]}"; do
  echo "Processing ${binary} ..."
  pushd "pkg/${binary}"
  # Go 1.26 added the reflect.Type.Methods / reflect.Value.Methods iterators,
  # whose closures carry the linker's ReflectMethod attribute. With Go >= 1.26
  # they are reported for every binary here (also on unmodified upstream code),
  # together with the promoted reflect.Value methods of kube-openapi's
  # go-json-experiment addressableValue (which embeds reflect.Value).
  # Ignore traces rooted in those toolchain/dependency symbols only.
  output=$(GOLDFLAGS=-dumpdep go build -ldflags=-dumpdep -o "${binary}" 2>&1 | grep "\->" | ${WHYDEADCODE_BIN} 2>&1 \
    | awk 'BEGIN { RS = ""; ORS = "\n\n" } $1 !~ /\.Methods\.func1$/ && $1 !~ /go-json-experiment\/json\.\(?\*?addressableValue\)?\.Method(ByName)?$/')
  if [[ -n "$output" ]]; then
    echo "golang linker is not eliminating dead code in ${binary}, please check the trace output below:"
    echo "(NOTE: that there may be false positives, but the first trace should be a real issue)"
    echo "$output"
    FAILED=true
    FAILED_BINARIES+=("${binary}")
  fi

  # Find the binary and print its size
  echo "Finding ${binary} binary and checking its size:"
    ls -altrh "${binary}"
  echo ""
  popd
done

if [[ "$FAILED" == "true" ]]; then
  echo "Dead code elimination check failed for the following binaries:"
  for failed_binary in "${FAILED_BINARIES[@]}"; do
    echo "  - ${failed_binary}"
  done
  exit 1
fi
