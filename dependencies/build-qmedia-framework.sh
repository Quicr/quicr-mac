#!/usr/bin/env bash
set -e

# Get correct directory
DIR="$(dirname "$(realpath "$0")")"

# Currently assumes we're using cmake from homebrew.
export PATH=$PATH:/opt/homebrew/bin/

# Build for catalyst
if [ -d "$DIR/build-catalyst" ]
then
    rm -r $DIR/build-catalyst
fi
mkdir $DIR/build-catalyst
cmake -DCMAKE_FRAMEWORK=TRUE -DCMAKE_TOOLCHAIN_FILE=$DIR/ios.toolchain.cmake -S $DIR/new-qmedia -B $DIR/build-catalyst -DPLATFORM=MAC_CATALYST_ARM64 -DENABLE_VISIBILITY=ON
cmake --build $DIR/build-catalyst --target neo_media_client

# Build for iOS
if [ -d "$DIR/build-ios" ]
then
    rm -r $DIR/build-ios
fi
mkdir $DIR/build-ios
cmake -DCMAKE_FRAMEWORK=TRUE -DCMAKE_TOOLCHAIN_FILE=$DIR/ios.toolchain.cmake -S $DIR/new-qmedia -B $DIR/build-ios -DPLATFORM=OS64 -DENABLE_VISIBILITY=ON
cmake --build $DIR/build-ios --target neo_media_client

# Build for simulator
if [ -d "$DIR/build-iossim" ]
then
    rm -r $DIR/build-iossim
fi
mkdir $DIR/build-iossim
cmake -DCMAKE_FRAMEWORK=TRUE -DCMAKE_TOOLCHAIN_FILE=$DIR/ios.toolchain.cmake -S $DIR/new-qmedia -B $DIR/build-iossim -DPLATFORM=SIMULATORARM64 -DENABLE_VISIBILITY=ON
cmake --build $DIR/build-iossim --target neo_media_client

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
