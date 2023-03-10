#!/bin/sh

# Skip package validation for build plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Build QMedia.
./$CI_PROJECT_FILE_PATH/dependencies/build-qmedia-framework.sh
