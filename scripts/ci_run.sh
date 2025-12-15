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
if command -v xcpretty &> /dev/null; then
    xcodebuild -project PDFQuickFix.xcodeproj \
        -scheme PDFQuickFix \
        -destination 'platform=macOS' \
        -configuration Debug \
        test | xcpretty
else
    xcodebuild -project PDFQuickFix.xcodeproj \
        -scheme PDFQuickFix \
        -destination 'platform=macOS' \
        -configuration Debug \
        test
fi

echo "✅ CI Run Complete."
