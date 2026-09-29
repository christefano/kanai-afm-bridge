#!/bin/sh
# Builds ./kanai-afm-bridge with the Swift toolchain that ships with the Command Line Tools.
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 main.swift -o kanai-afm-bridge
echo "built $(pwd)/kanai-afm-bridge"
