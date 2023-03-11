#!/bin/sh

# Skip package validation for build plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Build tools
brew install cmake
brew install pkg-config

# Build QMedia.
sh $CI_WORKSPACE/dependencies/build-qmedia-framework.sh
