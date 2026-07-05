#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

export USER="${USER:-$(id -un)}"

echo "Running OCR fallback smoke..."
echo "Always runs: local failure -> real Vision fallback."
echo "Opt in: PDFQF_RUN_LIVE_OCR_SMOKE=1 for real local OCR."
echo "Opt in: PDFQF_RUN_CLOUD_OCR_SMOKE=1 plus PDFQF_GOOGLE_VISION_API_KEY for real Google Vision cloud fallback."

./scripts/security_check.sh

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate
else
    echo "xcodegen not found. Install with: brew install xcodegen"
    exit 1
fi

./scripts/run_xcodebuild.sh \
    -project PDFQuickFix.xcodeproj \
    -scheme PDFQuickFix \
    -destination 'platform=macOS' \
    -configuration Debug \
    -derivedDataPath build \
    -only-testing:PDFQuickFixTests/OCRFallbackSmokeTests \
    test
