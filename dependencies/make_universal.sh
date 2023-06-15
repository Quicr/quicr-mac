# Univeral catalyst binary
DIR="$(cd "$(dirname "$0")";pwd -P)"
ORIGINAL=$(readlink -f $DIR/build-catalyst-$BUILD_FOLDER/$TARGET_PATH/$TARGET.framework/$TARGET)
ARCHS=$(lipo -archs $ORIGINAL)
if [ "$ARCHS" == "arm64" ]
then
  lipo -create -output $DIR/$TARGET $ORIGINAL $DIR/build-catalyst-x86-$BUILD_FOLDER/$TARGET_PATH/$TARGET.framework/$TARGET
  mv $DIR/$TARGET $ORIGINAL
fi