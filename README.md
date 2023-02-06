# WxQ
QuicR RealTime Osx Media Client

## Building

1. Ensure dependencies cloned / up to date:
    - `git submodule update --init --recursive`
2. Build QMedia on first time build or post repo clean:
    - `./dependencies/build-qmedia-framework.sh`
    - Note: This script assumes CMake provided by homebrew.
3. Open the XCode project and build for any Apple Silicon target.

### QMedia / Troubleshooting

If you see the following error in XCode: `There is no XCFramework found at '.../Decimus/dependencies/neo_media_client.xcframework'` then (re)run step 2 above. You may need to clean your XCode build for it to notice the change if you had already opened the project, you can do this from `Product->Clean Build Folder` or `cmd+shift+k`

This repo includes the QMedia dependency as a submodule, and building a universal `xcframework` for all Apple Sillicon targets is built into the buildsystem. However, there doesn't seem to currently be a good way to inform XCode to link against a framework that is built as part of an external build system, and so XCode will complain if this framework is not present (such as the first ever build). Currently, the workaround is to manually build QMedia by running the `./dependencies/build-qmedia-framework.sh` script.
