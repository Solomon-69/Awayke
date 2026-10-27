#!/usr/bin/env bash
# Logic tests: compiles Logic.swift with the tests and runs them. Changes nothing on the Mac.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
swiftc -parse-as-library "$REPO/Logic.swift" "$REPO/tests/LogicTests.swift" -o "$OUT/logic-tests"
"$OUT/logic-tests"
rm -rf "$OUT"
