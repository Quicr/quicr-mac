# Univeral catalyst binary
DIR="$(cd "$(dirname "$0")";pwd -P)"
ORIGINAL=$(readlink -f $DIR/build-catalyst/src/extern/neo_media_client.framework/neo_media_client)
ARCHS=$(lipo -archs $ORIGINAL)
if [ "$ARCHS" == "arm64" ]
then
  lipo -create -output $DIR/neo_media_client $ORIGINAL $DIR/build-catalyst-x86/src/extern/neo_media_client.framework/neo_media_client
  mv $DIR/neo_media_client $ORIGINAL
fi