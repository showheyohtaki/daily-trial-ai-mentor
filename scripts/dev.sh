#!/bin/bash
set -euo pipefail

# Debug版をビルドしてApplicationsにコピー
echo "🔨 Building Debug..."
xcodebuild -project "$(dirname "$0")/../leanring-buddy.xcodeproj" -scheme leanring-buddy -configuration Debug build 2>&1 | tail -3

echo "📦 Copying to /Applications..."
APP=$(find ~/Library/Developer/Xcode/DerivedData/leanring-buddy-*/Build/Products/Debug -name "DaytoraAIMentor.app" -maxdepth 1 -type d | head -1)
rm -rf /Applications/DaytoraAIMentor-Debug.app
cp -R "$APP" /Applications/DaytoraAIMentor-Debug.app

echo "✅ /Applications/DaytoraAIMentor-Debug.app を更新しました"
echo "   開く: open /Applications/DaytoraAIMentor-Debug.app"
