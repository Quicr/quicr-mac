#!/usr/bin/python3
# SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
# SPDX-License-Identifier: BSD-2-Clause

from enum import Enum
import sys
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor
import multiprocessing
import argparse
import shutil

build_type = "RelWithDebInfo"
generator = "Unix Makefiles"
openssl_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "openssl")
openssl_bundle_file = "openssl-v3.4.0.tgz"

class Platform:
    def __init__(self, type, cmake_platform, build_folder):
        self.type = type
        self.cmake_platform = cmake_platform
        self.build_folder = build_folder

class Crypto(Enum):
    OPENSSL = 1
    MBEDTLS = 2

class PlatformType(Enum):
    CATALYST_ARM = 1
    CATALYST_X86 = 2
    IOS = 3
    IOS_SIMULATOR = 4
    TVOS = 5
    TVOS_SIMULATOR = 6
    MACOS_ARM64 = 7
    MACOS_X86 = 8

def build(current_directory: str, platform: Platform, cmake_path: str, build_number: int, source: str, identifier: str, target: str, crypto: Crypto):

    build_dir = f"{current_directory}/{platform.build_folder}"
    print(f"[{platform.type.name}] Building {identifier} @ {build_dir} {target} {build_type}")
    if not os.path.exists(build_dir):
        os.makedirs(build_dir)

    mbedtls = "ON" if crypto == Crypto.MBEDTLS else "OFF"


    command = [
        cmake_path,
        f"-G{generator}",
        f"-DCMAKE_TOOLCHAIN_FILE={current_directory}/ios.toolchain.cmake",
        f"-DCMAKE_BUILD_TYPE={build_type}",
        "-S",
        source,
        "-B",
        build_dir,
        "-DCMAKE_FRAMEWORK=TRUE",
        f"-DPLATFORM={platform.cmake_platform}",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        "-DDEPLOYMENT_TARGET=15.0",
        "-DQUICR_BUILD_SHARED=ON",
        "-DENABLE_VISIBILITY=ON",
        "-DWITH_DTRACE=OFF",
        "-DHAVE_H_ERRNO_ASSIGNABLE=0",
        "-DENABLE_STRICT_TRY_COMPILE=ON",
        f"-DMACOSX_FRAMEWORK_IDENTIFIER={identifier}",
        f"-DCMAKE_MODULE_PATH={current_directory}",
        f"-DMACOSX_FRAMEWORK_INFO_PLIST={current_directory}/MacOSXFrameworkInfo.plist",
        f"-DMACOSX_FRAMEWORK_BUNDLE_VERSION=1.0.{build_number}",
        f"-DMACOSX_FRAMEWORK_SHORT_VERSION_STRING=1.0.{build_number}",
        f"-DBUILD_NUMBER={build_number}",
        f"-DUSE_MBEDTLS={mbedtls}",
        "-Wno-dev"]

    env = os.environ.copy()
    env["OPENSSL_ROOT_DIR"] = os.path.join(openssl_path, platform.type.name)

    generate = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    output, error = generate.communicate()
    if generate.returncode != 0:
        print("Generation failed")
        print(generate.stdout)
        return (platform, generate.returncode, output, error)
    build_command = [
        cmake_path,
        "--build",
        build_dir,
        f"--target {target}",
        f"--config {build_type}",
        f"-j{multiprocessing.cpu_count()}"
    ]
    build_process = subprocess.Popen(
        build_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, error = build_process.communicate()
    return (platform, build_process.returncode, output, error)


def generate_dsym(framework_dir, target) -> tuple[int, bytes, bytes]:
    command = [
        "dsymutil",
        f"{framework_dir}{target}.framework/{target}",
        "-o",
        f"{framework_dir}{target}.dSYM"
    ]
    make_dsym = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, error = make_dsym.communicate()
    return make_dsym.returncode, output, error,

def create_xcframework(target: str, target_path: str, current_directory: str, platforms: list[Platform]):
    xcframework_name = f"{target}.xcframework"
    xcframework_path = f"{current_directory}/{xcframework_name}"
    if os.path.exists(xcframework_path):
        shutil.rmtree(xcframework_path)

    command = [
        "xcodebuild",
        "-create-xcframework"
    ]

    for platform in platforms:
        command.append("-framework")
        command.append(
            f"{current_directory}/{platform.build_folder}/{target_path}/{get_build_folder(platform.type)}/{target}.framework")
        command.append("-debug-symbols")
        command.append(f"{current_directory}/{platform.build_folder}/{target_path}/{get_build_folder(platform.type)}/{target}.dSYM")
    command.append("-output")
    command.append(xcframework_path)

    framework = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, error = framework.communicate()
    if framework.returncode != 0:
        print("XCFramework creation failed!")
        print(error.decode())
        exit(1)
    else:
        print(output.decode())


def patch_universal(current_directory: str, build_folder: str, target: str, target_path: str, prefix: str):
    env = os.environ.copy()
    env["TARGET"] = target
    env["BUILD_FOLDER"] = build_folder
    env["TARGET_PATH"] = target_path
    env["PREFIX"] = prefix
    make_universal = subprocess.Popen(
        ["sh", f"{current_directory}/make_universal.sh"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    _, error = make_universal.communicate()
    if make_universal.returncode != 0:
        print(error.decode())
        exit(1)


def openssl_dirs_ready(platform_types: list[PlatformType]):
    """openssl_dirs_ready function
        Check if OPENSSL_PATH is defined with all expected subdirectories

        :param: platform_types    List of PlatformType to check for

        :returns: If all directories are valid, the real path of the OPENSSL_PATH. Otherwise None
    """
    real_path = openssl_path

    if "OPENSSL_PATH" in os.environ:
        real_path = os.path.realpath(os.environ.get("OPENSSL_PATH"))

    for ptype in platform_types:
        if not os.path.isdir(os.path.join(openssl_path, str(ptype.name))):
            print(f'Missing {os.path.join(openssl_path, str(ptype.name))}')
            return None

    return real_path

def do_build(source_folder: str, identifier: str, target: str, target_path: str):
    # Get CMake path.
    cmake = shutil.which("cmake")
    if cmake == None:
        # Assuming homebrew for xcode.
        cmake = "/opt/homebrew/bin/cmake"

    # Supported platforms.
    supported_platforms = {
        PlatformType.CATALYST_ARM: Platform(PlatformType.CATALYST_ARM, "MAC_CATALYST_ARM64", f"build-catalyst-{source_folder}"),
        PlatformType.CATALYST_X86: Platform(PlatformType.CATALYST_X86, "MAC_CATALYST", f"build-catalyst-x86-{source_folder}"),
        PlatformType.IOS: Platform(PlatformType.IOS, "OS64", f"build-ios-{source_folder}"),
        PlatformType.IOS_SIMULATOR: Platform(
            PlatformType.IOS_SIMULATOR, "SIMULATORARM64", f"build-iossim-{source_folder}"),
        PlatformType.TVOS: Platform(PlatformType.TVOS, "TVOS", f"build-tvos-{source_folder}"),
        PlatformType.TVOS_SIMULATOR: Platform(PlatformType.TVOS_SIMULATOR, "SIMULATORARM64_TVOS", f"build-tvossim-{source_folder}"),
        PlatformType.MACOS_ARM64: Platform(PlatformType.MACOS_ARM64, "MAC_ARM64", f"build-macos-{source_folder}"),
        PlatformType.MACOS_X86: Platform(PlatformType.MACOS_X86, "MAC", f"build-macos-x86-{source_folder}")
    }

    # Get dependencies directory (assuming this is where this script lives).
    current_directory = os.path.dirname(os.path.realpath(__file__))

    # Get the desired platforms from args.
    platforms = []
    build_number = 1234
    crypto = Crypto.OPENSSL
    if len(sys.argv) > 1:
        parse = argparse.ArgumentParser("Build Dependencies")
        parse.add_argument("--platform", action="append",
                           choices=[platform.name for platform in PlatformType])
        parse.add_argument("--archs", help="Optional, used by xcode")
        parse.add_argument("--effective-platform-name",
                           help="Optional, used by xcode")
        parse.add_argument(
            "--build-number", help="Optional, used by xcode cloud")
        parse.add_argument("--crypto", help="Optional, used by xcode cloud")
        args = parse.parse_args()
        if args.platform:
            # Build requested platforms.
            platforms = [PlatformType[platform] for platform in args.platform]
        else:
            # Build appropriate platforms for this xcode build.
            if args.effective_platform_name:
                if "maccatalyst" in args.effective_platform_name:
                    for arch in args.archs.split(" "):
                        if arch == "arm64":
                            platforms.append(PlatformType.CATALYST_ARM)
                        elif arch == "x86_64":
                            platforms.append(PlatformType.CATALYST_X86)
                elif "iphoneos" in args.effective_platform_name:
                    platforms.append(PlatformType.IOS)
                elif "iphonesimulator" in args.effective_platform_name:
                    platforms.append(PlatformType.IOS_SIMULATOR)
                elif "tvos" in args.effective_platform_name:
                    platforms.append(PlatformType.TVOS)
                else:
                    print(f"Unhandled effective platform: {args.effective_platform_name}")
                    exit(1)
            else:
                platforms = [platform for platform in PlatformType]

        if args.build_number:
            build_number = args.build_number

        if args.crypto and args.crypto == "mbedtls":
            crypto = Crypto.MBEDTLS

    else:
        # Default will build all supported.
        platforms = [platform for platform in PlatformType]

    # Set openssl_path
    openssl_path = openssl_dirs_ready(platforms)
    if not openssl_path:
        sys.exit("Missing required openssl dirs. Run `openssl/build.sh` to fix or provide your own")

    # CMake generate & build.
    with ThreadPoolExecutor(max_workers=len(platforms)) as pool:
        builds = [pool.submit(build, current_directory, supported_platforms[platform], cmake, build_number, f"{current_directory}/{source_folder}", identifier, target, crypto)
                  for platform in platforms]
    for completed in builds:
        platform, return_code, output, error = completed.result()
        if return_code:
            print(f"[{platform}] ({return_code}) Failed!")
            print(error.decode())
        else:
            print(f"[{platform.type.name}] Built")

    for platform in platforms:
        framework_path = f"{current_directory}/{supported_platforms[platform].build_folder}/{target_path}/{get_build_folder(platform)}/"

        # Patch plist with minimum version.
        if platform == PlatformType.IOS:
            patch_plist(f"{framework_path}{target}.framework/Info.plist", "18.2")
        elif platform == PlatformType.TVOS:
            patch_plist(f"{framework_path}{target}.framework/Info.plist", "18.0")

        # Generate dSYM.
        result, output, error = generate_dsym(framework_path, target)
        if result != 0:
            print(f"Couldn't make dsym for {platform}")
            print(output)
            print(error)

    # Universal LIPO.
    if PlatformType.CATALYST_ARM in platforms and PlatformType.CATALYST_X86 in platforms:
        # Patch and then drop the x86 support, as it's now included in the ARM binary.
        patch_universal(current_directory, source_folder, target, target_path, "catalyst")
        platforms.remove(PlatformType.CATALYST_X86)
        print(f"[{PlatformType.CATALYST_ARM.name} & {PlatformType.CATALYST_X86.name}] Patched universal catalyst binary for ARM64 & x86")

    if PlatformType.MACOS_ARM64 in platforms and PlatformType.MACOS_X86 in platforms:
        # Patch and then drop the x86 support, as it's now included in the ARM binary.
        patch_universal(current_directory, source_folder, target, target_path, "macos")
        platforms.remove(PlatformType.MACOS_X86)
        print(f"[{PlatformType.MACOS_ARM64.name} & {PlatformType.MACOS_X86.name}] Patched universal MacOS binary for ARM64 & x86")

    # XCFramework.
    create_xcframework(target, target_path, current_directory, [
                       supported_platforms[platform] for platform in platforms])

def get_build_folder(type: PlatformType) -> str:
    if generator == "Xcode":
        if type == PlatformType.IOS:
            return f"{build_type}-iphoneos"
        elif type == PlatformType.TVOS:
            return f"{build_type}-appletvos"
        else:
            return build_type
    else:
        return ""

def patch_plist(plist: str, version: str) -> bool:
    print(f"Patching plist @ {plist}")

    command = [
        "plutil",
        "-replace",
        "MinimumOSVersion",
        "-string",
        f"{version}",
        f"{plist}"
    ]
    generate = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, error = generate.communicate()
    if generate.returncode != 0:
        print("Plist patch failed")
        print(generate.stdout)
        return False
    return True

if __name__ == "__main__":
    # Extract tarball pre-built openssl static builds if present
    if os.path.exists(os.path.join(openssl_path, openssl_bundle_file)):
        print(f"Extracting {os.path.join(openssl_path, openssl_bundle_file)}")
        shutil.unpack_archive(os.path.join(openssl_path, openssl_bundle_file), openssl_path, "gztar")
        shutil.copy2(os.path.join(openssl_path, openssl_bundle_file), os.path.join(openssl_path, f"{openssl_bundle_file}.orig"))

    # Build frameworks.
    do_build("libquicr", "com.cisco.quicr.quicr", "quicr", "src")
    do_build("libjitter", "com.cisco.quicr.clibjitter", "clibjitter", "")
