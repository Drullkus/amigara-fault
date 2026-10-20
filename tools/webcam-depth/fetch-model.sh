#!/bin/sh
# Downloads the DepthAnythingV2SmallF16 Core ML package (about 50 MB) into models/.
# Written by Claude Code; conversation transcript:
# llm/transcripts/transcript_2026-10-20_06-06_cf6a8f39-437b-4cd7-9962-fcfbb1efa030.md
set -eu
cd "$(dirname "$0")"
NAME="${1:-DepthAnythingV2SmallF16}"
BASE="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/$NAME.mlpackage"
DEST="models/$NAME.mlpackage"
mkdir -p "$DEST/Data/com.apple.CoreML/weights"
for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    echo "fetch $f"
    curl -sSL --fail -o "$DEST/$f" "$BASE/$f"
done
echo "done: $DEST"
