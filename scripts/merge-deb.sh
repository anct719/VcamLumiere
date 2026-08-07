#!/usr/bin/env bash
# Merge vcamplus + audiosync + vcamui into ONE .deb.
# Usage: scripts/merge-deb.sh <rootless|roothide>
# Preserves existing package layout; no original source is modified.
set -euo pipefail

SCHEME="${1:-rootless}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN"

# Extract each built deb into the common staging root (last control wins).
for deb in packages/*.deb AudioSync/packages/*.deb VCamUIPatch/packages/*.deb; do
  [ -f "$deb" ] || continue
  dpkg-deb -e "$deb" "$STAGE/DEBIAN" || true
  dpkg-deb -x "$deb" "$STAGE/"
done

# Unified control: keep the main package identity (com.vcamplus.tweak),
# bump to a combined version, describe the full bundle.
VERSION="7.0.0"
# roothide requires iphoneos-arm64e arch; rootless uses iphoneos-arm64.
if [ "$SCHEME" = "roothide" ]; then
  PKG_ARCH="iphoneos-arm64e"
else
  PKG_ARCH="iphoneos-arm64"
fi
cat > "$STAGE/DEBIAN/control" <<EOF
Package: com.vcamplus.tweak
Name: VCamPlus (All-In-One)
Version: $VERSION
Architecture: $PKG_ARCH
Description: vcamplus core + AudioSync + VCamUI patch (single package)
Maintainer: vcamplus
Author: vcamplus
Section: Tweaks
EOF

# dpkg-deb needs a valid package; ensure file perms preserved.
# Use gzip compression (not xz) for maximum device dpkg compatibility.
dpkg-deb -Zgzip -z9 --root-owner-group -b "$STAGE" "vcam-all-$SCHEME.deb"
echo "Merged -> vcam-all-$SCHEME.deb"
