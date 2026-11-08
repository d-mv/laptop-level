#!/bin/sh
# Fails if any Swift file differs from `swift format` output. Fix with:
#   swift format format --in-place -r Sources Tests Package.swift
set -eu
cd "$(dirname "$0")/.."
bad=0
for f in Package.swift $(find Sources Tests -name '*.swift'); do
    if ! swift format format "$f" | cmp -s - "$f"; then
        echo "not formatted: $f"
        bad=1
    fi
done
[ "$bad" -eq 0 ] || { echo "run: swift format format --in-place -r Sources Tests Package.swift"; exit 1; }
