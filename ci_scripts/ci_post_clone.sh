#!/bin/sh

# Skip package validation for build plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Build tools
brew install cmake
brew install pkg-config
brew install go

# Build QMedia.
mkdir -p $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM
[ -f $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst ] && mv $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst $CI_WORKSPACE/dependencies/build-catalyst
[ -f $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst-x86 ] && mv $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst-x86 $CI_WORKSPACE/dependencies/build-catalyst-x86
[ -f $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-ios ] && mv $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-ios $CI_WORKSPACE/dependencies/build-ios
sh $CI_WORKSPACE/dependencies/build-qmedia-framework.sh
