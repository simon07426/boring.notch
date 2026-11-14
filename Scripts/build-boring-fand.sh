#!/bin/bash
# Xcode Run Script phase: builds the root fan daemon (SwiftPM product boring-fand) and bundles it,
# with its LaunchDaemon plist template, into the app's Resources. Needs ENABLE_USER_SCRIPT_SANDBOXING = NO.
set -euo pipefail

LABEL="theboringteam.boringnotch.fand"
PKG="$SRCROOT/Packages/NotchExtras"
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
SCRATCH="$TARGET_TEMP_DIR/boring-fand-build"

# Run swift build with a clean environment: Xcode's SDKROOT, ARCHS, etc. confuse a nested SwiftPM build.
ENV_ARGS=(HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin")
if [ -n "${DEVELOPER_DIR:-}" ]; then ENV_ARGS+=(DEVELOPER_DIR="$DEVELOPER_DIR"); fi

/usr/bin/env -i "${ENV_ARGS[@]}" /usr/bin/swift build -c release \
    --package-path "$PKG" --scratch-path "$SCRATCH" --product boring-fand
BIN_DIR="$(/usr/bin/env -i "${ENV_ARGS[@]}" /usr/bin/swift build -c release \
    --package-path "$PKG" --scratch-path "$SCRATCH" --show-bin-path)"

mkdir -p "$DEST"
cp -f "$BIN_DIR/boring-fand" "$DEST/$LABEL"
cp -f "$PKG/Resources/$LABEL.plist" "$DEST/$LABEL.plist"

# Capture first: `cmd | grep -q` under pipefail can report a false negative via SIGPIPE.
IDENTITIES="$(/usr/bin/security find-identity -p codesigning || true)"
if grep -q '"Boring Notch Dev"' <<<"$IDENTITIES"; then
    /usr/bin/codesign -f -i "$LABEL" -s "Boring Notch Dev" "$DEST/$LABEL"
else
    echo "warning: 'Boring Notch Dev' code signing identity not found; ad-hoc signing the fan daemon" >&2
    /usr/bin/codesign -f -i "$LABEL" -s - "$DEST/$LABEL"
fi
