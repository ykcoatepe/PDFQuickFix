#!/usr/bin/env bash
set -euo pipefail
xcodegen generate
./scripts/run_xcodebuild.sh -project PDFQuickFix.xcodeproj -scheme PDFQuickFix -configuration Release -derivedDataPath build build
open build/Build/Products/Release/PDFQuickFix.app || true
