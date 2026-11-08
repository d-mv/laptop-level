#!/bin/sh
# Runs the tests with coverage and fails unless LaptopLevelCore is at 100%
# of regions, functions and lines. Hardware tests need the SPU accelerometer,
# so the gate only passes on a supported Mac.
set -eu
cd "$(dirname "$0")/.."
log=$(mktemp)
trap 'rm -f "$log"' EXIT
if ! swift test --enable-code-coverage >"$log" 2>&1; then
    grep -E "error|failed" "$log" || tail -40 "$log"
    exit 1
fi
grep -E "^\s+Executed [0-9]+ tests" "$log" | tail -1 | sed 's/^[[:space:]]*/tests: /'
binpath=$(swift build --show-bin-path)
bin="$binpath/laptop-levelPackageTests.xctest/Contents/MacOS/laptop-levelPackageTests"
prof="$binpath/codecov/default.profdata"
total=$(xcrun llvm-cov report "$bin" -instr-profile "$prof" Sources/LaptopLevelCore | awk '/^TOTAL/')
echo "$total" | awk '{print "coverage: regions " $4 "  functions " $7 "  lines " $10}'
echo "$total" | awk '{ if ($4 != "100.00%" || $7 != "100.00%" || $10 != "100.00%") exit 1 }' || {
    echo "coverage below 100% — see: xcrun llvm-cov show $bin -instr-profile $prof Sources/LaptopLevelCore -show-regions"
    exit 1
}
