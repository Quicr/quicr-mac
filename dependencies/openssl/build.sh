#!/bin/bash
############################################################################################
# Script builds OpenSSL for mac platforms (ios, catalyst, tvos, ...)
#
# This script builds only the platforms that are used by the quicr-mac app.
# The version and openssl source can be changed to another. For example, boringSSL can
#   be used in the same way that this script builds OpenSSL.
#
# Due to the time it takes to build OpenSSL for each platform, it is suggested that the built
#   libs and headers are provided by an external trusted repo or use the pre-built ones
#   provided in this repo. This script is used to generate the pre-built per platform
#   headers and libraries.
#
# To provide your own OpenSSL, including boringSSL, you should change the GetSource() and
#    BuildSSL() functions to build based on your needs.
#
# You can provide your own build outside of this repo by setting the environment variable OPENSSL_PATH.
# Expected based directories must exist in the OPENSSL_PATH for each xcodebuild platform. Below are the
# expected names:
#    ${OPENSSL_PATH}/CATALYST_ARM
#    ${OPENSSL_PATH}/CATALYST_X86
#    ${OPENSSL_PATH}/IOS
#    ${OPENSSL_PATH}/IOS_SIMULATOR
#    ${OPENSSL_PATH}/TVOS
#    ${OPENSSL_PATH}/TVOS_SIMULATOR
#    ${OPENSSL_PATH}/MACOS_ARM64
#    ${OPENSSL_PATH}/MACOS_X86
#
#   Under each platform name, the standard openssl install directories MUST exist.
#        ${OPENSSL_PATH}/<platform>/include
#        ${OPENSSL_PATH}/<platform>/lib
#
# Create Tar Bundle for github so that it can be used as pre-built libs
#       tar -czvf openssl-v3.4.0.tgz ./CATALYST_ARM ./CATALYST_X86 ./IOS* ./MACOS* ./TVOS*
#        sha256 openssl-v3.4.0.tgz > openssl-v3.4.0.tgz.sha256
#
############################################################################################
set -e
THREAD_COUNT=$(sysctl hw.ncpu | awk '{print $2}')
THREAD_COUNT=$(($THREAD_COUNT * 80 / 100))
HOST_ARC=$( uname -m )
XCODE_ROOT=$( xcode-select -print-path )

# --------------------------------------------------
# Config level variables
# --------------------------------------------------
PREFIX="$(pwd)"
OPENSSL_CFG_OPTS="no-shared no-fips-securitychecks no-fips-post no-http no-tests no-docs no-apps"
MIN_MACOS_VERSION="15.0"
MIN_IOS_VERSION="17.0"

# --------------------------------------------------
# OpenSSL source
# --------------------------------------------------
OPENSSL_REPO=https://github.com/openssl/openssl
OPENSSL_TAG=openssl-3.4.0


# --------------------------------------------------
# Per platform sysroot (SDK to cross build)
# --------------------------------------------------
MAC_SYSROOT=$XCODE_ROOT/Platforms/MacOSX.platform/Developer
IOS_SYSROOT=$XCODE_ROOT/Platforms/iPhoneOS.platform/Developer
IOSSIMS_SYSROOT=$XCODE_ROOT/Platforms/iPhoneSimulator.platform/Developer
TVOS_SYSROOT=$XCODE_ROOT/Platforms/AppleTVOS.platform/Developer


# --------------------------------------------------
# functions
# --------------------------------------------------

# GetSource <github repo url> <src dir> [<tag version>]
function GetSource() {
    if [[ -d $2 ]]; then
        echo "OpenSSL $2 exists, skip git clone"
        return;
    fi

    pdir=$(pwd)

    echo "Cloning source $1"
    git clone $1 $2


    if [[ ! -z $3 ]]; then
        cd $2
        echo "Checking out tag version $3"
        git checkout $3;
        cd $pdir
    fi
}

# BuildOpenSSL <src dir>
function BuildOpenSSL() {
    pdir=$(pwd)
    cd $1

    if [[ -f Makefile ]]; then
        make distclean
    fi

    case "$2" in
        "CATALYST_X86")
            c_target=darwin64-x86_64-cc
            target="--target=x86_64-apple-ios${MIN_IOS_VERSION}-macabi"
            opts=$OPENSSL_CFG_OPTS
            prefix=${PREFIX}/CATALYST_X86
            sysroot=$MAC_SYSROOT/SDKs/MacOSX.sdk
        ;;

        "CATALYST_ARM")
            c_target=darwin64-arm64-cc
            target="--target=arm64-apple-ios${MIN_IOS_VERSION}-macabi"
            opts=$OPENSSL_CFG_OPTS
            prefix=${PREFIX}/CATALYST_ARM
            sysroot=$MAC_SYSROOT/SDKs/MacOSX.sdk
        ;;

        "IOS")
            c_target=ios64-xcrun
            #c_target=ios64-cross
            target=""
            opts="${OPENSSL_CFG_OPTS} -mios-version-min=${MIN_IOS_VERSION}"
            prefix=${PREFIX}/IOS
            sysroot=$IOS_SYSROOT/SDKs/iPhoneOS.sdk
        ;;

        "IOS_SIMULATOR")
            c_target=iossimulator-arm64-xcrun
            target=""
            opts="${OPENSSL_CFG_OPTS} -mios-simulator-version-min=${MIN_IOS_VERSION}"
            prefix=${PREFIX}/IOS_SIMULATOR
            sysroot=$IOS_SYSROOT/SDKs/iPhoneOS.sdk
        ;;

        "TVOS")
            c_target=iossimulator-arm64-xcrun
            target=""
            opts="${OPENSSL_CFG_OPTS} -mtvos-version-min=${MIN_IOS_VERSION}"
            prefix=${PREFIX}/TVOS
            sysroot=$TVOS_SYSROOT/SDKs/AppleTVOS.sdk
        ;;

        "TVOS_SIMULATOR")
            c_target=iossimulator-xcrun
            target=""
            opts="${OPENSSL_CFG_OPTS} -mtvos-simulator-version-min=${MIN_IOS_VERSION}"
            prefix=${PREFIX}/TVOS_SIMULATOR
            sysroot=$TVOS_SYSROOT/SDKs/AppleTVOS.sdk
        ;;

        "MACOS_ARM64")
            c_target=darwin64-arm64-cc
            target=""
            opts="${OPENSSL_CFG_OPTS} -mmacos-version-min=${MIN_MACOS_VERSION}"
            prefix=${PREFIX}/MACOS_ARM64
            sysroot=$MAC_SYSROOT/SDKs/MacOSX.sdk
        ;;

        "MACOS_X86")
            c_target=darwin64-x86_64-cc
            target=""
            opts="${OPENSSL_CFG_OPTS} -mmacos-version-min=${MIN_MACOS_VERSION}"
            prefix=${PREFIX}/MACOS_X86
            sysroot=$MAC_SYSROOT/SDKs/MacOSX.sdk
        ;;

    esac

    ./Configure $c_target \
        ${target} \
        -isysroot ${sysroot} \
        --prefix=${prefix} \
        $opts

    make -j $THREAD_COUNT
    make install_dev
    cd $pdir
}

# --------------------------------------------------
# main
# --------------------------------------------------
echo "Building using ${THREAD_COUNT} threads"

GetSource https://github.com/openssl/openssl ./openssl-src $OPENSSL_TAG

BuildOpenSSL ./openssl-src CATALYST_X86
BuildOpenSSL ./openssl-src CATALYST_ARM
BuildOpenSSL ./openssl-src IOS
BuildOpenSSL ./openssl-src IOS_SIMULATOR
BuildOpenSSL ./openssl-src TVOS
BuildOpenSSL ./openssl-src TVOS_SIMULATOR
BuildOpenSSL ./openssl-src MACOS_ARM64
BuildOpenSSL ./openssl-src MACOS_X86