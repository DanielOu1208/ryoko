#!/bin/zsh
# Puts the demo simulator in its recording state: the latest Debug build, the
# demo profile, Nara (Higashimuki), light mode, a 9:41 status bar, and no saved
# place cards or Mimo chats (so loading and arrival animations play).
#
#   demo/capture/prep.sh            # uses ios/.build/DerivedData-demo
#
# Build first:
#   xcodebuild -project ios/Ryoko.xcodeproj -scheme Ryoko -configuration Debug \
#     -destination 'generic/platform=iOS Simulator' -derivedDataPath ios/.build/DerivedData-demo build
set -euo pipefail
cd "${0:A:h}/../.."

UDID=${RYOKO_DEMO_UDID:-303168FE-D5C4-4084-80F2-92D31A987784}
APP=ios/.build/DerivedData-demo/Build/Products/Debug-iphonesimulator/Ryoko.app

xcrun simctl terminate "$UDID" com.danielou.ryoko 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi
# Higashimuki, Nara: a short walk from the 7-Eleven, Kofuku-ji and Nara Park.
xcrun simctl location "$UDID" set 34.6843,135.8297
xcrun simctl privacy "$UDID" grant location com.danielou.ryoko

C=$(xcrun simctl get_app_container "$UDID" com.danielou.ryoko data)
mkdir -p "$C/Library/Application Support/Ryoko"
cp demo/sim/profile.demo.json "$C/Library/Application Support/Ryoko/profile.json"
rm -rf "$C/Library/Application Support/Ryoko/Mimo" "$C/Library/Caches/Ryoko"
xcrun simctl spawn "$UDID" defaults write com.danielou.ryoko RyokoOnboarded -bool YES
echo "Demo simulator ready ($UDID)"
