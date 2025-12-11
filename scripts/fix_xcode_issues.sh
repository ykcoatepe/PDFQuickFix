#!/bin/bash
set -e

echo "🧹 Cleaning Xcode environment..."

# 1. Kill Xcode (optional, user might not want this, so maybe just warn)
echo "⚠️  Ideally, close Xcode before running this."

# 2. Delete DerivedData
echo "🗑️  Deleting DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/PDFQuickFix-*

# 3. Clean build folder
echo "clean build folder..."
xcodebuild clean -project PDFQuickFix.xcodeproj -scheme PDFQuickFix > /dev/null 2>&1 || true

# 4. Regenerate project (since we use XcodeGen)
if command -v xcodegen &> /dev/null; then
    echo "🔄 Regenerating project with XcodeGen..."
    xcodegen generate
else
    echo "⚠️  XcodeGen not found, skipping regeneration."
fi

echo "✅ Done! Please restart Xcode and try again."
