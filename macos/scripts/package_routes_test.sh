#!/usr/bin/env bash
# Internal Rules-only DMG. Requires a local Apple Development signing identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IDENTITY="${NETPILOT_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  echo "Set NETPILOT_SIGNING_IDENTITY to a local Apple Development identity." >&2
  exit 2
fi

cd "$ROOT"
# A fresh checkout has no macos/Flutter/ephemeral input/output file lists.
# Generate Flutter's Xcode configuration before invoking xcodebuild directly.
flutter build macos --release --config-only
mkdir -p build/macos dist
xcodebuild \
  -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/macos \
  CODE_SIGNING_ALLOWED=NO \
  build -quiet

STAGE="$(mktemp -d "$ROOT/build/macos/routes-package.XXXXXX")"
APP="$STAGE/NetPilot.app"
ditto build/macos/Build/Products/Release/netpilot_desktop.app "$APP"

# The Network Extension cannot activate without its approved entitlement.
# The Rules-only app must not ship an unusable extension or claim that entitlement.
python3 - "$APP" <<'PY'
from pathlib import Path
import shutil
import sys

extension_dir = Path(sys.argv[1]) / "Contents/Library/SystemExtensions"
if extension_dir.is_dir() and not extension_dir.is_symlink():
    shutil.rmtree(extension_dir)
PY

# The normal helper build follows the host CPU. Add the other architecture so
# the test DMG can run on either supported macOS architecture.
SHARED="$ROOT/macos/Runner/NetPilotShared"
HELPER_SRC="$ROOT/macos/NetPilotHelper"
HELPER="$APP/Contents/MacOS/NetPilotHelper"
HOST_ARCH="$(lipo -archs "$HELPER")"
case "$HOST_ARCH" in
  arm64) EXTRA_ARCH=x86_64 ;;
  x86_64) EXTRA_ARCH=arm64 ;;
  *) echo "Unexpected helper architecture: $HOST_ARCH" >&2; exit 1 ;;
esac
EXTRA_HELPER="$STAGE/NetPilotHelper.$EXTRA_ARCH"
xcrun swiftc \
  -O -target "$EXTRA_ARCH-apple-macos14.0" -framework Foundation \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
  -Xlinker "$HELPER_SRC/Info.plist" \
  -o "$EXTRA_HELPER" \
  "$SHARED/NetPilotXPCProtocol.swift" \
  "$SHARED/RouteSpec.swift" \
  "$SHARED/RouteManager.swift" \
  "$HELPER_SRC/HelperDelegate.swift" \
  "$HELPER_SRC/main.swift"
lipo -create "$HELPER" "$EXTRA_HELPER" -output "$STAGE/NetPilotHelper.universal"
mv "$STAGE/NetPilotHelper.universal" "$HELPER"
rm "$EXTRA_HELPER"

for framework in "$APP"/Contents/Frameworks/*.framework; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$framework"
done
codesign --force --sign "$IDENTITY" \
  --identifier com.netpilot.netpilotDesktop.helper \
  --entitlements "$HELPER_SRC/NetPilotHelper.entitlements" \
  --timestamp=none "$HELPER"
codesign --force --sign "$IDENTITY" \
  --identifier com.netpilot.netpilotDesktop \
  --entitlements "$ROOT/macos/Runner/RoutesOnly.entitlements" \
  --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

ln -s /Applications "$STAGE/Applications"
STAMP="$(date +%Y%m%d-%H%M)"
DMG="$ROOT/dist/NetPilot-Rules-Test-$STAMP.dmg"
hdiutil create -volname 'NetPilot Rules Test' \
  -srcfolder "$STAGE" -format UDZO -ov "$DMG"
shasum -a 256 "$DMG"
python3 - "$STAGE" <<'PY'
from pathlib import Path
import shutil
import sys

stage = Path(sys.argv[1]).resolve()
expected_parent = (Path.cwd() / "build/macos").resolve()
if stage.parent == expected_parent and stage.name.startswith("routes-package."):
    shutil.rmtree(stage)
else:
    raise SystemExit(f"Refusing to remove unexpected staging path: {stage}")
PY
echo "Internal test DMG: $DMG"
echo "Apple Development signing is not Developer ID notarization; Gatekeeper may reject this DMG on another Mac."
