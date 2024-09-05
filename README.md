# Decimus

Decimus is a proof of concept Media over QUIC application allowing audio / video conferencing using [libquicr](https://github.com/quicr/libquicr).

## Building

1. Ensure dependencies cloned / up to date:
    - `git submodule update --init --recursive`
2. Remove build directories (optional, if cleaning)
    - `rm -rf dependencies/build-*`
3. Build dependencies on first time build or post repo clean:
    - `./dependencies/build-qmedia-framework.sh`
    - Note: This script assumes CMake provided by homebrew.
4. Open the XCode project and build for any supported target
    - Build for Mac Catalyst, iOS device or simulator.

If you need to build for iOS devices, you will need to specify a valid team and certificate in the Project's `Signing and Capabilities` page. Your own personal certificate should work well enough for this.

## Contributing

A `pre-commit` hook for `swiftlint` is provided. You can install both from Homebrew, and run `pre-commit install` to add the hook to your local repository.

## Troubleshooting

Please open an issue for any build issues you face that aren't covered below.

### iOS Toolchain

If you see a CMake error `get_filename_component called with incorrect number of arguments`, it may be that CMake is using the wrong SDK. You can override this by setting the `SDKROOT` environment variable to an SDK listed by `xcrun`. You may need to remove the dependency build directories for this to apply, `git clean -f -d -x` is an easy (but nuclear) way to do this.

Roughly the below should do the trick:

```bash
# Ensure XCode itself is selected.
xcode-select -s /Applications/Xcode.app
# Tell CMake to use XCode SDKs.
export SDKROOT=$(xcrun --show-sdk-path)
# Remove generated build directories (this will clear unstaged new files).
git clean -f -d -x
# Rebuild libquicr.
./dependencies/build-qmedia-framework.sh
```

### XCFramework

If you see the following error in XCode: `There is no XCFramework found at '.../Decimus/dependencies/quicr.xcframework'` then (re)run step 2 above. You may need to clean your XCode build for it to notice the change if you had already opened the project, you can do this from `Product->Clean Build Folder` or `cmd+shift+k`

This repo includes the libquicr dependency as a submodule, and building a universal `xcframework` for all supported targets is built into the buildsystem. However, there doesn't seem to currently be a good way to inform XCode to link against a framework that is built as part of an external build system, and so XCode will complain if this framework is not present (such as the first ever build). Currently, the workaround is to manually build libquicr by running the `./dependencies/build-qmedia-framework.sh` script. Going forwards, you should not need to manually do this again unless the framework is deleted from disk.

### Linker issues with libquicr

- Sometimes you can end up with a mismatch of libquicr and client code in the cache. A clean build of both libquicr and the project will usually resolve it.
