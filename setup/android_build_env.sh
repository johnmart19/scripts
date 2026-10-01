#!/usr/bin/env bash

# Copyright (C) 2018 Harsh 'MSF Jarvis' Shandilya
# Copyright (C) 2018 Akhil Narang
# SPDX-License-Identifier: GPL-3.0-only

# Set up an Android/AOSP build environment on Ubuntu/Debian-based hosts.
# Updated for Android 17 and Ubuntu 26.04 LTS (Resolute Raccoon).

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

die() {
    echo -e "${RED}Error: $*${NC}" >&2
    exit 1
}

if ! command -v apt-get >/dev/null 2>&1; then
    die "This script currently supports apt-based Ubuntu/Debian distributions."
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
fi

DISTRO_ID="${ID:-unknown}"
DISTRO_VERSION="${VERSION_ID:-unknown}"
DISTRO_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
DISTRO_NAME="${PRETTY_NAME:-${NAME:-Linux}}"

echo -e "${BLUE}Detected: ${DISTRO_NAME}${NC}"

if [[ "${DISTRO_ID}" == "ubuntu" && "${DISTRO_CODENAME}" == "resolute" ]]; then
    echo -e "${GREEN}Ubuntu 26.04 LTS (Resolute Raccoon) build host detected.${NC}"
fi

echo -e "${BLUE}Refreshing apt metadata...${NC}"
sudo apt-get update

# add-apt-repository is useful for Ubuntu's Universe repository, which carries
# several Android/ROM development utilities.
sudo apt-get install -y software-properties-common ca-certificates curl gnupg

if [[ "${DISTRO_ID}" == "ubuntu" ]] && command -v add-apt-repository >/dev/null 2>&1; then
    sudo add-apt-repository -y universe >/dev/null 2>&1 || true
    sudo apt-get update
fi

package_exists() {
    local candidate
    candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "${candidate}" && "${candidate}" != "(none)" ]]
}

first_available_package() {
    local package
    for package in "$@"; do
        if package_exists "${package}"; then
            printf '%s\n' "${package}"
            return 0
        fi
    done
    return 1
}

# Current AOSP requirements for Ubuntu 18.04+ / Android 11+.
# Android 17's source tree carries prebuilt OpenJDK, Make and Python, but we
# still install host Python 3 and common ROM/kernel tooling used outside Soong.
AOSP_PACKAGES=(
    git-core
    gnupg
    flex
    bison
    build-essential
    zip
    curl
    zlib1g-dev
    libc6-dev-i386
    x11proto-core-dev
    libx11-dev
    lib32z1-dev
    libgl1-mesa-dev
    libxml2-utils
    xsltproc
    unzip
    fontconfig
)

# Useful host tools for AOSP/custom-ROM development, device bring-up,
# Android image manipulation, kernels and release workflows.
DEV_PACKAGES=(
    adb
    fastboot
    android-sdk-libsparse-utils
    autoconf
    automake
    axel
    bc
    brotli
    ccache
    clang
    cmake
    cpio
    device-tree-compiler
    expat
    file
    g++
    g++-multilib
    gawk
    gcc
    gcc-multilib
    git
    git-lfs
    gperf
    htop
    imagemagick
    jq
    lib32ncurses-dev
    libcap-dev
    libelf-dev
    libexpat1-dev
    libgmp-dev
    liblz4-dev
    liblzma-dev
    libmpc-dev
    libmpfr-dev
    libncurses-dev
    libsdl1.2-dev
    libssl-dev
    libtool
    libxml2-dev
    lzip
    lzop
    maven
    ncftp
    ninja-build
    patch
    patchelf
    pigz
    pkg-config
    pngcrush
    pngquant
    python3
    python3-dev
    python3-pip
    python3-pyelftools
    python3-venv
    python-is-python3
    re2c
    rsync
    schedtool
    squashfs-tools
    subversion
    texinfo
    w3m
    zstd
    libxml-simple-perl
    libswitch-perl
    apt-utils
)

# Kernel/GKI development helpers. Some distributions rename or omit a subset,
# so these are installed when present.
OPTIONAL_PACKAGES=(
    dwarves
    kmod
    libdw-dev
    libudev-dev
    python3-yaml
)

# Package name transitions on modern Ubuntu:
#   p7zip-full    -> 7zip
#   liblz4-tool   -> lz4
SEVENZIP_PACKAGE="$(first_available_package 7zip p7zip-full || true)"
LZ4_PACKAGE="$(first_available_package lz4 liblz4-tool || true)"

# Filter development extras that may not exist on every Debian derivative,
# while keeping Google's AOSP-required package set mandatory.
AVAILABLE_DEV_PACKAGES=()
SKIPPED_PACKAGES=()

for package in "${DEV_PACKAGES[@]}"; do
    if package_exists "${package}"; then
        AVAILABLE_DEV_PACKAGES+=("${package}")
    else
        SKIPPED_PACKAGES+=("${package}")
    fi
done

PACKAGES=("${AOSP_PACKAGES[@]}" "${AVAILABLE_DEV_PACKAGES[@]}")

if [[ -n "${SEVENZIP_PACKAGE}" ]]; then
    PACKAGES+=("${SEVENZIP_PACKAGE}")
fi

if [[ -n "${LZ4_PACKAGE}" ]]; then
    PACKAGES+=("${LZ4_PACKAGE}")
fi

for package in "${OPTIONAL_PACKAGES[@]}"; do
    if package_exists "${package}"; then
        PACKAGES+=("${package}")
    fi
done

echo -e "${BLUE}Installing Android 17/AOSP build dependencies...${NC}"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

if (("${#SKIPPED_PACKAGES[@]}" > 0)); then
    echo -e "${YELLOW}Skipped unavailable optional packages: ${SKIPPED_PACKAGES[*]}${NC}"
fi

# Install Repo. Prefer the distro package recommended by current AOSP docs;
# fall back to Google's launcher when a Debian derivative does not ship it.
if ! command -v repo >/dev/null 2>&1; then
    echo -e "${BLUE}Installing repo...${NC}"
    if package_exists repo; then
        sudo apt-get install -y repo
    else
        sudo install -d -m 0755 /usr/local/bin
        sudo curl -fsSL \
            https://storage.googleapis.com/git-repo-downloads/repo \
            -o /usr/local/bin/repo
        sudo chmod 0755 /usr/local/bin/repo
    fi
fi

# GitHub CLI is used by several scripts in this repository.
if ! command -v gh >/dev/null 2>&1; then
    echo -e "${BLUE}Installing GitHub CLI...${NC}"
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
        sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
        sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

    sudo apt-get update
    sudo apt-get install -y gh
fi

# Current Ubuntu adb packages pull in android-udev-rules. Reload rules if
# present so connected devices can be used without the old third-party rules.
if command -v udevadm >/dev/null 2>&1; then
    sudo udevadm control --reload-rules || true
    sudo udevadm trigger || true
fi

echo
echo -e "${GREEN}Android build environment setup complete.${NC}"
echo "Host: ${DISTRO_NAME}"
echo "Codename: ${DISTRO_CODENAME}"
echo "Repo: $(repo version 2>/dev/null | head -n 1 || echo installed)"
echo "Git: $(git --version)"
echo "Python: $(python3 --version)"
echo
echo "Android 17 AOSP uses source-tree prebuilts for OpenJDK, Make and Python."
echo "No legacy Python 2, libtinfo5/libncurses5, or forced Make 4.3 downgrade is required."
