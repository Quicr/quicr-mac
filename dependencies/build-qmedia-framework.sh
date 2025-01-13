#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
# SPDX-License-Identifier: BSD-2-Clause
set -e


# Get correct directory
DIR="$(cd "$(dirname "$0")";pwd -P)"

if [ "$CI" = TRUE ] ; then
    if [ "$CI_PRODUCT_PLATFORM" == "iOS" ] ; then
        CMD_LINE="--platform IOS"
    elif [ "$CI_PRODUCT_PLATFORM" == "macOS" ] ; then
        CMD_LINE="--platform CATALYST_ARM --platform CATALYST_X86"
    elif [ "$CI_PRODUCT_PLATFORM" == "tvOS" ] ; then
        CMD_LINE="--platform TVOS"
    fi

    CRYPTO="openssl"
    $DIR/build-qmedia-framework.py $CMD_LINE --build-number="$CI_BUILD_NUMBER" --crypto="$CRYPTO"
else
    $DIR/build-qmedia-framework.py
fi
