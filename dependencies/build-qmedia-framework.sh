#!/usr/bin/env bash
set -e

# Get correct directory
DIR="$(cd "$(dirname "$0")";pwd -P)"

if [ "$CI" = TRUE ] ; then
    if [ "$CI_PRODUCT_PLATFORM" == "iOS" ] ; then
        CMD_LINE="--platform IOS"
    elif [ "$CI_PRODUCT_PLATFORM" == "macOS" ] ; then
        CMD_LINE="--platform CATALYST_ARM --platform CATALYST_X86"
    fi
    $DIR/build-qmedia-framework.py $CMD_LINE --build-number="$CI_BUILD_NUMBER"
else
    $DIR/build-qmedia-framework.py
fi
