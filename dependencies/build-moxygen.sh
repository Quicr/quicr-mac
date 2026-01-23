#!/usr/bin/env bash
# Build script for moxygen client library on macOS
# Builds moxygen and its dependencies using Facebook's getdeps.py

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOXYGEN_DIR="${SCRIPT_DIR}/moxygen"
INSTALL_PREFIX="${SCRIPT_DIR}/moxygen-install"
BUILD_TYPE="RelWithDebInfo"
NUM_JOBS=$(sysctl -n hw.ncpu)

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Build moxygen client library for macOS.

Options:
    --install-prefix PATH   Installation directory (default: ${INSTALL_PREFIX})
    --build-type TYPE       CMake build type: Debug, Release, RelWithDebInfo (default: ${BUILD_TYPE})
    --jobs N                Number of parallel jobs (default: ${NUM_JOBS})
    --install-deps          Install system dependencies via getdeps.py
    --clean                 Clean build artifacts before building
    --show-paths            Show build/install paths and exit
    -h, --help              Show this help message

Examples:
    $(basename "$0")                           # Build with defaults
    $(basename "$0") --install-deps            # Install deps first, then build
    $(basename "$0") --clean --build-type Release
    $(basename "$0") --show-paths              # Show where things are built
EOF
    exit 0
}

INSTALL_DEPS=false
CLEAN=false
SHOW_PATHS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --install-prefix)
            INSTALL_PREFIX="$2"
            shift 2
            ;;
        --build-type)
            BUILD_TYPE="$2"
            shift 2
            ;;
        --jobs)
            NUM_JOBS="$2"
            shift 2
            ;;
        --install-deps)
            INSTALL_DEPS=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --show-paths)
            SHOW_PATHS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

if [[ ! -d "${MOXYGEN_DIR}" ]]; then
    echo "Error: Moxygen directory not found at ${MOXYGEN_DIR}"
    echo "Make sure the moxygen submodule is initialized:"
    echo "  git submodule update --init --recursive"
    exit 1
fi

cd "${MOXYGEN_DIR}"

GETDEPS="${MOXYGEN_DIR}/build/fbcode_builder/getdeps.py"

if [[ ! -f "${GETDEPS}" ]]; then
    echo "Error: getdeps.py not found at ${GETDEPS}"
    exit 1
fi

# Query build paths
get_build_dir() {
    python3 "${GETDEPS}" show-build-dir --src-dir=. moxygen 2>/dev/null || echo ""
}

get_install_dir() {
    python3 "${GETDEPS}" show-inst-dir --src-dir=. moxygen 2>/dev/null || echo ""
}

# Show paths and exit if requested
if [[ "${SHOW_PATHS}" == "true" ]]; then
    echo "=== Moxygen Build Paths ==="
    echo "Source directory: ${MOXYGEN_DIR}"
    echo "Install prefix:   ${INSTALL_PREFIX}"
    BUILD_DIR=$(get_build_dir)
    INST_DIR=$(get_install_dir)
    if [[ -n "${BUILD_DIR}" ]]; then
        echo "Build directory:  ${BUILD_DIR}"
    fi
    if [[ -n "${INST_DIR}" ]]; then
        echo "Getdeps install:  ${INST_DIR}"
    fi
    exit 0
fi

echo "=== Moxygen Build Configuration ==="
echo "Moxygen source:   ${MOXYGEN_DIR}"
echo "Install prefix:   ${INSTALL_PREFIX}"
echo "Build type:       ${BUILD_TYPE}"
echo "Parallel jobs:    ${NUM_JOBS}"
echo "==================================="

# Install system dependencies if requested
if [[ "${INSTALL_DEPS}" == "true" ]]; then
    echo ""
    echo "=== Installing system dependencies ==="
    python3 "${GETDEPS}" install-system-deps --recursive moxygen
fi

# Clean if requested
if [[ "${CLEAN}" == "true" ]]; then
    echo ""
    echo "=== Cleaning build artifacts ==="
    python3 "${GETDEPS}" clean
    rm -rf "${INSTALL_PREFIX}"
fi

# Build moxygen and all dependencies
echo ""
echo "=== Building moxygen and dependencies ==="
echo "This may take a while on first build..."
echo ""

python3 "${GETDEPS}" build \
    --no-tests \
    --src-dir=. \
    moxygen \
    --project-install-prefix "moxygen:${INSTALL_PREFIX}"

# Copy artifacts to install prefix (this handles moxygen itself)
echo ""
echo "=== Copying build artifacts ==="
python3 "${GETDEPS}" fixup-dyn-deps \
    --src-dir=. \
    moxygen \
    "${INSTALL_PREFIX}" \
    --project-install-prefix "moxygen:${INSTALL_PREFIX}" \
    --final-install-prefix "${INSTALL_PREFIX}"

# Copy client libraries that aren't installed by CMake's install target
# (moxygenclient, moxygenserver, moxygenwtclient, moqfollyexecutorimpl)
BUILD_DIR=$(get_build_dir)
if [[ -n "${BUILD_DIR}" && -d "${BUILD_DIR}" ]]; then
    echo ""
    echo "=== Copying client libraries ==="
    mkdir -p "${INSTALL_PREFIX}/lib"

    # Copy all moxygen static libraries from build directory
    echo "  Copying moxygen libraries..."
    find "${BUILD_DIR}/moxygen" -name "*.a" -exec cp {} "${INSTALL_PREFIX}/lib/" \;
    ls "${INSTALL_PREFIX}/lib/"lib*.a 2>/dev/null | wc -l | xargs -I{} echo "  Copied {} moxygen libraries"

    # Copy all moxygen headers (preserving directory structure)
    echo "  Copying moxygen headers..."
    mkdir -p "${INSTALL_PREFIX}/include/moxygen"
    cd "${MOXYGEN_DIR}/moxygen"
    find . -name "*.h" -type f | while read -r header; do
        dir=$(dirname "$header")
        mkdir -p "${INSTALL_PREFIX}/include/moxygen/${dir}"
        cp "$header" "${INSTALL_PREFIX}/include/moxygen/${dir}/"
    done
    cd "${MOXYGEN_DIR}"
fi

# Consolidate all Facebook dependencies into install prefix
echo ""
echo "=== Consolidating dependencies ==="
GETDEPS_INSTALLED=$(dirname "$(get_install_dir)")
if [[ -d "${GETDEPS_INSTALLED}" ]]; then
    # List of dependencies to consolidate
    DEPS="folly fizz wangle mvfst proxygen boost double-conversion fmt gflags glog libevent openssl zstd lz4 snappy libsodium liboqs"

    for dep in ${DEPS}; do
        # Find directory: exact match or with hash suffix
        DEP_DIR=$(ls -d "${GETDEPS_INSTALLED}/${dep}" "${GETDEPS_INSTALLED}/${dep}"-* 2>/dev/null | head -1)
        if [[ -n "${DEP_DIR}" && -d "${DEP_DIR}" ]]; then
            # Copy libraries (static and dynamic, preserving symlinks)
            if [[ -d "${DEP_DIR}/lib" ]]; then
                find "${DEP_DIR}/lib" -maxdepth 1 -name "*.a" -exec cp {} "${INSTALL_PREFIX}/lib/" \; 2>/dev/null || true
                find "${DEP_DIR}/lib" -maxdepth 1 \( -name "*.dylib" -o -name "*.so*" \) -exec cp -a {} "${INSTALL_PREFIX}/lib/" \; 2>/dev/null || true
            fi
            if [[ -d "${DEP_DIR}/lib64" ]]; then
                find "${DEP_DIR}/lib64" -maxdepth 1 -name "*.a" -exec cp {} "${INSTALL_PREFIX}/lib/" \; 2>/dev/null || true
                find "${DEP_DIR}/lib64" -maxdepth 1 \( -name "*.dylib" -o -name "*.so*" \) -exec cp -a {} "${INSTALL_PREFIX}/lib/" \; 2>/dev/null || true
            fi
            # Copy headers
            if [[ -d "${DEP_DIR}/include" ]]; then
                cp -R "${DEP_DIR}/include/"* "${INSTALL_PREFIX}/include/" 2>/dev/null || true
            fi
            echo "  Consolidated ${dep}"
        fi
    done
fi

echo ""
echo "=== Build complete ==="
echo ""
echo "Moxygen installed to: ${INSTALL_PREFIX}"
echo ""

# Count libraries
LIB_COUNT=$(find "${INSTALL_PREFIX}/lib" -name "*.a" 2>/dev/null | wc -l | tr -d ' ')
echo "Static libraries: ${LIB_COUNT} .a files in ${INSTALL_PREFIX}/lib"
echo ""

# Generate library flags from installed .a and .dylib files
echo "=== Generating library list ==="
LIB_FLAGS=""
# Add static libraries
for lib in "${INSTALL_PREFIX}/lib/"lib*.a; do
    if [[ -f "$lib" ]]; then
        libname=$(basename "$lib" .a | sed 's/^lib//')
        LIB_FLAGS="${LIB_FLAGS} -l${libname}"
    fi
done
# Add dynamic libraries (exclude versioned duplicates like libfoo.0.dylib when libfoo.dylib exists)
for lib in "${INSTALL_PREFIX}/lib/"lib*.dylib; do
    if [[ -f "$lib" && ! -L "$lib" ]]; then
        # Skip versioned dylibs (e.g., libglog.0.5.0.dylib)
        basename_lib=$(basename "$lib")
        if [[ ! "$basename_lib" =~ \.[0-9]+\.dylib$ && ! "$basename_lib" =~ \.[0-9]+\.[0-9]+\.dylib$ ]]; then
            libname=$(basename "$lib" .dylib | sed 's/^lib//')
            # Check if we already have this library from .a
            if [[ ! "$LIB_FLAGS" =~ "-l${libname} " && ! "$LIB_FLAGS" =~ "-l${libname}$" ]]; then
                LIB_FLAGS="${LIB_FLAGS} -l${libname}"
            fi
        fi
    fi
done

# Generate Xcode configuration file
XCODE_CONFIG="${INSTALL_PREFIX}/moxygen.xcconfig"

# Compute relative path from SRCROOT (assumes project is parent of dependencies/)
RELATIVE_INSTALL_PATH="dependencies/moxygen-install"

cat > "${XCODE_CONFIG}" << XCEOF
// Moxygen XCConfig - Generated by build-moxygen.sh
// Add this to your Xcode project's build settings

// Use SRCROOT-relative path for portability
// Assumes Xcode project is at the same level as 'dependencies' folder
MOXYGEN_PREFIX = \$(SRCROOT)/${RELATIVE_INSTALL_PATH}

// Header Search Paths (add to existing)
HEADER_SEARCH_PATHS = \$(inherited) \$(MOXYGEN_PREFIX)/include

// Library Search Paths (add to existing)
LIBRARY_SEARCH_PATHS = \$(inherited) \$(MOXYGEN_PREFIX)/lib

// Runtime Search Paths for dynamic libraries
LD_RUNPATH_SEARCH_PATHS = \$(inherited) \$(MOXYGEN_PREFIX)/lib

// Other Linker Flags - All installed static libraries
OTHER_LDFLAGS = \$(inherited)${LIB_FLAGS} -lc++

// System Frameworks
OTHER_LDFLAGS = \$(inherited) -framework Security -framework CoreFoundation -framework SystemConfiguration -framework CoreServices
XCEOF

echo "Generated Xcode configuration: ${XCODE_CONFIG}"
echo ""
echo "=== Xcode Integration ==="
echo ""
echo "Option 1: Use the generated xcconfig file"
echo "  1. In Xcode, go to Project > Info > Configurations"
echo "  2. Set the configuration file to: ${XCODE_CONFIG}"
echo ""
echo "Option 2: Manual configuration"
echo "  Header Search Paths:  ${INSTALL_PREFIX}/include"
echo "  Library Search Paths: ${INSTALL_PREFIX}/lib"
echo "  Other Linker Flags:   (see ${XCODE_CONFIG} for full list)"
echo ""
echo "Required System Frameworks:"
echo "  Security, CoreFoundation, SystemConfiguration, CoreServices"
