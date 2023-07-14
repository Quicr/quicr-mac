# WxQ

QuicR RealTime Osx Media Client

Targets iOS 16.0+ with best effort for >=15.0.

## Building

1. Ensure dependencies cloned / up to date:
    - `git submodule update --init --recursive`
2. Remove build directories

``` rm -rf dependencies/build-catalyst```

3. Build QMedia on first time build or post repo clean:
    - `./dependencies/build-qmedia-framework.sh`
    - Note: This script assumes CMake provided by homebrew.
4. Open the XCode project and build for any Apple Silicon target
    - Build for Mac Catalyst, iOS device or simulator.
    - QMedia intel / rosetta builds currently NOT provided.

If you need to build for iOS devices, you will need to specify a valid team and certificate in the Project's `Signing and Capabilities` page. Your own personal certificate should work well enough for this.

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

This repo includes the QMedia dependency as a submodule, and building a universal `xcframework` for all Apple Sillicon targets is built into the buildsystem. However, there doesn't seem to currently be a good way to inform XCode to link against a framework that is built as part of an external build system, and so XCode will complain if this framework is not present (such as the first ever build). Currently, the workaround is to manually build QMedia by running the `./dependencies/build-qmedia-framework.sh` script.

#### Undefined QMedia Symbols

Ensure you're building for an ARM64 target and not an Intel, Rosetta or Any Mac target.

## Building for H3 Support

Steps:

- Build a customer Rust compiler

  - Clone Rust:

    - `git clone --depth 1 --recursive git@github.com:paulej/rust.git --branch paulej_ios`

  - Build rust

    - `cd rust`

    - ``./x.py build``

  - Add this build as a toolchain

    - `rustup toolchain link 'm10x' build/host/stage2`

- Clone Decimus

  - `git clone --recursive --branch h3-support git@github.com:Quicr/WxQ.git`

- Switch libquir to the paulej_h3 branch and update submodules

  - `cd dependencies/new-qmedia/dependencies/libquicr`

  - `git checkout main`

  - `git pull (to get the latest code)`

  - `git checkout paulej_h3`

  - `git submodule update --init --recursive`

- Follow the normal build instructions for Decimus
