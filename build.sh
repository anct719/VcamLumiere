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
#   MONOCYPHER_DIR - path to Monocypher source (default: ./deps/monocypher)
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
MONOCYPHER_DIR="${MONOCYPHER_DIR:-./deps/monocypher}"

# Common flags
CFLAGS="-arch ${ARCHS} -isysroot ${SDKROOT} -miphoneos-version-min=${MIN_IOS}"
CFLAGS="${CFLAGS} -O2 -Wall"
OBJCFLAGS="${CFLAGS} -fobjc-arc -fmodules"
LDFLAGS="-arch ${ARCHS} -isysroot ${SDKROOT} -miphoneos-version-min=${MIN_IOS}"
LDFLAGS="${LDFLAGS} -dynamiclib"
LDFLAGS="${LDFLAGS} -Wl,-rpath,${ROOTLESS_PREFIX}/usr/lib"
LDFLAGS="${LDFLAGS} -Wl,-rpath,${ROOTLESS_PREFIX}/Library/Frameworks"

OUTDIR="./build"
PKGDIR="./package"

mkdir -p "${OUTDIR}"

# ── Shared source files ───────────────────────────────────────────────

SHARED_SRC="Shared/VcamSharedAuth.m Shared/VcamAntiHook.m"

build_crypto() {
    MONOCYPHER_CORE="${MONOCYPHER_DIR}/src/monocypher.c"
    MONOCYPHER_ED25519="${MONOCYPHER_DIR}/src/optional/monocypher-ed25519.c"
    if [ ! -f "${MONOCYPHER_CORE}" ] || [ ! -f "${MONOCYPHER_ED25519}" ]; then
        echo "  [ERROR] Monocypher source not found at ${MONOCYPHER_DIR}"
        echo "          Clone https://github.com/LoupVaillant/Monocypher.git there."
        exit 1
    fi

    mkdir -p "${OUTDIR}/obj"
    ${CC} ${CFLAGS} -std=c99 -I"${MONOCYPHER_DIR}/src" \
        -c "${MONOCYPHER_CORE}" -o "${OUTDIR}/obj/monocypher.o"
    ${CC} ${CFLAGS} -std=c99 \
        -I"${MONOCYPHER_DIR}/src" -I"${MONOCYPHER_DIR}/src/optional" \
        -c "${MONOCYPHER_ED25519}" -o "${OUTDIR}/obj/monocypher-ed25519.o"
    CRYPTO_OBJS="${OUTDIR}/obj/monocypher.o ${OUTDIR}/obj/monocypher-ed25519.o"
}

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

    build_crypto

    if [ ! -d "${LIBRTMP_DIR}" ]; then
        echo "  [ERROR] librtmp source not found at ${LIBRTMP_DIR}"
        echo "          Clone https://github.com/mirror/rtmpdump.git and point LIBRTMP_DIR to its librtmp directory."
        exit 1
    fi

    RTMP_OBJS=""
    for source in "${LIBRTMP_DIR}"/*.c; do
        [ -f "${source}" ] || continue
        base=$(basename "${source}" .c)
        case "${base}" in
            hashswf|sslstub) continue ;;
        esac
        object="${OUTDIR}/obj/rtmp-${base}.o"
        ${CC} ${CFLAGS} -DNO_SSL -DNO_CRYPTO -w -c "${source}" -o "${object}"
        RTMP_OBJS="${RTMP_OBJS} ${object}"
    done
    if [ -z "${RTMP_OBJS}" ]; then
        echo "  [ERROR] No librtmp C sources found at ${LIBRTMP_DIR}"
        exit 1
    fi

    ${CC} ${OBJCFLAGS} ${LDFLAGS} \
        -install_name @rpath/VcamLumiereDaemon.dylib \
        ${DAEMON_SRC} ${SHARED_SRC} ${RTMP_OBJS} ${CRYPTO_OBJS} \
        ${DAEMON_FRAMEWORKS} \
        -lz \
        -lsubstrate \
        -L"${SUBSTRATE_DIR}" \
        -I"${LIBRTMP_DIR}/.." \
        -I"${MONOCYPHER_DIR}/src" -I"${MONOCYPHER_DIR}/src/optional" \
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

    build_crypto

    ${CC} ${OBJCFLAGS} ${LDFLAGS} \
        -install_name @rpath/VcamLumiereUI.dylib \
        ${UI_SRC} ${SHARED_SRC} ${CRYPTO_OBJS} \
        ${UI_FRAMEWORKS} \
        -lsubstrate \
        -L"${SUBSTRATE_DIR}" \
        -I"${MONOCYPHER_DIR}/src" -I"${MONOCYPHER_DIR}/src/optional" \
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
    cp Layout/DEBIAN/* "${STAGE}/DEBIAN/"
    chmod 755 "${STAGE}/DEBIAN/postinst" "${STAGE}/DEBIAN/extrainst_"
    sh -n "${STAGE}/DEBIAN/postinst"
    sh -n "${STAGE}/DEBIAN/extrainst_"

    # Copy dylibs
    cp "${OUTDIR}/VcamLumiereDaemon.dylib" "${STAGE}/var/jb/Library/MobileSubstrate/DynamicLibraries/"
    cp "${OUTDIR}/VcamLumiereUI.dylib"     "${STAGE}/var/jb/Library/MobileSubstrate/DynamicLibraries/"

    # Copy filter plists
    cp Layout/var/jb/Library/MobileSubstrate/DynamicLibraries/*.plist \
       "${STAGE}/var/jb/Library/MobileSubstrate/DynamicLibraries/"

    # Build .deb
    dpkg-deb -Zxz --root-owner-group --build \
        "${STAGE}" \
        "${OUTDIR}/com.lumiere.vcamlumiere_2.0.3_iphoneos-arm64.deb"

    echo "  [OK] ${OUTDIR}/com.lumiere.vcamlumiere_2.0.3_iphoneos-arm64.deb"
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
