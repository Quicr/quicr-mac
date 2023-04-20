#!/bin/sh

# Skip package validation for build plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Build tools
brew install cmake
brew install pkg-config
brew install go

# Build QMedia.
mv $CI_DERIVED_DATA_PATH/build-catalyst $CI_WORKSPACE/dependencies/build-catalyst
mv $CI_DERIVED_DATA_PATH/build-catalyst-x86 $CI_WORKSPACE/dependencies/build-catalyst-x86
mv $CI_DERIVED_DATA_PATH/build-ios $CI_WORKSPACE/dependencies/build-ios
sh $CI_WORKSPACE/dependencies/build-qmedia-framework.sh
