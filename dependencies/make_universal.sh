# Univeral catalyst binary
DIR="$(cd "$(dirname "$0")";pwd -P)"
ORIGINAL=$(readlink -f $DIR/build-catalyst/src/qmedia.framework/qmedia)
ARCHS=$(lipo -archs $ORIGINAL)
if [ "$ARCHS" == "arm64" ]
then
  lipo -create -output $DIR/qmedia $ORIGINAL $DIR/build-catalyst-x86/src/qmedia.framework/qmedia
  mv $DIR/qmedia $ORIGINAL
fi