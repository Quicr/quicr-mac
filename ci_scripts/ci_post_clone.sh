#!/bin/sh

# Skip package validation for build plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Build tools
brew install cmake
brew install pkg-config
brew install go

# Patch entitilements for tests.
if [ "$CI_WORKFLOW" == "PR" ]
then
    cp $CI_WORKSPACE/ci_scripts/Decimus.entitlements $CI_WORKSPACE/Decimus/Decimus.entitlements
fi

# Build QMedia.
if [ "$CI_PRODUCT_PLATFORM" == "iOS"]
then
    CMD_LINE="--platform IOS"
elif [ "$CI_PRODUCT_PLATFORM" == "macOS"]
then
    CMD_LINE="--platform CATALYST_ARM --platform CATALYST_X86"
fi
sh $CI_WORKSPACE/dependencies/build-qmedia-framework.sh $CMD_LINE
