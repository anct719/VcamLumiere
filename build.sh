#!/bin/bash
#
# build.sh — Build VcamLumiere without Theos.
#
# Requirements:
#   - Xcode or standalone iOS SDK (iPhoneOS.sdk)
#   - CydiaSubstrate headers + lib (libsubstrate.dylib)
#   - librtmp source compiled for arm64
#   - ldid (for code signing with entitlements)
#
# Usage:
#   ./build.sh [clean|daemon|ui|all|package]
#
# Environment variables:
#   SDKROOT  - path to iPhoneOS.sdk  (auto-detected if Xcode installed)
#   SYSROOT  - same as SDKROOT
#   SUBSTRATE_DIR - directory containing libsubstrate.dylib
#                   (default: /var/jb/usr/lib)
#   LIBRTMP_DIR   - path to compiled librtmp (default: ./librtmp)
#

set -e

# ── Configuration ──────────────────────────────────────────────────────

ARCHS="arm64"
MIN_IOS="15.0"
SDK_VER="16.4"

# Auto-detect SDK
if [ -z "$SDKROOT" ]; then
    SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
    if [ -z "$SDKROOT" ]; then
        echo "[ERROR] Cannot find iPhoneOS SDK. Set SDKROOT manually."
        echo "  export SDKROOT=/path/to/iPhoneOS${SDK_VER}.sdk"
        exit 1
    fi
fi

CC="clang"
ROOTLESS_PREFIX="${ROOTLESS_PREFIX:-/var/jb}"
SUBSTRATE_DIR="${SUBSTRATE_DIR:-${ROOTLESS_PREFIX}/usr/lib}"
LIBRTMP_DIR="${LIBRTMP_DIR:-./librtmp}"

# Common flags
CFLAGS="-arch ${ARCHS} -isysroot ${SDKROOT} -miphoneos-version-min=${MIN_IOS}"
CFLAGS="${CFLAGS} -fobjc-arc -fmodules -O2 -Wall"
LDFLAGS="-arch ${ARCHS} -isysroot ${SDKROOT} -miphoneos-version-min=${MIN_IOS}"
LDFLAGS="${LDFLAGS} -dynamiclib"
LDFLAGS="${LDFLAGS} -Wl,-rpath,${ROOTLESS_PREFIX}/usr/lib"
LDFLAGS="${LDFLAGS} -Wl,-rpath,${ROOTLESS_PREFIX}/Library/Frameworks"

OUTDIR="./build"
PKGDIR="./package"

mkdir -p "${OUTDIR}"

# ── Shared source files ───────────────────────────────────────────────

SHARED_SRC="Shared/VcamSharedAuth.m Shared/VcamAntiHook.m"

# ── Build Daemon ──────────────────────────────────────────────────────

build_daemon() {
    echo "══════════════════════════════════════════════"
    echo "  Building VcamLumiereDaemon.dylib"
    echo "══════════════════════════════════════════════"

    DAEMON_SRC="Daemon/Tweak.m Daemon/VCamManager.m Daemon/RTMPClient.m Daemon/H264Decoder.m"

    DAEMON_FRAMEWORKS="-framework Foundation -framework CoreMedia -framework CoreVideo"
    DAEMON_FRAMEWORKS="${DAEMON_FRAMEWORKS} -framework VideoToolbox -framework Accelerate"
    DAEMON_FRAMEWORKS="${DAEMON_FRAMEWORKS} -framework CoreImage -framework Security"
    DAEMON_FRAMEWORKS="${DAEMON_FRAMEWORKS} -framework CFNetwork -framework ImageIO"
    DAEMON_FRAMEWORKS="${DAEMON_FRAMEWORKS} -framework QuartzCore -framework UIKit"

    # librtmp (compiled C source)
    RTMP_SRC=""
    if [ -d "${LIBRTMP_DIR}" ]; then
        RTMP_SRC=$(find "${LIBRTMP_DIR}" -name "*.c" | tr '\n' ' ')
        echo "  librtmp sources: $(echo ${RTMP_SRC} | wc -w | tr -d ' ') files"
    else
        echo "  [WARN] librtmp dir not found at ${LIBRTMP_DIR}"
        echo "         Download from: https://rtmpdump.mber.com/"
        echo "         Building without RTMP support."
    fi

    ${CC} ${CFLAGS} ${LDFLAGS} \
        -install_name @rpath/VcamLumiereDaemon.dylib \
        ${DAEMON_SRC} ${SHARED_SRC} ${RTMP_SRC} \
        ${DAEMON_FRAMEWORKS} \
        -lz \
        -lsubstrate \
        -L"${SUBSTRATE_DIR}" \
        -I"${LIBRTMP_DIR}/.." \
        -o "${OUTDIR}/VcamLumiereDaemon.dylib"

    echo "  [OK] ${OUTDIR}/VcamLumiereDaemon.dylib"

    # Sign with entitlements
    if command -v ldid &>/dev/null; then
        ldid -Sentitlements.plist "${OUTDIR}/VcamLumiereDaemon.dylib"
        echo "  [OK] Signed with entitlements"
    else
        echo "  [WARN] ldid not found — dylib is unsigned"
    fi
}

# ── Build UI ──────────────────────────────────────────────────────────

build_ui() {
    echo "══════════════════════════════════════════════"
    echo "  Building VcamLumiereUI.dylib"
    echo "══════════════════════════════════════════════"

    UI_SRC="UI/Tweak.m UI/VcamHelper.m UI/VcamLoginHelper.m"
    UI_SRC="${UI_SRC} UI/VcamLiveVerifier.m UI/VcamPinnedSession.m"
    UI_SRC="${UI_SRC} UI/VcamPassthroughWindow.m UI/VcamVolumeObserver.m"

    UI_FRAMEWORKS="-framework Foundation -framework UIKit -framework AudioToolbox"
    UI_FRAMEWORKS="${UI_FRAMEWORKS} -framework Security -framework AVFoundation"
    UI_FRAMEWORKS="${UI_FRAMEWORKS} -framework CoreGraphics -framework QuartzCore"

    ${CC} ${CFLAGS} ${LDFLAGS} \
        -install_name @rpath/VcamLumiereUI.dylib \
        ${UI_SRC} ${SHARED_SRC} \
        ${UI_FRAMEWORKS} \
        -lsubstrate \
        -L"${SUBSTRATE_DIR}" \
        -o "${OUTDIR}/VcamLumiereUI.dylib"

    echo "  [OK] ${OUTDIR}/VcamLumiereUI.dylib"

    # Sign
    if command -v ldid &>/dev/null; then
        ldid -Sentitlements.plist "${OUTDIR}/VcamLumiereUI.dylib"
        echo "  [OK] Signed with entitlements"
    else
        echo "  [WARN] ldid not found — dylib is unsigned"
    fi
}

# ── Package .deb ──────────────────────────────────────────────────────

build_package() {
    echo "══════════════════════════════════════════════"
    echo "  Packaging .deb"
    echo "══════════════════════════════════════════════"

    STAGE="${PKGDIR}/stage"
    rm -rf "${STAGE}"
    mkdir -p "${STAGE}/DEBIAN"
    mkdir -p "${STAGE}/var/jb/Library/MobileSubstrate/DynamicLibraries"

    # Copy control file
    cp Layout/DEBIAN/control "${STAGE}/DEBIAN/"

    # Copy dylibs
    cp "${OUTDIR}/VcamLumiereDaemon.dylib" "${STAGE}/var/jb/Library/MobileSubstrate/DynamicLibraries/"
    cp "${OUTDIR}/VcamLumiereUI.dylib"     "${STAGE}/var/jb/Library/MobileSubstrate/DynamicLibraries/"

    # Copy filter plists
    cp Layout/var/jb/Library/MobileSubstrate/DynamicLibraries/*.plist \
       "${STAGE}/var/jb/Library/MobileSubstrate/DynamicLibraries/"

    # Build .deb
    dpkg-deb -Zxz --root-owner-group --build \
        "${STAGE}" \
        "${OUTDIR}/com.lumiere.vcamlumiere_2.0.0_iphoneos-arm64.deb"

    echo "  [OK] ${OUTDIR}/com.lumiere.vcamlumiere_2.0.0_iphoneos-arm64.deb"
    ls -la "${OUTDIR}/"*.deb
}

# ── Clean ─────────────────────────────────────────────────────────────

clean() {
    echo "Cleaning..."
    rm -rf "${OUTDIR}" "${PKGDIR}"
    echo "  [OK] Clean"
}

# ── Main ──────────────────────────────────────────────────────────────

case "${1:-all}" in
    clean)   clean ;;
    daemon)  build_daemon ;;
    ui)      build_ui ;;
    package) build_package ;;
    all)
        build_daemon
        build_ui
        build_package
        echo ""
        echo "══════════════════════════════════════════════"
        echo "  BUILD COMPLETE"
        echo "══════════════════════════════════════════════"
        ;;
    *)
        echo "Usage: $0 [clean|daemon|ui|all|package]"
        exit 1
        ;;
esac
