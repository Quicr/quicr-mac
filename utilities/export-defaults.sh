#!/usr/bin/env bash

OUTPUT="${1:-defaults.json}"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
defaults export com.cisco.quicr.decimus $SCRIPT_DIR/defaults
plutil -convert json -o $OUTPUT $SCRIPT_DIR/defaults
rm $SCRIPT_DIR/defaults
