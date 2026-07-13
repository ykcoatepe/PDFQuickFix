# Contributing to PDFQuickFix

Thanks for your interest!

## Prereqs
- Xcode 15+
- Homebrew
- `xcodegen` (`brew install xcodegen`)

## Build
```bash
make bootstrap
make generate
make build
make run
```

## Validate
```bash
make sanity-fast
make smoke-ocr-fallback
make build
```

`make ci-home`, `make ci-cloud`, and `make sanity-fast` currently run the same unit/regression script. Run `make ui-test-cleanup-review` when changing Cleanup Evidence or its UI. Before a release or packaging change, also run:

```bash
codesign --verify --deep --strict build/Build/Products/Release/PDFQuickFix.app
```

Optional non-mutating style checks, when the tools are installed:

```bash
swiftformat --lint .
swiftlint --strict
```

## Branching
- `main`: stable and the default branch
- feature branches: `feat/*`
- bugfix branches: `fix/*`
- automation branches commonly use `codex/*`

## Commit style
Conventional Commits (e.g., `feat: add QuickFix sheet`).

## PRs
- Describe the change, screenshots welcome.
- CI must be green.
- If you touch docs or product copy, keep [README.md](README.md), [agent.md](agent.md), and the linked project docs in sync.

## Project docs

- `docs/README.md` for the Diataxis documentation index
- `docs/getting-started.md` for the first-build and first-output tutorial
- `docs/sanitize-for-sharing.md` for interactive and batch cleanup tasks
- `docs/cli-reference.md` for CLI commands and machine-readable output contracts
- `docs/cleanup-evidence.md` for receipt, verdict, and privacy-safe manifest contracts
- `docs/architecture.md` for module and security boundaries
- `README.md` for the user-facing feature map and documentation index
- `CHANGELOG.md` for release notes and user-visible changes
- `agent.md` for repo structure, commands, and release expectations
- `DESIGN.md` for the shared visual system and UI direction
- `PRODUCT_THESIS.md` for product positioning and scope decisions
- `TODOS.md` for the active backlog
- `AUTOPLAN_REVIEW.md` for the archived April 2026 planning snapshot
- `LOGBOOK.md` for historical task notes, not current feature status
