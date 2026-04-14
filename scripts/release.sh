#!/bin/bash
set -euo pipefail

# =============================================================================
# release.sh — Builds a DMG release package for AIメンター デイトラちゃん
#
# What it does (in order):
#   1. xcodebuild で Release ビルド
#   2. vv-engine内のバイナリ・dylibにad-hoc署名
#   3. アプリ全体にad-hoc署名
#   4. DMG作成（hdiutil create）
#   5. 成果物のパスを表示
#
# Usage:
#   ./scripts/release.sh
#
# Output:
#   build/DaytoraAIMentor.dmg
# =============================================================================

# ── Configuration ────────────────────────────────────────────────────────────

SCHEME="leanring-buddy"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
DMG_STAGING="${BUILD_DIR}/dmg-staging"
DMG_OUTPUT="${BUILD_DIR}/DaytoraAIMentor.dmg"
DMG_VOLNAME="AIメンター デイトラちゃん"

# ── Step 1: Clean previous build artifacts ───────────────────────────────────

echo "🧹 Cleaning previous build artifacts..."
rm -rf "${DMG_STAGING}"
rm -f "${DMG_OUTPUT}"
mkdir -p "${BUILD_DIR}"

# ── Step 2: Release ビルド ───────────────────────────────────────────────────

echo "📦 Building ${SCHEME} (Release)..."
xcodebuild \
    -project "${PROJECT_DIR}/leanring-buddy.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    build \
    2>&1 | tail -5

echo "✅ Build complete"

# ── Step 3: ビルド成果物のパスを取得 ─────────────────────────────────────────

echo "🔍 Locating built app..."
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Release -name "*.app" -maxdepth 1 -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    echo "❌ Built .app not found in DerivedData. Build may have failed."
    exit 1
fi

echo "   Found: ${APP_PATH}"

# ── Step 4: vv-engine内の実行権限を設定 ──────────────────────────────────────

VV_ENGINE_DIR="${APP_PATH}/Contents/Resources/vv-engine"

if [ ! -d "$VV_ENGINE_DIR" ]; then
    echo "❌ vv-engine not found at ${VV_ENGINE_DIR}"
    exit 1
fi

echo "🔧 Setting execute permission on vv-engine/run..."
chmod +x "${VV_ENGINE_DIR}/run"

# ── Step 5: vv-engine内のバイナリ・dylib・soにad-hoc署名（内側から外側）────

echo "🔐 Ad-hoc signing vv-engine binaries..."

# Sign all .dylib files
DYLIB_COUNT=0
while IFS= read -r -d '' dylib; do
    codesign --force --sign - "$dylib" 2>/dev/null && ((DYLIB_COUNT++)) || true
done < <(find "${VV_ENGINE_DIR}" -type f -name "*.dylib" -print0)
echo "   Signed ${DYLIB_COUNT} .dylib files"

# Sign all .so files
SO_COUNT=0
while IFS= read -r -d '' so; do
    codesign --force --sign - "$so" 2>/dev/null && ((SO_COUNT++)) || true
done < <(find "${VV_ENGINE_DIR}" -type f -name "*.so" -print0)
echo "   Signed ${SO_COUNT} .so files"

# Sign the Python framework binary if present
PYTHON_BIN="${VV_ENGINE_DIR}/engine_internal/Python.framework/Versions/3.11/Python"
if [ -f "$PYTHON_BIN" ]; then
    codesign --force --sign - "$PYTHON_BIN"
    echo "   Signed Python framework binary"
fi

# Sign the run binary last (it depends on the libraries above)
codesign --force --sign - "${VV_ENGINE_DIR}/run"
echo "   Signed vv-engine/run"

# ── Step 6: アプリ全体にad-hoc署名 ──────────────────────────────────────────

echo "🔐 Ad-hoc signing the app bundle..."
codesign --force --deep --sign - "${APP_PATH}"
echo "✅ App signed"

# ── Step 7: DMG作成（create-dmg で背景・レイアウト付き）─────────────────────

DMG_BG="${PROJECT_DIR}/build/dmg-background.png"

echo "💿 Creating DMG..."
rm -f "${DMG_OUTPUT}"

create-dmg \
    --volname "${DMG_VOLNAME}" \
    --background "${DMG_BG}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 80 \
    --icon "DaytoraAIMentor.app" 175 190 \
    --app-drop-link 485 190 \
    --no-internet-enable \
    "${DMG_OUTPUT}" \
    "${APP_PATH}"

echo "✅ DMG created"

# ── Done ─────────────────────────────────────────────────────────────────────

DMG_SIZE=$(du -h "${DMG_OUTPUT}" | cut -f1)

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ DMG release package created!"
echo ""
echo "   File: ${DMG_OUTPUT}"
echo "   Size: ${DMG_SIZE}"
echo "   Volume: ${DMG_VOLNAME}"
echo ""
echo "   受講生への配布手順:"
echo "   1. DaytoraAIMentor.dmg をダウンロード"
echo "   2. DMGを開いてアプリをApplicationsにドラッグ"
echo "   3. 初回起動時「開発元が未確認」と出たら右クリック→開く"
echo "   4. Anthropic APIキーを入力して利用開始"
echo "═══════════════════════════════════════════════════════════════"
