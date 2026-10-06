#!/usr/bin/env bash
# Generates the project, builds Release, and installs into /Applications.
# Usage: ./scripts/build-mac.sh [--launch]
set -euo pipefail
cd "$(dirname "$0")/.."

LAUNCH=false
[[ "${1:-}" == "--launch" ]] && LAUNCH=true

# Stamp the version so the menu bar menu says which build is installed: the
# last release tag, and the commit count as the build number (the same number
# release-macos.sh uses), so every new commit installs as a visibly new build.
RELEASE_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*')" \
  || { echo "No release tag found to version this build from. Run: git fetch --tags"; exit 1; }
MARKETING_VERSION="${RELEASE_TAG#v}"
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "Building $MARKETING_VERSION ($BUILD_NUMBER)"

xcodegen generate

xcodebuild \
  -project DogballWhisper.xcodeproj \
  -scheme DogballWhisper \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

APP="build/DerivedData/Build/Products/Release/Dogball Whisper.app"
[[ -d "$APP" ]] || { echo "Build product not found at $APP"; exit 1; }

pkill -x "Dogball Whisper" 2>/dev/null || true
sleep 1
rm -rf "/Applications/Dogball Whisper.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/Dogball Whisper.app"

codesign --verify --strict "/Applications/Dogball Whisper.app"

# An `$LAUNCH && open ...` one-liner here would make the no-flag invocation
# exit 1, because `false` would be the last command the script ran.
if [[ "$LAUNCH" == true ]]; then
  open "/Applications/Dogball Whisper.app"
fi
