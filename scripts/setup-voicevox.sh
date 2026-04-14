#!/bin/bash
# setup-voicevox.sh — Copy VOICEVOX engine from the installed app to the project.
#
# Usage:
#   ./scripts/setup-voicevox.sh
#
# This copies the engine binary, libraries, and model files from
# /Applications/VOICEVOX.app into the project's vv-engine/ directory.
# The engine is ~290MB and is excluded from git via .gitignore.
#
# Prerequisites:
#   - VOICEVOX must be installed at /Applications/VOICEVOX.app
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VV_SRC="/Applications/VOICEVOX.app/Contents/Resources/vv-engine"
VV_DST="$PROJECT_ROOT/vv-engine"

echo "=== VOICEVOX Engine Setup ==="

# Check VOICEVOX is installed
if [ ! -d "$VV_SRC" ]; then
    echo "ERROR: VOICEVOX not found at /Applications/VOICEVOX.app"
    echo "Please install VOICEVOX from https://voicevox.hiroshiba.jp/"
    exit 1
fi

# Check if already set up
if [ -f "$VV_DST/run" ]; then
    echo "vv-engine already exists at $VV_DST"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipped."
        exit 0
    fi
fi

echo "Source: $VV_SRC"
echo "Destination: $VV_DST"
echo ""

# Create destination
mkdir -p "$VV_DST"

# Copy engine files
echo "Copying engine binary and libraries..."
cp "$VV_SRC/run" "$VV_DST/"
cp "$VV_SRC/libvoicevox_core.dylib" "$VV_DST/"
cp "$VV_SRC/libvoicevox_onnxruntime.dylib" "$VV_DST/"
cp "$VV_SRC/engine_manifest.json" "$VV_DST/"

echo "Copying engine_internal/ (Python runtime, ~146MB)..."
rsync -a --delete "$VV_SRC/engine_internal/" "$VV_DST/engine_internal/"

echo "Copying resources/..."
rsync -a --delete "$VV_SRC/resources/" "$VV_DST/resources/"

echo "Copying speaker_info/..."
rsync -a --delete "$VV_SRC/speaker_info/" "$VV_DST/speaker_info/"

# Copy only the first model (0.vvm = ずんだもん) to keep size small.
# VOICEVOX ships all models (~1.5GB total), but we only need ずんだもん (~56MB).
echo "Copying model/ (ずんだもん only)..."
mkdir -p "$VV_DST/model"
cp "$VV_SRC/model/0.vvm" "$VV_DST/model/"

# Ensure run binary is executable
chmod +x "$VV_DST/run"

echo ""
TOTAL_SIZE=$(du -sh "$VV_DST" | cut -f1)
echo "Done! vv-engine set up at $VV_DST ($TOTAL_SIZE)"
echo ""
echo "Test the engine:"
echo "  $VV_DST/run --host 127.0.0.1 --port 50021"
echo "  curl http://127.0.0.1:50021/version"
