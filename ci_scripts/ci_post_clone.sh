#!/bin/sh
# SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
# SPDX-License-Identifier: BSD-2-Clause

# Skip package validation for build plugins.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES

# Build tools
brew install cmake
brew install pkg-config
brew install go

# Patch entitilements for tests.
if [ "$CI_WORKFLOW" == "PR" ]
then
    cp $CI_PRIMARY_REPOSITORY_PATH/ci_scripts/Decimus.entitlements $CI_PRIMARY_REPOSITORY_PATH/Decimus/Decimus.entitlements
fi

# Build QMedia.
sh $CI_PRIMARY_REPOSITORY_PATH/dependencies/build-qmedia-framework.sh
