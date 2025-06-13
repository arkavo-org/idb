#!/bin/bash
# Build script for libidb_direct.a static library

set -e

echo "Building libidb_direct.a..."

# Ensure we're in the right directory
cd "$(dirname "$0")"

# Compiler flags
CFLAGS="-Wall -Wextra -g -O2 -fPIC -framework Foundation -framework CoreGraphics -fobjc-arc"

# Source files - using the adaptive version which includes the fix
SOURCES=(
    "idb_direct_real_adaptive.m"
)

# Object files
OBJECTS=()

# Compile each source file
for source in "${SOURCES[@]}"; do
    if [ -f "$source" ]; then
        object="${source%.m}.o"
        echo "Compiling $source..."
        clang -c $CFLAGS "$source" -o "$object"
        OBJECTS+=("$object")
    else
        echo "Warning: $source not found"
    fi
done

# Create the static library
echo "Creating static library..."
ar rcs libidb_direct.a "${OBJECTS[@]}"

# Create a thin library for the current architecture
echo "Creating architecture-specific library..."
lipo -create libidb_direct.a -output libidb_direct.a

# Clean up object files
rm -f "${OBJECTS[@]}"

echo "Build complete! Created libidb_direct.a"

# Show library info
echo ""
echo "Library info:"
lipo -info libidb_direct.a
echo ""
echo "Symbols:"
nm libidb_direct.a | grep " T " | head -10
echo "..."