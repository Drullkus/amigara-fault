#!/bin/sh
# Builds Syphon.framework (with its Metal server and client) from the pinned upstream commit
# into Frameworks/. Package.swift links the two executables against that copy.
# Written by Claude Code; conversation transcript:
# llm/transcripts/transcript_2026-10-20_07-18_eb73890b-4f17-4ace-abdd-6dda67cd169b.md
set -eu
cd "$(dirname "$0")"

# Upstream has no Swift package and no release with the Metal classes, so build from Git.
REPO="https://github.com/Syphon/Syphon-Framework.git"
COMMIT="${SYPHON_COMMIT:-f4761677a45b8034a3c2069ec0f3d2553da81fba}"
SRC="Frameworks/Syphon-Framework"
DEST="Frameworks/Syphon.framework"

if ! xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -q "Status: installed"; then
    echo "The Xcode Metal toolchain is missing. Install it once with:" >&2
    echo "    xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

mkdir -p Frameworks
if [ ! -d "$SRC/.git" ]; then
    echo "clone $REPO"
    git clone --quiet "$REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet "$COMMIT"

echo "build Syphon.framework at $COMMIT"
xcodebuild -quiet \
    -project "$SRC/Syphon.xcodeproj" -scheme Syphon -configuration Release \
    -derivedDataPath "$SRC/build" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    build

rm -rf "$DEST"
ditto "$SRC/build/Build/Products/Release/Syphon.framework" "$DEST"
echo "done: $DEST"
