#!/bin/bash
# Copies the ONNX models and reference fixtures into the app's sandbox
# container so the integration tests can reach them.
#
# The test host is the sandboxed app, so assets outside the container are
# invisible to it no matter what path the tests are given.
#
# Usage: Tools/stage-test-assets.sh <source-directory>
#   where <source-directory> holds models/, media/ and out/.
set -euo pipefail

SRC="${1:?usage: stage-test-assets.sh <source-directory>}"
DEST="$HOME/Library/Containers/com.lisenhuang.FaceFusionMac/Data/Library/Application Support/FaceFusionMac/TestAssets"

if [ ! -d "$SRC/models" ]; then
  echo "error: $SRC/models not found" >&2
  exit 1
fi

mkdir -p "$DEST"
for part in models media out; do
  [ -d "$SRC/$part" ] || continue
  echo "staging $part ..."
  rsync -a --delete "$SRC/$part/" "$DEST/$part/"
done

echo "staged to: $DEST"
du -sh "$DEST"
