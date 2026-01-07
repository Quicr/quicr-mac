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
    python3 "${GETDEPS}" --allow-system-packages show-build-dir --src-dir=. moxygen 2>/dev/null || echo ""
}

get_install_dir() {
    python3 "${GETDEPS}" --allow-system-packages show-inst-dir --src-dir=. moxygen 2>/dev/null || echo ""
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
    python3 "${GETDEPS}" --allow-system-packages install-system-deps --recursive moxygen
fi

# Clean if requested
if [[ "${CLEAN}" == "true" ]]; then
    echo ""
    echo "=== Cleaning build artifacts ==="
    python3 "${GETDEPS}" clean moxygen
    rm -rf "${INSTALL_PREFIX}"
fi

# Build moxygen and all dependencies
echo ""
echo "=== Building moxygen and dependencies ==="
echo "This may take a while on first build..."
echo ""

python3 "${GETDEPS}" --allow-system-packages build \
    --no-tests \
    --src-dir=. \
    moxygen \
    --project-install-prefix "moxygen:${INSTALL_PREFIX}"

# Copy artifacts to install prefix (this handles moxygen itself)
echo ""
echo "=== Copying build artifacts ==="
python3 "${GETDEPS}" --allow-system-packages fixup-dyn-deps \
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

    # Copy client-related static libraries that CMake doesn't install
    for lib in libmoxygenclient.a libmoxygenserver.a libmoxygenwtclient.a libmoqfollyexecutorimpl.a; do
        if [[ -f "${BUILD_DIR}/moxygen/${lib}" ]]; then
            cp "${BUILD_DIR}/moxygen/${lib}" "${INSTALL_PREFIX}/lib/"
            echo "  Copied ${lib}"
        fi
    done

    # Copy client headers
    mkdir -p "${INSTALL_PREFIX}/include/moxygen"
    for header in MoQClient.h MoQClientBase.h MoQWebTransportClient.h; do
        if [[ -f "${MOXYGEN_DIR}/moxygen/${header}" ]]; then
            cp "${MOXYGEN_DIR}/moxygen/${header}" "${INSTALL_PREFIX}/include/moxygen/"
        fi
    done
    # Copy util headers needed by client
    mkdir -p "${INSTALL_PREFIX}/include/moxygen/util"
    if [[ -f "${MOXYGEN_DIR}/moxygen/util/QuicConnector.h" ]]; then
        cp "${MOXYGEN_DIR}/moxygen/util/QuicConnector.h" "${INSTALL_PREFIX}/include/moxygen/util/"
    fi
fi

# Consolidate all Facebook dependencies into install prefix
echo ""
echo "=== Consolidating dependencies ==="
GETDEPS_INSTALLED=$(dirname "$(get_install_dir)")
if [[ -d "${GETDEPS_INSTALLED}" ]]; then
    # List of dependencies to consolidate
    DEPS="folly fizz wangle mvfst proxygen boost double-conversion fmt gflags glog libevent openssl zstd lz4 snappy libsodium"

    for dep in ${DEPS}; do
        DEP_DIR="${GETDEPS_INSTALLED}/${dep}"
        if [[ -d "${DEP_DIR}" ]]; then
            # Copy libraries
            if [[ -d "${DEP_DIR}/lib" ]]; then
                find "${DEP_DIR}/lib" -name "*.a" -exec cp {} "${INSTALL_PREFIX}/lib/" \; 2>/dev/null || true
            fi
            if [[ -d "${DEP_DIR}/lib64" ]]; then
                find "${DEP_DIR}/lib64" -name "*.a" -exec cp {} "${INSTALL_PREFIX}/lib/" \; 2>/dev/null || true
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

# Generate Xcode configuration file
XCODE_CONFIG="${INSTALL_PREFIX}/moxygen.xcconfig"
cat > "${XCODE_CONFIG}" << XCEOF
// Moxygen XCConfig - Generated by build-moxygen.sh
// Add this to your Xcode project's build settings

MOXYGEN_PREFIX = ${INSTALL_PREFIX}

// Header Search Paths (add to existing)
HEADER_SEARCH_PATHS = \$(inherited) \$(MOXYGEN_PREFIX)/include

// Library Search Paths (add to existing)
LIBRARY_SEARCH_PATHS = \$(inherited) \$(MOXYGEN_PREFIX)/lib

// Other Linker Flags - Core moxygen client libraries
// Note: Order matters for static linking
OTHER_LDFLAGS = \$(inherited) -lmoxygenclient -lmoxygen -lmlogger -lmoqfollyexecutorimpl -lproxygenhttpserver -lproxygen -lproxygenhttp3 -lquicwebtransport -lwangle -lmvfst_server -lmvfst_client -lmvfst_protocol -lmvfst_transport -lmvfst_codec -lmvfst_state_machine -lmvfst_fizz_handshake -lfizz -lfolly -lfmt -lglog -lgflags -ldouble-conversion -levent -lssl -lcrypto -lz -lzstd -llz4 -lsnappy -lsodium -lboost_context -lboost_filesystem -lboost_program_options -lboost_regex -lboost_system -lboost_thread -lc++

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
