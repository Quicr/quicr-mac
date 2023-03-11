#!/bin/sh

# Skip package validation for build plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# CMake
brew install cmake

# Build QMedia.
sh $CI_WORKSPACE/dependencies/build-qmedia-framework.sh
