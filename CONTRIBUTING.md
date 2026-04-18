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
make ci-home
make sanity-fast
```

## Branching
- `master`: stable
- feature branches: `feat/*`
- bugfix branches: `fix/*`
- automation branches commonly use `codex/*`

## Commit style
Conventional Commits (e.g., `feat: add QuickFix sheet`).

## PRs
- Describe the change, screenshots welcome.
- CI must be green.
- If you touch docs or product copy, keep [README.md](README.md), [agent.md](agent.md), and the linked project docs in sync.
