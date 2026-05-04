#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT_YML="${ROOT_DIR}/project.yml"
INFO_PLIST="${ROOT_DIR}/Sources/PDFQuickFix/Info.plist"
ENTITLEMENTS_PLIST="${ROOT_DIR}/Sources/PDFQuickFix/PDFQuickFix.entitlements"

fail=0

if [[ ! -f "${PROJECT_YML}" ]]; then
  echo "❌ Missing ${PROJECT_YML}"
  exit 1
fi

if [[ ! -f "${INFO_PLIST}" ]]; then
  echo "❌ Missing ${INFO_PLIST}"
  exit 1
fi

if [[ ! -f "${ENTITLEMENTS_PLIST}" ]]; then
  echo "❌ Missing ${ENTITLEMENTS_PLIST}"
  exit 1
fi

if [[ -x /usr/libexec/PlistBuddy ]]; then
  if /usr/libexec/PlistBuddy -c "Print :com.apple.security.network.server" "${ENTITLEMENTS_PLIST}" >/dev/null 2>&1; then
    echo "❌ Network server entitlement present: com.apple.security.network.server (${ENTITLEMENTS_PLIST})"
    fail=1
  fi

  if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsArbitraryLoads" "${INFO_PLIST}" >/dev/null 2>&1; then
    echo "❌ ATS allows arbitrary loads: NSAppTransportSecurity:NSAllowsArbitraryLoads (${INFO_PLIST})"
    fail=1
  fi
else
  if grep -q "com.apple.security.network.server" "${ENTITLEMENTS_PLIST}"; then
    echo "❌ Network server entitlement present: com.apple.security.network.server (${ENTITLEMENTS_PLIST})"
    fail=1
  fi

  if grep -q "NSAllowsArbitraryLoads" "${INFO_PLIST}"; then
    echo "❌ ATS allows arbitrary loads: NSAllowsArbitraryLoads (${INFO_PLIST})"
    fail=1
  fi
fi

if grep -q "com.apple.security.network.server" "${PROJECT_YML}"; then
  echo "❌ Network server entitlement configured in project.yml: com.apple.security.network.server (${PROJECT_YML})"
  fail=1
fi

if ! grep -q "PDFQuickFix.entitlements" "${PROJECT_YML}"; then
  echo "❌ App target is not wired to PDFQuickFix.entitlements in project.yml"
  fail=1
fi

if ! grep -q "com.apple.security.app-sandbox: true" "${PROJECT_YML}"; then
  echo "❌ App Sandbox is not enabled in project.yml"
  fail=1
fi

if grep -q "NSAllowsArbitraryLoads" "${PROJECT_YML}"; then
  echo "❌ ATS allows arbitrary loads configured in project.yml: NSAllowsArbitraryLoads (${PROJECT_YML})"
  fail=1
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi

echo "✅ Security check passed (local-only defaults)"
