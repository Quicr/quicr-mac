#!/usr/bin/env bash
set -e

# Get correct directory
DIR="$(cd "$(dirname "$0")";pwd -P)"

if [ "$CI" = TRUE ] ; then
    $DIR/build-qmedia-framework.py --archs "$ARCHS" --effective-platform-name="$EFFECTIVE_PLATFORM_NAME" --build-number="$CI_BUILD_NUMBER"
else
    $DIR/build-qmedia-framework.py
fi
