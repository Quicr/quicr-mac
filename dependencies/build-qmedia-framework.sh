#!/usr/bin/env bash
set -e

# Get correct directory
DIR="$(dirname "$0")"

# Currently assumes we're using cmake from homebrew.
export PATH=$PATH:/opt/homebrew/bin/

# Get core count
CORES=$(getconf _NPROCESSORS_ONLN)

# Build for catalyst
mkdir -p $DIR/build-catalyst
cmake -DCMAKE_FRAMEWORK=TRUE -DCMAKE_TOOLCHAIN_FILE=$DIR/ios.toolchain.cmake -S $DIR/new-qmedia -B $DIR/build-catalyst -DPLATFORM=MAC_CATALYST_ARM64 -DENABLE_VISIBILITY=ON
cmake --build $DIR/build-catalyst --target neo_media_client -j$CORES

# Build for iOS
mkdir -p $DIR/build-ios
cmake -DCMAKE_FRAMEWORK=TRUE -DCMAKE_TOOLCHAIN_FILE=$DIR/ios.toolchain.cmake -S $DIR/new-qmedia -B $DIR/build-ios -DPLATFORM=OS64 -DENABLE_VISIBILITY=ON
cmake --build $DIR/build-ios --target neo_media_client -j$CORES

# Build for simulator
mkdir -p $DIR/build-iossim
cmake -DCMAKE_FRAMEWORK=TRUE -DCMAKE_TOOLCHAIN_FILE=$DIR/ios.toolchain.cmake -S $DIR/new-qmedia -B $DIR/build-iossim -DPLATFORM=SIMULATORARM64 -DENABLE_VISIBILITY=ON
cmake --build $DIR/build-iossim --target neo_media_client -j$CORES

# Create xcframework
if [ -d "$DIR/neo_media_client.xcframework" ]
then
    rm -r $DIR/neo_media_client.xcframework
fi
xcodebuild -create-xcframework \
  -framework $DIR/build-catalyst/src/extern/neo_media_client.framework \
  -framework $DIR/build-ios/src/extern/neo_media_client.framework \
  -framework $DIR/build-iossim/src/extern/neo_media_client.framework \
  -output $DIR/neo_media_client.xcframework