# Product Thesis

## One-line thesis

PDFQuickFix should become the best **local-first macOS workstation for cleaning up sensitive PDFs before they leave your machine**.

## The job to be done

Users do not wake up wanting "another PDF editor."

They need to:
- open a messy or risky PDF,
- inspect what is inside,
- repair broken structure or searchability,
- remove or obscure sensitive content,
- reorganize or split pages if needed,
- export a safer version they can share with confidence.

That is the whole game.

## Ideal customer profile

The best early customers are people who handle sensitive PDFs often enough that mistakes are expensive:
- operations teams sending contracts, manifests, reports, or internal packets,
- finance, travel, aviation, and compliance-adjacent users,
- consultants and small teams who want local processing instead of uploading documents to third-party web tools,
- power users who need repeatable folder-level cleanup, not just one-off edits.

## Wedge

The wedge is **privacy-first document cleanup**, not "general AI PDF editor."

Winning means being trusted for:
- permanent redaction,
- sanitization for sharing,
- local OCR repair,
- metadata cleanup,
- batch sanitize workflows,
- predictable local automation.

Reader, Studio, Split/Merge, and AI Tools should support that workflow, not compete to become separate product lines.

## Why this can win

The repo already has real leverage:
- app-level sanitize export,
- Finder Quick Action sanitize from selected PDFs,
- folder-level batch sanitize,
- CLI sanitize and sanitize-batch commands,
- local-first OCR and AI integration,
- PDF repair plus page organization and split/merge support.

That combination is more differentiated than a generic "chat with PDF" story.

## What not to do

Do not try to beat Acrobat, PDF Expert, or Foxit as a feature-checklist PDF editor.

Avoid:
- leading with generic AI assistant messaging,
- adding broad "me too" editor features that do not strengthen cleanup workflows,
- letting batch/privacy features stay hidden while surface-level editing features dominate the story.

## Product principles

1. Local by default
   Sensitive documents should stay on-device unless the user explicitly opts into fallback services.

2. Safer outbound copies
   The product should help users create a clean version for sharing, not just edit the original.

3. Trust through evidence
   Cleanup actions should be understandable, reviewable, and eventually auditable.

4. Batch matters
   Repeated folder-level work is part of the core product, not an edge case.

5. AI is assistive
   AI should help detect, extract, summarize, and repair. It should not become the main product story.

## Near-term bets

- Move sanitize/privacy messaging to the front of the README, landing copy, and release notes
- Make batch sanitize and CLI workflows impossible to miss
- Add clearer cleanup evidence: before/after summaries, report bundles, or export receipts
- Tighten the Finder Quick Action receipt into clearer cleanup evidence
- Add vertical presets where they improve speed without fragmenting the product

## Success test

If a user asks, "Why should I use PDFQuickFix instead of another PDF app?", the answer should be immediate:

"Because it is the fastest local way to repair, clean, redact, and prepare sensitive PDFs for safe sharing."
