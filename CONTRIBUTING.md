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

## Branching
- `main`: stable
- feature branches: `feat/*`
- bugfix branches: `fix/*`

## Commit style
Conventional Commits (e.g., `feat: add QuickFix sheet`).

## PRs
- Describe the change, screenshots welcome.
- CI must be green.
