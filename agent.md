Agent Guide — PDFQuickFix

Version: 2026-07-13 • Owner: CodeForge AI

0. Quickstart
   • `make bootstrap` (if available) or `brew install xcodegen`
   • `make generate` (or `xcodegen generate`)
   • `make build`
   • `make run` (or open `PDFQuickFix.xcodeproj` and run scheme)

1. Structure & Naming
   • `Sources/PDFQuickFix/`: SwiftUI macOS app, PDF tooling, utilities.
   • `Sources/PDFQuickFixCLI/`: Local CLI entrypoints for inspect, repair, sanitize, and batch sanitize workflows.
   • `docs/`: Tutorials, how-to guides, technical reference, architecture explanations, and archived plans/specs.
   • `libs/pdfcore/`: Core PDF parsing logic (COS objects, Lexer, Parser).
   • `libs/pdfquickfix-kit/`: Repair and recovery services.
   • `scripts/`: Shell helpers (`build.sh`, `setup.sh`, `ci_run.sh`).
   • `project.yml`: XcodeGen spec.
   • `build/`, `build_*/`, `dist/`: Artifacts and local build output.
   • Swift: 4-space indent, CamelCase types, camelCase vars/funcs. SwiftUI MVVM.

2. Dev Commands
   • Build: `make build` (Release), `make debug` (Debug).
   • Run: `make run` (or via Xcode).
   • DMG: `make dmg`.
   • CI Local: `make ci-home`.
   • Security: `make security-check` (runs automatically from `make build` / `make debug`).
   • Optional lint: `swiftformat --lint .`, `swiftlint --strict` (if installed).
   • Test: `make sanity-fast`; use `make ui-test-cleanup-review` for cleanup-review UI changes.

3. Repo Memory
   • `.codex/memory.json`: JSON memory for the agent.
   • `LOGBOOK.md`: Human-readable task log.

4. Security
   • No secrets in repo.
   • App Sandbox enabled (user-selected read/write).
   • Local processing by default; local-only client access is allowed for Ollama/LM Studio on loopback hosts.

5. Commit & PR
   • Conventional Commits (`feat:`, `fix:`, `chore:`).
   • PRs: Concise summary, screenshots for UI, `make build` verification.

6. CI Gate
   • Build must pass.
   • GitHub Actions runs `make smoke-ocr-fallback`, `make ci-cloud`, `make ui-test-cleanup-review`, and `make build`.
   • `make smoke-ocr-fallback` proves deterministic OCR fallback behavior.
   • `make ui-test-cleanup-review` verifies the Cleanup Evidence review UI.
   • Manual verification of OCR/redaction flows.

7. Troubleshooting
   • `xcodegen` issues: Check `project.yml`.
   • Build fails: Check `xcodebuild -version`, `xcode-select -p`, and logs under `build/logs/` before cleaning. `xcpretty` is optional.
   • `XCODEBUILD_LOG_TAIL_LINES=200 make sanity-fast` prints a longer captured-log tail.
   • `XCODEBUILD_USE_CLANG_WRAPPER=0 make sanity-fast` disables the repository's Xcode 26.4 compiler-probe workaround for diagnosis.

8. Doc Control
   • Owner: CodeForge AI.
   • Start at `docs/README.md`; keep user flows, CLI contracts, evidence schema, and architecture docs aligned with code and tests.
   • Update on material changes.
