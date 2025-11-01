#!/usr/bin/env bash
# Template for notarization using notarytool.
# Requirements:
# - Apple Developer ID cert installed and signing configured in Xcode
# - Keychain profile set up once:
#   xcrun notarytool store-credentials "AC_Creds" --apple-id "<APPLE_ID>" --team-id "<TEAM_ID>" --password "<APP_SPECIFIC_PW>"
#
# Usage:
#   scripts/notarize_template.sh "dist/PDFQuickFix.dmg"
set -euo pipefail

ARTIFACT="${1:-dist/PDFQuickFix.dmg}"
PROFILE="${NOTARY_PROFILE:-AC_Creds}"

if [[ ! -f "$ARTIFACT" ]]; then
  echo "Artifact not found: $ARTIFACT"
  exit 1
fi

xcrun notarytool submit "$ARTIFACT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$ARTIFACT"
echo "✅ Notarized: $ARTIFACT"
