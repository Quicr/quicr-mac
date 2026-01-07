#!/usr/bin/env bash
# Create a macOS framework from moxygen static libraries

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_PREFIX="${SCRIPT_DIR}/moxygen-install"
FRAMEWORK_NAME="Moxygen"
FRAMEWORK_DIR="${SCRIPT_DIR}/${FRAMEWORK_NAME}.framework"

echo "=== Creating ${FRAMEWORK_NAME}.framework ==="

# Check install exists
if [[ ! -d "${INSTALL_PREFIX}/lib" ]]; then
    echo "Error: ${INSTALL_PREFIX}/lib not found. Run build-moxygen.sh first."
    exit 1
fi

# Clean previous framework
rm -rf "${FRAMEWORK_DIR}"

# Create framework structure
mkdir -p "${FRAMEWORK_DIR}/Versions/A/Headers"
mkdir -p "${FRAMEWORK_DIR}/Versions/A/Resources"

# Create symlinks
ln -s A "${FRAMEWORK_DIR}/Versions/Current"
ln -s Versions/Current/Headers "${FRAMEWORK_DIR}/Headers"
ln -s Versions/Current/Resources "${FRAMEWORK_DIR}/Resources"
ln -s Versions/Current/${FRAMEWORK_NAME} "${FRAMEWORK_DIR}/${FRAMEWORK_NAME}"

# Combine all static libraries into one
echo "Combining static libraries..."
find "${INSTALL_PREFIX}/lib" -name "*.a" > /tmp/moxygen_libs.txt
libtool -static -o "${FRAMEWORK_DIR}/Versions/A/${FRAMEWORK_NAME}" $(cat /tmp/moxygen_libs.txt)
rm /tmp/moxygen_libs.txt

# Copy headers
echo "Copying headers..."
cp -R "${INSTALL_PREFIX}/include/"* "${FRAMEWORK_DIR}/Versions/A/Headers/"

# Create Info.plist
cat > "${FRAMEWORK_DIR}/Versions/A/Resources/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Moxygen</string>
    <key>CFBundleIdentifier</key>
    <string>com.moxygen.framework</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Moxygen</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

# Create module.modulemap for Swift interop
cat > "${FRAMEWORK_DIR}/Versions/A/Headers/module.modulemap" << 'MODULEMAP'
framework module Moxygen {
    umbrella header "Moxygen.h"
    export *
    module * { export * }
}
MODULEMAP

# Create umbrella header
cat > "${FRAMEWORK_DIR}/Versions/A/Headers/Moxygen.h" << 'UMBRELLA'
// Moxygen Framework Umbrella Header
#ifndef Moxygen_h
#define Moxygen_h

// Note: C++ headers cannot be directly imported into Swift.
// Use the Objective-C++ wrapper (MoxygenClientObjC) instead.

#endif /* Moxygen_h */
UMBRELLA

echo ""
echo "=== Framework created ==="
echo "Location: ${FRAMEWORK_DIR}"
echo ""
du -sh "${FRAMEWORK_DIR}"
echo ""
echo "To use in Xcode:"
echo "  1. Drag ${FRAMEWORK_NAME}.framework into your project"
echo "  2. Add to 'Frameworks, Libraries, and Embedded Content'"
echo "  3. Set 'Do Not Embed' (it's static)"
echo ""
echo "Build Settings needed:"
echo "  Framework Search Paths: \$(PROJECT_DIR)/dependencies"
echo "  Header Search Paths: \$(PROJECT_DIR)/dependencies/${FRAMEWORK_NAME}.framework/Headers"
echo ""
echo "Still need to link homebrew dependencies:"
echo "  -lglog -lgflags -lssl -lcrypto -levent -lboost_context -lboost_filesystem"
echo "  -lboost_program_options -lboost_regex -lboost_system -lboost_thread"
echo "  -lz -lzstd -llz4 -lsnappy -lsodium -lfmt"
echo ""
echo "And system frameworks:"
echo "  Security, CoreFoundation, SystemConfiguration, CoreServices"
