SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
export PROJECT_DIR=$SCRIPT_DIR/..
echo $PROJECT_DIR
xcodebuild -destination 'platform=macOS,variant=Mac Catalyst' -scheme QuicR -project $PROJECT_DIR/QuicR.xcodeproj clean build-for-testing > $SCRIPT_DIR/xcodebuild.log
swiftlint analyze --strict --compiler-log-path $SCRIPT_DIR/xcodebuild.log $PROJECT_DIR --reporter markdown
rm $SCRIPT_DIR/xcodebuild.log
