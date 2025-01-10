# quicr-mac

QuicR-mac is a MacOS/iOS/tvOS proof of concept Media over QUIC application allowing audio / video conferencing using [libquicr](https://github.com/quicr/libquicr).

> [!TIP]  
> This client's working title was "Decimus", which may still be present in the codebase or project. Any reference to "Decimus" refers to this application. Its display name is also now just QuicR, as the `-mac` suffix is implied when on an Apple platform.

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

### OpenSSL
> [!IMPORTANT]
> This repository contains pre-built OpenSSL version 3.4.0 static libraries and headers for the supported xcodebuild platforms.

OpenSSL, compatible OpenSSL, or MBedTLS is required by libquicr and other C++ libraries in this project. Apple requires
specific platform builds of OpenSSL even though the architectures are the same. For this reason, we need to build
OpenSSL for each target platfrom, such as IOS, Catalyst, TVOS, etc.  The
[`./dependencies/openssl/build.sh`](dependencies/openssl/build.sh) script has been provided to build 
OpenSSL for all the platforms that this project supports. If the source doesn't exist, the script by default 
will clone the official OpenSSL github source and checkout tag v3.4.0. It will then build from source
each target platform. 

These libraries do not change, unless the version changes. Building OpenSSL from source for every build results in
unnecessary build time delays, which can be in the several minute range. To speed this up, pre-built openssl
target dev includes/libs have been included in this project. A build is not required unless you need to change
OpenSSL.

#### Providing custom OpenSSL

To provide a custom OpenSSL (e.g., boringSSL or other fork), you should change the
[build.sh](dependencies/openssl/build.sh) `GetSource()` and `BuildSSL()` functions to build based
on your needs. 

You can provide your own build outside of this repo by setting the environment variable `OPENSSL_PATH`.
Expected based directories must exist in the `OPENSSL_PATH` for each xcodebuild platform. Below are the
expected subdirectories:

```
    ${OPENSSL_PATH}/CATALYST_ARM
    ${OPENSSL_PATH}/CATALYST_X86
    ${OPENSSL_PATH}/IOS
    ${OPENSSL_PATH}/IOS_SIMULATOR
    ${OPENSSL_PATH}/TVOS
    ${OPENSSL_PATH}/TVOS_SIMULATOR
    ${OPENSSL_PATH}/MACOS_ARM64
    ${OPENSSL_PATH}/MACOS_X86
```

Under each platform subdirectory, the standard openssl install directories **MUST** exist.

```
        ${OPENSSL_PATH}/<platform>/include
        ${OPENSSL_PATH}/<platform>/lib
```

The default `OPENSSL_PATH` is `./dependencies/openssl`. If you want to change this or move it outside
of this repo, then set the environment variable `OPENSSL_PATH` before calling the
[`./dependencies/build-qmedia-framework py/sh](dependencies/build-qmedia-framework.py) script. 

##### Tar bundle for github

There are many platforms and the size gets a little large. It is more efficient to tar compress these
when pushing to github. The [`./dependencies/build-qmedia-framework.py`](dependencies/build-qmedia-framework.py)
will detect an expected name defined in that script to exist, which is currently `openssl-v3.4.0.tgz`. If that file
exists, it will extract it. One extracted it will rename it to `openssl-v3.4.0.tgz.orig`. 

To create the tar gz file for github, run the following at the root of `OPENSSL_PATH`:

```
cd $OPENSSL_PATH
tar -czvf openssl-v3.4.0.tgz ./CATALYST_ARM ./CATALYST_X86 ./IOS* ./MACOS* ./TVOS*
sha256 openssl-v3.4.0.tgz > openssl-v3.4.0.tgz.sha256
```

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
