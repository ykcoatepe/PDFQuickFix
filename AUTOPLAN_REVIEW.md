# Autoplan Review

Captured: 2026-04-18  
Branch: `codex/split-merge-workbench`  
Base branch: `master`

## Plan Summary

PDFQuickFix has grown into a capable desktop PDF tool, but its strongest advantage is not "general PDF editor" scope. The winning direction is a **privacy-first PDF cleanup workstation** for sensitive outbound documents, with Reader, Studio, Split/Merge, and AI Tools supporting that core job.

This review consolidates the strategy, design, and engineering work completed so far and turns it into an implementation path. The first applied slice is a shared visual direction across the app shell and the highest-traffic workbench entry surfaces.

## Decisions Made

- Reposition the product around local-first cleanup, sanitization, redaction, repair, and safe sharing
- Surface shipped sanitize and batch workflows as core product capabilities, not future work
- Adopt a single design thesis, `Forensic Desk`, for future UI work
- Use a phased implementation path instead of a broad visual rewrite
- Keep DX review out of scope for now because the product is user-facing, not developer-facing

## Review Scores

| Review | Score | Summary |
|--------|-------|---------|
| CEO | 8/10 | Strong product kernel, weak story before repositioning. The privacy-first wedge is much better than a generic AI PDF editor story. |
| Design | 7/10 | The app already has the right dark-shell instinct, but the visual system is fragmented across multiple token layers and uneven screen copy. |
| Eng | 7/10 | Core PDF workflows are strong, but repo hygiene and duplicated UI token systems create drag and noise. |
| DX | Skipped | No meaningful developer-facing scope for this review pass. |

## Cross-Phase Themes

- **Wedge clarity**: the product is strongest when framed as a local cleanup tool, not a broad feature-checklist PDF app
- **Hidden leverage**: sanitize export, batch sanitize, and CLI support were underrepresented in the product story
- **Visual fragmentation**: `AppTheme` and `AppColors` split the design language into two parallel systems
- **Signal vs noise**: tracked build artifacts have historically obscured the meaningful product diff

## What Already Exists

- Privacy and sanitization workflows in Reader/Studio export and batch sanitize flows
- Finder Quick Action support for creating sanitized outbound copies from selected PDFs
- Local OCR and local AI support with opt-in fallback behavior
- Split/Merge workbench with real operational capabilities
- A dark-shell UI direction already present in Reader and Split surfaces

## First Applied Slice

This autoplan run applies the first implementation slice directly:

1. Align shared UI tokens toward the new palette and tone
2. Update the main entry surfaces so they read like workbenches, not generic utility panels
3. Preserve minimal diffs while creating a clear base for later UI polish

Target files:
- `Sources/PDFQuickFix/AppTheme.swift`
- `Sources/PDFQuickFix/ContentView.swift`
- `Sources/PDFQuickFix/SplitView.swift`

## Deferred to TODOs

- Unify `AppTheme` and `AppColors` into one token source instead of two compatibility layers
- Add cleanup evidence surfaces, before/after summaries, and audit-style result bundles
- Carry the new product thesis into app copy, onboarding, and empty states more broadly
- Review the repo's remaining tracked artifact history and keep it clean going forward

## Decision Audit Trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|-------|----------|----------------|-----------|-----------|----------|
| 1 | CEO | Reframe product as privacy-first cleanup workstation | Mechanical | Choose completeness | Better matches shipped capabilities and competitive gap | Generic AI PDF editor framing |
| 2 | Design | Adopt `Forensic Desk` visual direction | Taste | Explicit over clever | Gives the app a serious, native, memorable identity | Trend-heavy AI styling |
| 3 | Eng | Apply a focused UI slice instead of full refactor | Mechanical | Bias toward action | Delivers visible improvement without stalling on architecture cleanup | Big-bang redesign |
| 4 | Eng | Leave full token convergence for later, but point both systems at the same palette now | Mechanical | Pragmatic | Reduces risk while improving consistency immediately | Parallel untouched token systems |

## Approval State

Approved for direct application in this branch.
