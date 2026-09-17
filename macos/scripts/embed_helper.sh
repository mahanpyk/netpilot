#!/bin/bash
# Compiles and embeds NetPilotHelper into the app bundle for SMAppService.
set -euo pipefail

APP_BUNDLE="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app"
HELPER_OUT="${APP_BUNDLE}/Contents/MacOS/NetPilotHelper"
LAUNCHD_DIR="${APP_BUNDLE}/Contents/Library/LaunchDaemons"
SRC_ROOT="${SRCROOT}"
SHARED="${SRC_ROOT}/Runner/NetPilotShared"
HELPER_SRC="${SRC_ROOT}/NetPilotHelper"
ARCH="$(uname -m)"

mkdir -p "$(dirname "$HELPER_OUT")"
mkdir -p "$LAUNCHD_DIR"

SOURCES=(
  "${SHARED}/NetPilotXPCProtocol.swift"
  "${SHARED}/RouteSpec.swift"
  "${SHARED}/RouteManager.swift"
  "${HELPER_SRC}/HelperDelegate.swift"
  "${HELPER_SRC}/main.swift"
)

echo "Compiling NetPilotHelper for ${ARCH}-apple-macos14.0..."
xcrun swiftc \
  -O \
  -target "${ARCH}-apple-macos14.0" \
  -framework Foundation \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker "${HELPER_SRC}/Info.plist" \
  -o "$HELPER_OUT" \
  "${SOURCES[@]}"

cp "${HELPER_SRC}/com.netpilot.netpilotDesktop.helper.plist" \
  "${LAUNCHD_DIR}/com.netpilot.netpilotDesktop.helper.plist"

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]; then
  codesign --force \
    --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
    --entitlements "${HELPER_SRC}/NetPilotHelper.entitlements" \
    --timestamp=none \
    "$HELPER_OUT"
fi

echo "Embedded NetPilotHelper at $HELPER_OUT"
