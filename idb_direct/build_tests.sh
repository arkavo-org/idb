#!/bin/bash
# Build script for idb_direct tests

set -e

echo "Building idb_direct tests..."

# Ensure we're in the right directory
cd "$(dirname "$0")"

# Check if the static library exists
if [ ! -f "libidb_direct.a" ]; then
    echo "Error: libidb_direct.a not found. Please build it first."
    exit 1
fi

# Compiler flags
CFLAGS="-Wall -Wextra -g -O0 -framework Foundation -framework CoreGraphics"
LDFLAGS="-L. -lidb_direct"

# Build the minimal segfault reproduction test
echo "Building test_segfault_repro..."
clang $CFLAGS test_segfault_repro.m $LDFLAGS -o test_segfault_repro

# Build the comprehensive test suite
echo "Building test_connect_comprehensive..."
clang $CFLAGS test_connect_comprehensive.m $LDFLAGS -o test_connect_comprehensive

# Build the existing smoke test
if [ -f "idb_direct_test.m" ]; then
    echo "Building idb_direct_test..."
    clang $CFLAGS idb_direct_test.m $LDFLAGS -o idb_direct_test
fi

echo "Build complete!"
echo ""
echo "To run tests:"
echo "  1. Boot a simulator: xcrun simctl boot <device-udid>"
echo "  2. Run: ./test_segfault_repro"
echo "  3. Run: ./test_connect_comprehensive"