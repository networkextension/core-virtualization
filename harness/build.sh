#!/bin/sh
# Compile and codesign the vzrun boot-bench harness.
# Requires macOS 13+ and the Virtualization entitlement (ad-hoc signing is enough).
set -eu
cd "$(dirname "$0")"
swiftc -O -framework Virtualization -o vzrun vzrun.swift
codesign -s - --entitlements vzrun.entitlements vzrun
echo "built + signed ./vzrun"
