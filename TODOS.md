# TODOs

## Product

- Balance the welcome screen and onboarding around everyday reading, reliable editing, and cleanup evidence.
- Investigate safe editing of remote-file bookmarks beyond PDFKit's verified serialization capabilities; preserve the current fail-closed behavior until round-trip fidelity is proven.
- Extend native interaction coverage for popup/list selection and note-popup editing across supported macOS versions.
- Investigate preserving implicit owner-access encryption restrictions without weakening the verified-save boundary.

## Workflows

- Add stronger outbound-copy workflows around sanitize presets and reviewable exports
- Add vertical preset packs only where they strengthen the cleanup wedge

## Repo

- Keep build artifacts out of tracked diffs
- Continue adding regression coverage around PDF repair, sanitize, and page operations

## Completed

- Finder Quick Action support for **PDFQuickFix/Sanitize PDF for Sharing**. **Released:** 1.1.0 (2026-07-13)
- README positioning for batch sanitize, CLI sanitize, and Finder sanitize surfaces. **Released:** 1.1.0 (2026-07-13)
