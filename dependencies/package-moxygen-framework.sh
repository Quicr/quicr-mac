#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2024
# SPDX-License-Identifier: BSD-2-Clause
#
# Package moxygen and all dependencies into a single framework/xcframework
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
BUILD_DIR="$SCRIPT_DIR/_moxygen_build"
INSTALL_DIR="$BUILD_DIR/installed"
FRAMEWORK_NAME="moxygen"
FRAMEWORK_IDENTIFIER="com.meta.moxygen"
OUTPUT_DIR="$SCRIPT_DIR"

# Parse arguments
CLEAN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            CLEAN=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Package moxygen into xcframework"
            echo ""
            echo "Options:"
            echo "  --clean    Remove existing framework before building"
            echo "  --help,-h  Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check that build exists
if [ ! -d "$INSTALL_DIR" ]; then
    echo "ERROR: Moxygen build not found at $INSTALL_DIR"
    echo "Run ./build-moxygen.sh first"
    exit 1
fi

echo "=== Packaging Moxygen Framework ==="
echo ""

# Temporary directory for combining libraries
WORK_DIR="$BUILD_DIR/framework_work"
if [ "$CLEAN" = true ] || [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
fi
mkdir -p "$WORK_DIR/objects"

# Collect all static libraries we need
# Exclude test/benchmark libraries
echo "Collecting static libraries..."

LIBS_TO_MERGE=()

# Core moxygen libraries
for lib in "$INSTALL_DIR"/moxygen/lib/*.a; do
    [ -f "$lib" ] && LIBS_TO_MERGE+=("$lib")
done

# Facebook stack libraries (folly, fizz, mvfst, wangle, proxygen)
for pkg in folly fizz mvfst wangle proxygen; do
    for lib in "$INSTALL_DIR/$pkg"/lib/*.a; do
        [ -f "$lib" ] && LIBS_TO_MERGE+=("$lib")
    done
done

# Required dependencies (being selective to avoid bloat)
# boost - only what's needed
for lib in \
    "$INSTALL_DIR"/boost-*/lib/libboost_context.a \
    "$INSTALL_DIR"/boost-*/lib/libboost_filesystem.a \
    "$INSTALL_DIR"/boost-*/lib/libboost_program_options.a \
    "$INSTALL_DIR"/boost-*/lib/libboost_regex.a \
    "$INSTALL_DIR"/boost-*/lib/libboost_system.a \
    "$INSTALL_DIR"/boost-*/lib/libboost_thread.a \
    "$INSTALL_DIR"/boost-*/lib/libboost_iostreams.a \
    ; do
    [ -f "$lib" ] && LIBS_TO_MERGE+=("$lib")
done

# Other required dependencies
for lib in \
    "$INSTALL_DIR"/double-conversion-*/lib/*.a \
    "$INSTALL_DIR"/fmt-*/lib/*.a \
    "$INSTALL_DIR"/gflags-*/lib/*.a \
    "$INSTALL_DIR"/glog-*/lib/*.a \
    "$INSTALL_DIR"/libevent-*/lib/libevent*.a \
    "$INSTALL_DIR"/libsodium-*/lib/*.a \
    "$INSTALL_DIR"/lz4-*/lib/*.a \
    "$INSTALL_DIR"/snappy-*/lib/*.a \
    "$INSTALL_DIR"/zstd-*/lib/*.a \
    "$INSTALL_DIR"/zlib-*/lib/*.a \
    "$INSTALL_DIR"/c-ares-*/lib/libcares.a \
    "$INSTALL_DIR"/openssl-*/lib/libssl.a \
    "$INSTALL_DIR"/openssl-*/lib/libcrypto.a \
    "$INSTALL_DIR"/liboqs-*/lib/*.a \
    "$INSTALL_DIR"/xz-*/lib/liblzma.a \
    ; do
    [ -f "$lib" ] && LIBS_TO_MERGE+=("$lib")
done

echo "Found ${#LIBS_TO_MERGE[@]} libraries to merge"

# Combine all static libraries directly using libtool
# This properly handles duplicate object file names within archives
echo "Creating combined static library..."
COMBINED_LIB="$WORK_DIR/lib${FRAMEWORK_NAME}.a"

# Use libtool -static to merge all archives directly
# This is the correct approach - no need to extract objects manually
echo "Merging ${#LIBS_TO_MERGE[@]} libraries with libtool..."
libtool -static -o "$COMBINED_LIB" "${LIBS_TO_MERGE[@]}"

COMBINED_SIZE=$(du -h "$COMBINED_LIB" | cut -f1)
echo "Combined library size: $COMBINED_SIZE"

# Collect headers
echo "Collecting headers..."
HEADERS_DIR="$WORK_DIR/include"
mkdir -p "$HEADERS_DIR"

# Copy moxygen headers from source (they're not installed by default)
# Preserve the directory structure including subdirectories (events/, util/, mlog/, etc.)
MOXYGEN_SRC="$BUILD_DIR/repos/github.com-facebookexperimental-moxygen.git"
if [ -d "$MOXYGEN_SRC/moxygen" ]; then
    echo "Copying moxygen headers with directory structure..."
    # Use rsync to preserve directory structure, only copying .h files
    mkdir -p "$HEADERS_DIR/moxygen"
    cd "$MOXYGEN_SRC"
    find moxygen -name "*.h" -type f | while read -r hfile; do
        destdir="$HEADERS_DIR/$(dirname "$hfile")"
        mkdir -p "$destdir"
        cp "$hfile" "$destdir/"
    done
    cd - > /dev/null
fi

# Copy required dependency headers
for pkg in folly fizz mvfst wangle proxygen; do
    if [ -d "$INSTALL_DIR/$pkg/include" ]; then
        cp -R "$INSTALL_DIR/$pkg/include/"* "$HEADERS_DIR/" 2>/dev/null || true
    fi
done

# Copy boost headers (required by folly)
BOOST_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "boost-*" | head -1)
if [ -d "$BOOST_DIR/include" ]; then
    echo "Copying boost headers from $BOOST_DIR..."
    cp -R "$BOOST_DIR/include/"* "$HEADERS_DIR/" 2>/dev/null || true
fi

# Copy glog headers (required by folly)
GLOG_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "glog-*" | head -1)
if [ -d "$GLOG_DIR/include" ]; then
    echo "Copying glog headers from $GLOG_DIR..."
    cp -R "$GLOG_DIR/include/"* "$HEADERS_DIR/" 2>/dev/null || true
fi

# Copy gflags headers
GFLAGS_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "gflags-*" | head -1)
if [ -d "$GFLAGS_DIR/include" ]; then
    echo "Copying gflags headers from $GFLAGS_DIR..."
    cp -R "$GFLAGS_DIR/include/"* "$HEADERS_DIR/" 2>/dev/null || true
fi

# Copy fmt headers
FMT_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "fmt-*" | head -1)
if [ -d "$FMT_DIR/include" ]; then
    echo "Copying fmt headers from $FMT_DIR..."
    cp -R "$FMT_DIR/include/"* "$HEADERS_DIR/" 2>/dev/null || true
fi

# Copy double-conversion headers
DC_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "double-conversion-*" | head -1)
if [ -d "$DC_DIR/include" ]; then
    echo "Copying double-conversion headers from $DC_DIR..."
    cp -R "$DC_DIR/include/"* "$HEADERS_DIR/" 2>/dev/null || true
fi

# Copy libevent headers
LIBEVENT_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "libevent-*" | head -1)
if [ -d "$LIBEVENT_DIR/include" ]; then
    echo "Copying libevent headers from $LIBEVENT_DIR..."
    cp -R "$LIBEVENT_DIR/include/"* "$HEADERS_DIR/" 2>/dev/null || true
fi

# Copy libsodium headers
SODIUM_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "libsodium-*" | head -1)
if [ -d "$SODIUM_DIR/include" ]; then
    echo "Copying libsodium headers from $SODIUM_DIR..."
    cp -R "$SODIUM_DIR/include/"* "$HEADERS_DIR/" 2>/dev/null || true
fi

# Copy openssl headers
OPENSSL_DIR=$(find "$INSTALL_DIR" -maxdepth 1 -type d -name "openssl-*" | head -1)
if [ -d "$OPENSSL_DIR/include" ]; then
    echo "Copying openssl headers from $OPENSSL_DIR..."
    cp -R "$OPENSSL_DIR/include/"* "$HEADERS_DIR/" 2>/dev/null || true
fi

# Create framework structure for macOS
echo "Creating framework structure..."
FRAMEWORK_DIR="$WORK_DIR/${FRAMEWORK_NAME}.framework"
mkdir -p "$FRAMEWORK_DIR/Versions/A/Headers"
mkdir -p "$FRAMEWORK_DIR/Versions/A/Resources"

# Copy library
cp "$COMBINED_LIB" "$FRAMEWORK_DIR/Versions/A/${FRAMEWORK_NAME}"

# Copy headers
cp -R "$HEADERS_DIR/"* "$FRAMEWORK_DIR/Versions/A/Headers/" 2>/dev/null || true

# Create Info.plist
cat > "$FRAMEWORK_DIR/Versions/A/Resources/Info.plist" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${FRAMEWORK_IDENTIFIER}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FRAMEWORK_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLISTEOF

# Create symbolic links
cd "$FRAMEWORK_DIR/Versions"
ln -sf A Current
cd "$FRAMEWORK_DIR"
ln -sf Versions/Current/Headers Headers
ln -sf Versions/Current/Resources Resources
ln -sf "Versions/Current/${FRAMEWORK_NAME}" "${FRAMEWORK_NAME}"

# Generate dSYM
echo "Generating dSYM..."
dsymutil "$FRAMEWORK_DIR/Versions/A/${FRAMEWORK_NAME}" -o "$WORK_DIR/${FRAMEWORK_NAME}.dSYM" 2>/dev/null || echo "  (dSYM generation skipped - static library)"

# Create xcframework (macOS only for now)
echo "Creating xcframework..."
XCFRAMEWORK="$OUTPUT_DIR/${FRAMEWORK_NAME}.xcframework"
rm -rf "$XCFRAMEWORK"

xcodebuild -create-xcframework \
    -framework "$FRAMEWORK_DIR" \
    -output "$XCFRAMEWORK"

echo ""
echo "=== Packaging Complete ==="
echo ""
echo "Created: $XCFRAMEWORK"
echo ""
echo "Framework contents:"
ls -la "$XCFRAMEWORK/"
echo ""
echo "To use in Xcode:"
echo "  1. Drag ${FRAMEWORK_NAME}.xcframework into your project"
echo "  2. Add to 'Frameworks, Libraries, and Embedded Content'"
echo "  3. Link against system frameworks: Security, SystemConfiguration"
echo ""

# Show size
XCFW_SIZE=$(du -sh "$XCFRAMEWORK" | cut -f1)
echo "Total xcframework size: $XCFW_SIZE"
