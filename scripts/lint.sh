#!/bin/sh
# Lints with the toolchain's swift-format using .swift-format rules.
set -eu
cd "$(dirname "$0")/.."
swift format lint --strict -r Sources Tests Package.swift
