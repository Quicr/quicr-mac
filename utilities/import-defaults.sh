#!/usr/bin/env bash

INPUT="${1:-defaults.json}"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
plutil -convert xml1 -o $SCRIPT_DIR/defaults $INPUT
defaults import com.cisco.quicr.decimus $SCRIPT_DIR/defaults
rm $SCRIPT_DIR/defaults
