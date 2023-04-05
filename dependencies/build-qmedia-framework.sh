#!/usr/bin/env bash
set -e

# Get correct directory
DIR="$(cd "$(dirname "$0")";pwd -P)"

# We need a build number to run.
BUILD_NUMBER="${CI_BUILD_NUMBER:-1234}"

# Currently assumes we're using cmake from homebrew.
export PATH=$PATH:/opt/homebrew/bin/

# Get core count
CORES=$(getconf _NPROCESSORS_ONLN)

# Build for catalyst
mkdir -p $DIR/build-catalyst
cmake -DCMAKE_FRAMEWORK=TRUE -DDEPLOYMENT_TARGET=16.0 -DCMAKE_TOOLCHAIN_FILE=$DIR/ios.toolchain.cmake -S $DIR/new-qmedia -B $DIR/build-catalyst -DPLATFORM=MAC_CATALYST_ARM64 -DENABLE_VISIBILITY=ON -DMACOSX_FRAMEWORK_IDENTIFIER=com.cisco.quicr.qmedia -DCMAKE_MODULE_PATH=$DIR -DBUILD_NUMBER=$BUILD_NUMBER
cmake --build $DIR/build-catalyst --target neo_media_client -j$CORES

# Build for x86
mkdir -p $DIR/build-catalyst-x86
cmake -DCMAKE_FRAMEWORK=TRUE -DDEPLOYMENT_TARGET=16.0 -DCMAKE_TOOLCHAIN_FILE=$DIR/ios.toolchain.cmake -S $DIR/new-qmedia -B $DIR/build-catalyst-x86 -DPLATFORM=MAC_CATALYST -DENABLE_VISIBILITY=ON -DMACOSX_FRAMEWORK_IDENTIFIER=com.cisco.quicr.qmedia -DCMAKE_MODULE_PATH=$DIR -DBUILD_NUMBER=$BUILD_NUMBER
cmake --build $DIR/build-catalyst-x86 --target neo_media_client -j$CORES

# Univeral catalyst binary
ORIGINAL=$(readlink -f $DIR/build-catalyst/src/extern/neo_media_client.framework/neo_media_client)
ARCHS=$(lipo -archs $ORIGINAL)
if [ "$ARCHS" == "arm64" ]
then
CATALYST_BUILD=build-catalyst
else
CATALYST_BUILD=build-catalyst-x86
fi

# Build for iOS
mkdir -p $DIR/build-ios
cmake -DCMAKE_FRAMEWORK=TRUE -DDEPLOYMENT_TARGET=16.0 -DCMAKE_TOOLCHAIN_FILE=$DIR/ios.toolchain.cmake -S $DIR/new-qmedia -B $DIR/build-ios -DPLATFORM=OS64 -DENABLE_VISIBILITY=ON -DMACOSX_FRAMEWORK_IDENTIFIER=com.cisco.quicr.qmedia -DCMAKE_MODULE_PATH=$DIR -DBUILD_NUMBER=$BUILD_NUMBER
cmake --build $DIR/build-ios --target neo_media_client -j$CORES

# Create xcframework
if [ -d "$DIR/neo_media_client.xcframework" ]
then
    rm -r $DIR/neo_media_client.xcframework
fi
xcodebuild -create-xcframework \
  -framework $DIR/$CATALYST_BUILD/src/extern/neo_media_client.framework \
  -framework $DIR/build-ios/src/extern/neo_media_client.framework \
  -output $DIR/neo_media_client.xcframework
