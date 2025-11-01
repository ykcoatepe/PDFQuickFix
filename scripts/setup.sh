#!/usr/bin/env bash
set -euo pipefail
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
brew list create-dmg >/dev/null 2>&1 || brew install create-dmg || true
xcodegen generate
echo "✅ Setup complete. Next: make build"
