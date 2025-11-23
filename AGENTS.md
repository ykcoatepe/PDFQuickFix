# Repository Guidelines

## Project Structure & Module Organization
- `Sources/PDFQuickFix/`: SwiftUI macOS app, including UI (`QuickFixTab.swift`, `ReaderView.swift`), PDF tooling (`PDFQuickFixEngine.swift`, `PDFKitContainerView.swift`), and utilities.
- `scripts/`: Shell helpers (`build.sh`, `setup.sh`, notarization template). Prefer `make` targets over calling these directly.
- `project.yml`: XcodeGen spec; update this before modifying the generated `.xcodeproj`.
- `build/` and `dist/`: Generated artifacts (Release/Debug builds, DMG). Clean or ignore in commits.

## Build, Test, and Development Commands
- `make debug`: Regenerates the Xcode project, builds Debug configuration, and opens the app bundle for local smoke checks.
- `make build`: Produces a Release build at `build/Build/Products/Release/PDFQuickFix.app`.
- `make dmg`: Builds Release and packages a distributable DMG in `dist/PDFQuickFix.dmg`.
- Ensure `xcpretty` is on `PATH` via `~/.gem/ruby/2.6.0/bin` for readable build logs.

## Coding Style & Naming Conventions
- Swift sources follow SwiftUI defaults: 4-space indentation, camelCase for identifiers, `UpperCamelCase` for types, and `lowerCamelCase` for functions/variables.
- Keep SwiftUI view structs lightweight and split reusable logic into helpers in `Utilities.swift`.
- Use `project.yml` to set bundle identifiers, versions, and signing; run `xcodegen generate` (or a `make` target) after changes.

## Testing Guidelines
- No automated test target exists yet. Before merging feature work, run a manual pass: import sample PDFs, verify OCR/redaction flows, and confirm DMG contents.
- When adding tests, prefer XCTest in a new `Tests/` target and mirror source file names (e.g., `QuickFixTabTests.swift`).

## Commit & Pull Request Guidelines
- Follow conventional commits already in history (`chore:`, `feat:`, `fix:`). Scope optional but encouraged (e.g., `feat(reader): add manual redactions`).
- PRs should include: concise summary, key screenshots for UI changes, build command output if relevent, and references to GitHub issues (`Fixes #123`).
- Run `make build` (or relevant smoke checks) before requesting review; attach DMG links for release-focused PRs.
