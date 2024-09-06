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


class Platform:
    def __init__(self, type, cmake_platform, build_folder):
        self.type = type
        self.cmake_platform = cmake_platform
        self.build_folder = build_folder


class PlatformType(Enum):
    CATALYST_ARM = 1
    CATALYST_X86 = 2
    IOS = 3
    IOS_SIMULATOR = 4
    TVOS = 5
    TVOS_SIMULATOR = 6


def build(current_directory: str, platform: Platform, cmake_path: str, build_number: int, source: str, identifier: str, target: str):

    build_dir = f"{current_directory}/{platform.build_folder}"
    print(f"[{platform.type.name}] Building {identifier} @ {build_dir}")
    if not os.path.exists(build_dir):
        os.makedirs(build_dir)

    command = [
        cmake_path,
        f"-DCMAKE_TOOLCHAIN_FILE={current_directory}/ios.toolchain.cmake",
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
        "-S",
        source,
        "-B",
        build_dir,
        "-DCMAKE_FRAMEWORK=TRUE",
        f"-DPLATFORM={platform.cmake_platform}",
        "-DDEPLOYMENT_TARGET=16.0",
        "-DQUICR_BUILD_SHARED=ON",
        "-DENABLE_VISIBILITY=ON",
        "-DHAVE_H_ERRNO_ASSIGNABLE=0",
        "-DENABLE_STRICT_TRY_COMPILE=ON",
        f"-DMACOSX_FRAMEWORK_IDENTIFIER={identifier}",
        f"-DCMAKE_MODULE_PATH={current_directory}",
        f"-DMACOSX_FRAMEWORK_INFO_PLIST={current_directory}/MacOSXFrameworkInfo.plist",
        f"-DMACOSX_FRAMEWORK_BUNDLE_VERSION=1.0.{build_number}",
        f"-DMACOSX_FRAMEWORK_SHORT_VERSION_STRING=1.0.{build_number}",
        f"-DBUILD_NUMBER={build_number}",
        "-Wno-dev"]
    generate = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
        "--config RelWithDebInfo",
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
            f"{current_directory}/{platform.build_folder}/{target_path}/{target}.framework")
        command.append("-debug-symbols")
        command.append(f"{current_directory}/{platform.build_folder}/{target_path}/{target}.dSYM")
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


def patch_universal(current_directory: str, build_folder: str, target: str, target_path: str):
    env = os.environ.copy()
    env["TARGET"] = target
    env["BUILD_FOLDER"] = build_folder
    env["TARGET_PATH"] = target_path
    make_universal = subprocess.Popen(
        ["sh", f"{current_directory}/make_universal.sh"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    _, error = make_universal.communicate()
    if make_universal.returncode != 0:
        print(error.decode())
        exit(1)

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
    }

    # Get dependencies directory (assuming this is where this script lives).
    current_directory = os.path.dirname(os.path.realpath(__file__))

    # Get the desired platforms from args.
    platforms = []
    build_number = 1234
    if len(sys.argv) > 1:
        parse = argparse.ArgumentParser("Build Dependencies")
        parse.add_argument("--platform", action="append",
                           choices=[platform.name for platform in PlatformType])
        parse.add_argument("--archs", help="Optional, used by xcode")
        parse.add_argument("--effective-platform-name",
                           help="Optional, used by xcode")
        parse.add_argument(
            "--build-number", help="Optional, used by xcode cloud")
        args = parse.parse_args()
        if args.platform:
            # Build requested platforms.
            platforms = [PlatformType[platform] for platform in args.platform]
        else:
            # Build appropriate platforms for this xcode build.
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

        if args.build_number:
            build_number = args.build_number
    else:
        # Default will build all supported.
        platforms = [platform for platform in PlatformType]

    # CMake generate & build.
    with ThreadPoolExecutor(max_workers=len(platforms)) as pool:
        builds = [pool.submit(build, current_directory, supported_platforms[platform], cmake, build_number, f"{current_directory}/{source_folder}", identifier, target)
                  for platform in platforms]
    for completed in builds:
        platform, return_code, output, error = completed.result()
        if return_code:
            print(f"[{platform}] ({return_code}) Failed!")
            print(error.decode())
        else:
            print(f"[{platform.type.name}] Built")

    for platform in platforms:
        result, output, error = generate_dsym(f"{current_directory}/{supported_platforms[platform].build_folder}/{target_path}", target)
        if result != 0:
            print(f"Couldn't make dsym for {platform}")
            print(output)
            print(error)

    # Universal LIPO.
    if PlatformType.CATALYST_ARM in platforms and PlatformType.CATALYST_X86 in platforms:
        # Patch and then drop the x86 support, as it's now included in the ARM binary.
        patch_universal(current_directory, source_folder, target, target_path)
        platforms.remove(PlatformType.CATALYST_X86)
        print(f"[{PlatformType.CATALYST_ARM.name} & {PlatformType.CATALYST_X86.name}] Patched universal catalyst binary for ARM64 & x86")

    # XCFramework.
    create_xcframework(target, target_path, current_directory, [
                       supported_platforms[platform] for platform in platforms])

if __name__ == "__main__":
    do_build("libquicr", "com.cisco.quicr.quicr", "quicr", "src/")
    do_build("libjitter", "com.cisco.quicr.clibjitter", "clibjitter", "")
