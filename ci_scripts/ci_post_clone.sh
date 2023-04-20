#!/bin/sh

# Skip package validation for build plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Build tools
brew install cmake
brew install pkg-config
brew install go

# Restore native build caches from derived data.
mkdir -p $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM
if [ -d $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst ]
then
    echo "Restoring build-catalyst from derived data"
    mv $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst $CI_WORKSPACE/dependencies/build-catalyst
else
    echo "Couldn't find cached build-catalyst"
fi

if [ -d $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst-x86 ]
then
    echo "Restoring build-catalyst-x86 from derived data"
    mv $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-catalyst-x86 $CI_WORKSPACE/dependencies/build-catalyst-x86
else
    echo "Couldn't find cached build-catalyst-x86"
fi

if [ -d $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-ios ]
then
    echo "Restoring build-ios from derived data"
    mv $CI_DERIVED_DATA_PATH/$CI_PRODUCT_PLATFORM/build-ios $CI_WORKSPACE/dependencies/build-ios
else
    echo "Couldn't find cached build-ios"
fi

# Build QMedia.
sh $CI_WORKSPACE/dependencies/build-qmedia-framework.sh
