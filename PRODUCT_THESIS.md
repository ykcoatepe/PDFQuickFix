# Product Thesis

## One-line thesis

PDFQuickFix should be a **local-first macOS PDF workstation with a strong everyday reader and reliable editing, cleanup, and sharing tools**.

The current product direction gives reading and editing equal weight. Large manuals must remain useful to navigate, and edits must survive saving without silently losing structure or protection.

## The job to be done

Users do not wake up wanting "another PDF editor."

They need to:
- read and navigate a long manual without artificial limits,
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

The differentiator is **dependable local document work**, from reading a large manual to preparing a sensitive outbound copy.

Winning means being trusted for:
- complete chapter navigation and accurate page/search state,
- clear save outcomes and protection against accidental loss of unsaved edits,
- permanent redaction,
- sanitization for sharing,
- local OCR repair,
- metadata cleanup,
- batch sanitize workflows,
- predictable local automation.

Reader and Studio are equally important parts of that workflow. Split/Merge and AI Tools should support them without fragmenting the document experience.

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
- hiding either everyday reading or batch/privacy workflows behind unrelated tools.

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

6. Navigation and persistence are product contracts
   A long outline must remain complete; page and search controls must describe the current document. Saving must preserve intended edits and document protection. Closing or replacing a document must not silently discard work.

## Near-term bets

- Fix demonstrated navigation, search lifecycle, and save/close defects before adding more tools.
- Validate complete outline loading and practical navigation against a representative large manual, alongside synthetic boundary tests.
- Prove bookmark, annotation, form, and encryption preservation with saved-and-reopened outputs.
- Turn Cleanup Evidence from a shipped receipt into a faster review decision: make warnings, changed pages, and next actions unmistakable.
- Make the CLI easier to build and install without weakening the shared sanitize contract.
- Add vertical presets only where they shorten repeated cleanup work without fragmenting the product.
- Keep privacy boundaries explicit whenever cloud OCR or persistent AI logs are enabled.
- Validate real outbound handoffs with representative sensitive-document fixtures, not feature-count demos.

## Success test

If a user asks, "Why should I use PDFQuickFix instead of another PDF app?", the answer should be immediate:

"Because I can read large PDFs comfortably, edit them reliably, and prepare sensitive documents for sharing without leaving my Mac."
