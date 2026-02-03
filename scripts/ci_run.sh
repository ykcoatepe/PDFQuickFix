#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

export USER="${USER:-$(id -un)}"

echo "🚀 Starting CI Run..."

./scripts/security_check.sh

echo "🧰 Tooling:"
xcodebuild -version

# Generate project
if command -v xcodegen &> /dev/null; then
    echo "🛠 Generating Xcode project..."
    xcodegen generate
else
    echo "❌ xcodegen not found. Please install it."
    exit 1
fi

# Run tests
echo "🧪 Running tests..."
XCODEBUILD_CMD=(
    xcodebuild -project PDFQuickFix.xcodeproj
    -scheme PDFQuickFix
    -destination 'platform=macOS'
    -configuration Debug
    test
)

case "${CI_CODE_SIGNING:-1}" in
    0|false|FALSE|no|NO)
        echo "⚠️  Code signing disabled for this run (CI_CODE_SIGNING=${CI_CODE_SIGNING})."
        XCODEBUILD_CMD+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
        ;;
esac

if command -v xcpretty &> /dev/null; then
    "${XCODEBUILD_CMD[@]}" | xcpretty
else
    "${XCODEBUILD_CMD[@]}"
fi

echo "✅ CI Run Complete."
