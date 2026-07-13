# PDFQuickFix Architecture

PDFQuickFix separates the macOS user interface, reusable PDF operations, low-level parsing, and command-line automation. The split keeps the privacy-critical sanitizer shared across interactive and scripted workflows while allowing Reader, Studio, QuickFix, and Split to own different user jobs.

## System map

```text
Finder service      SwiftUI app                         CLI
     |        Reader | QuickFix | Studio | Split         |
     +--------------------+------------------------------+
                          |
                 PDFQuickFixKit
          sanitizer | batch | repair services
                          |
                      PDFCore
             lexer | parser | writer | document
                          |
                PDFKit / Core Graphics
```

The generated Xcode project contains five targets:

| Target | Type | Responsibility |
| --- | --- | --- |
| `PDFQuickFix` | macOS app | SwiftUI/AppKit UI, document workflows, evidence, OCR, local AI |
| `PDFCore` | framework | Low-level PDF objects, lexing, parsing, writing, and structure inspection |
| `PDFQuickFixKit` | framework | Sanitization, batch planning/execution, presets, and repair services |
| `PDFQuickFixCLI` | command-line tool | Inspect, repair, sanitize, and sanitize-batch automation |
| `PDFQuickFixTests` / `PDFQuickFixUITests` | test bundles | Unit/regression coverage and cleanup-review UI coverage |

The app and frameworks target macOS 13. Unit and UI test bundles target macOS 14.

## App surfaces

- **Reader** owns opening, searching, annotating, signing, printing, document copilot, and inspection-first workflows.
- **QuickFix** owns OCR, redaction/replacement processing, local AI tasks, progress, and output packets.
- **Studio** owns page organization, richer visual editing, forms, outlines, metadata, measurements, and document health.
- **Split** owns split and merge jobs, presets, history, and Finder reveal actions.
- The **Finder service** accepts selected PDF file URLs, writes collision-safe sibling `-sanitized.pdf` copies, and presents a receipt.
- **File > Sanitize Folder…** runs the shared batch sanitizer and builds aggregate and per-file evidence.

Reader and Studio share document handoff state, but each controller owns its loading and editing lifecycle. `DocumentValidationRunner` centralizes open/validation progress and cancellation so those surfaces do not implement competing job-state rules.

## Sanitization boundary

All sanitize surfaces map a `SanitizeProfile` to `PDFDocumentSanitizer.Options` in `PDFQuickFixKit`:

```text
app export ----+
Finder service +--> profile --> sanitizer --> validation --> output
folder batch --+                                      |
CLI -----------+                                      +--> evidence/review in app flows
```

`privacyClean` rasterizes pages and removes editability/searchability. `lightClean` rebuilds PDF data and sanitizes annotations while trying to preserve text. `keepEditable` avoids a structural rebuild and retains annotations. Every profile scrubs metadata and removes outlines.

The sanitizer validates rendered pages after transformation. App flows then generate Cleanup Evidence and, where available, a before/after comparison. See [Cleanup Evidence](cleanup-evidence.md) for the receipt boundary.

## Local AI and network boundary

Document processing is local by default. The app sandbox permits user-selected file read/write, printing, and outbound network-client access.

The supported network paths are:

- Ollama on loopback `127.0.0.1:11434`
- LM Studio on loopback `127.0.0.1:1234`
- Optional Google Vision OCR over HTTPS when the user enables cloud fallback and supplies an API key

The local clients reject non-loopback hosts. Google Vision is the explicit exception to local-only processing. The API key is entered through a secure field and is not part of Cleanup Evidence.

The security check verifies that the app sandbox remains enabled, the entitlements file remains wired to the target, the network-server entitlement is absent, and ATS arbitrary loads are not enabled. It does not prove that every outbound request targets an approved host; source review and tests enforce the client-specific host rules.

## Build and verification

`project.yml` is the source of truth for generated Xcode targets and schemes.

```text
make generate              regenerate PDFQuickFix.xcodeproj
make security-check        validate sandbox/network configuration
make sanity-fast           run the local CI regression suite
make smoke-ocr-fallback    run deterministic OCR fallback coverage
make ui-test-cleanup-review run cleanup-review UI tests
make build                 build the Release app
```

GitHub Actions runs the OCR smoke, CI suite, cleanup-review UI tests, and a Release build on `main` pushes and pull requests.

## Design trade-offs

- PDFKit and Core Graphics provide native rendering and editing, but malformed or unusual PDFs need the separate `PDFCore`/repair path.
- A shared sanitizer prevents Finder, app, batch, and CLI behavior from drifting, but UI-only evidence remains outside `PDFQuickFixKit` because it depends on app models and PDFKit review surfaces.
- Local-first AI protects documents and works offline when providers are installed, but model setup and performance become the user's responsibility.
- Optional cloud OCR improves fallback coverage, but it changes the privacy boundary and therefore requires explicit enablement and a user-provided key.

## Related

- [Get started](getting-started.md)
- [CLI reference](cli-reference.md)
- [Sanitize for Sharing](sanitize-for-sharing.md)
- [Contributing](../CONTRIBUTING.md)
