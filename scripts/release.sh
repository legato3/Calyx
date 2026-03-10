#!/bin/bash
set -euo pipefail

VERSION=$(grep 'MARKETING_VERSION' project.yml | grep -v '\$(' | sed 's/.*"\(.*\)"/\1/')
APP_PATH="/tmp/CalyxRelease/Build/Products/Release/Calyx.app"
ZIP_PATH="/tmp/Calyx.zip"

echo "=== Calyx Release v$VERSION ==="

# 1. Check required env vars
echo "Checking required environment variables..."
: "${APPLE_API_KEY:?APPLE_API_KEY is not set}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is not set}"
: "${APPLE_API_ISSUER:?APPLE_API_ISSUER is not set}"
echo "All required environment variables are set."

# 2. Generate Xcode project
echo "Generating Xcode project..."
xcodegen generate
echo "Xcode project generated."

# 3. Build
echo "Building Calyx (Release)..."
xcodebuild \
  -project Calyx.xcodeproj \
  -scheme Calyx \
  -configuration Release \
  CODE_SIGN_IDENTITY="Developer ID Application: Yuuichi Eguchi (PQQBSRKD72)" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=PQQBSRKD72 \
  -derivedDataPath /tmp/CalyxRelease \
  clean build
echo "Build succeeded."

# 4. Zip for notarization
echo "Creating zip for notarization..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "Zip created at $ZIP_PATH."

# 5. Submit for notarization
echo "Submitting for notarization..."
xcrun notarytool submit "$ZIP_PATH" \
  --key "$APPLE_API_KEY" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER" \
  --wait
echo "Notarization complete."

# 6. Staple
echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_PATH"
echo "Stapling complete."

# 7. Re-zip with staple
echo "Creating final zip with stapled ticket..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
echo "Final zip created at $ZIP_PATH."

# 8. Push to remote
echo "Pushing to origin main..."
git push origin main
echo "Push complete."

# 9. Create GitHub release
echo "Creating GitHub release v$VERSION..."
git fetch --tags --force
PREV_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")
if [ -n "$PREV_TAG" ]; then
  NOTES=$(git log --pretty=format:"- %s" "$PREV_TAG"..HEAD)
else
  NOTES=$(git log --pretty=format:"- %s")
fi
RELEASE_BODY="## What's Changed
$NOTES"
gh release create "v$VERSION" "$ZIP_PATH" \
  --title "Calyx v$VERSION" \
  --notes "$RELEASE_BODY"
echo "GitHub release v$VERSION created."

echo "=== Release v$VERSION complete ==="
