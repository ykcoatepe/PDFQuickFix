Agent Guide — PDFQuickFix

Version: 2025-11-30 • Owner: CodeForge AI

0. Quickstart
   • `make bootstrap` (if available) or `brew install xcodegen`
   • `make generate` (or `xcodegen generate`)
   • `make build`
   • `make run` (or open `PDFQuickFix.xcodeproj` and run scheme)
   • `python -m .scripts.memory bootstrap` (if memory scripts exist, else skip)

1. Structure & Naming
   • `Sources/PDFQuickFix/`: SwiftUI macOS app, PDF tooling, utilities.
   • `libs/pdfcore/`: Core PDF parsing logic (COS objects, Lexer, Parser).
   • `libs/pdfquickfix-kit/`: Repair and recovery services.
   • `scripts/`: Shell helpers (`build.sh`, `setup.sh`, `ci_run.sh`).
   • `project.yml`: XcodeGen spec.
   • `build/`, `dist/`: Artifacts.
   • Swift: 4-space indent, CamelCase types, camelCase vars/funcs. SwiftUI MVVM.

2. Dev Commands
   • Build: `make build` (Release), `make debug` (Debug).
   • Run: `make run` (or via Xcode).
   • DMG: `make dmg`.
   • CI Local: `make ci-home`.
   • Lint: `swiftformat .` (if installed), `swiftlint` (if installed).
   • Test: `make sanity-fast` or `xcodebuild test`.

3. Repo Memory
   • `.codex/memory.json`: JSON memory for the agent.
   • `LOGBOOK.md`: Human-readable task log.

4. Security
   • No secrets in repo.
   • App Sandbox enabled (user-selected read/write).
   • Local processing only (no network).

5. Commit & PR
   • Conventional Commits (`feat:`, `fix:`, `chore:`).
   • PRs: Concise summary, screenshots for UI, `make build` verification.

6. CI Gate
   • Build must pass.
   • `make ci-cloud` runs on GitHub Actions.
   • Manual verification of OCR/redaction flows.

7. Troubleshooting
   • `xcodegen` issues: Check `project.yml`.
   • Build fails: Clean build folder, check `xcpretty` path.

8. Doc Control
   • Owner: CodeForge AI.
   • Update on material changes.
