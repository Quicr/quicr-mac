# WxQ

`qmedia` driven video conferencing application.

WxQ, or Decimus, is an example video conferencing application built on top of [`qmedia`](https://github.com/Quicr/new-qmedia) and the `QuicR` stack. It provides support for audio and video using Opus and H264 publications and subscriptions as determined by the selected manifest as provided to `qmedia`.

Decimus currently provides:

- `AVFoundation` driven realtime audio/video capture & playout
- H264 hardware accelerated encoding/decoding
- Opus encoding/decoding.
- Manifest fetching.
- QMedia interop.
- Audio/video jitter buffer implementations.
- Unified logging of both client and quicr output
- Summary and granular level metrics
- Integrated build for all qmedia dependencies
- XCode cloud CI

Decimus currently supports iOS 16+ and Mac Catalyst x86/ARM64 and is available on Testflight. 

## Building

1. Ensure dependencies cloned / up to date:
    - `git submodule update --init --recursive`
2. Build QMedia on first time build or post repo clean:
    - `./dependencies/build-qmedia-framework.sh`
    - Note: This script assumes CMake provided by homebrew.
3. Open the XCode project and build for any supported target
    - Build for Mac Catalyst, iOS device or simulator.

If you need to build for iOS devices, you will need to specify a valid team and certificate in the Project's `Signing and Capabilities` page. Your own personal certificate should work well enough for this.

If you wish to run a custom version of any dependency, you can manually check out the given submodule to the desired version and an XCode build will take care of the rest. Sometimes loose files can be left behind from previous versions in lower submodules. If you have issues, ensure they're clean and have been recursively checked out to the correct versions.

### Troubleshooting

Please open an issue for any build issues you face that aren't covered below.

#### iOS Toolchain

If you see a CMake error `get_filename_component called with incorrect number of arguments`, it may be that CMake is using the wrong SDK. You can override this by setting the `SDKROOT` environment variable to an SDK listed by `xcrun`. You may need to remove the QMedia build directories for this to apply, `git clean -f -d -x` is an easy (but nuclear) way to do this.

Roughly the below should do the trick:

```bash
# Ensure XCode itself is selected.
xcode-select -s /Applications/Xcode.app
# Tell CMake to use XCode SDKs.
export SDKROOT=$(xcrun --show-sdk-path)
# Remove generated build directories (this will clear unstaged new files).
git clean -f -d -x
# Rebuild QMedia
./dependencies/build-qmedia-framework.sh
```

#### XCFramework

If you see the following error in XCode: `There is no XCFramework found at '.../Decimus/dependencies/qmedia.xcframework'` then (re)run step 2 above. You may need to clean your XCode build for it to notice the change if you had already opened the project, you can do this from `Product->Clean Build Folder` or `cmd+shift+k`

This repo includes the QMedia dependency as a submodule, and building a universal `xcframework` for all supported targets is built into the buildsystem. However, there doesn't seem to currently be a good way to inform XCode to link against a framework that is built as part of an external build system, and so XCode will complain if this framework is not present (such as the first ever build). Currently, the workaround is to manually build QMedia by running the `./dependencies/build-qmedia-framework.sh` script.