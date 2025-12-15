# PDFQuickFix (macOS)

A local, on‑device macOS app that **reads & annotates PDFs**, **redacts sensitive data**, performs **inline visual text edits**, and **repairs OCR** — a practical replacement for Adobe Acrobat *Reader* for personal use.

## What you get

**Reader tab**
- Open / Save As / Print
- Search inside PDF
- Thumbnails sidebar, continuous scroll, zoom
- Annotations: **highlight selection**, **notes**, **rectangles**
- **Form filling** (AcroForm) directly in the viewer
- **Sign**: create a reusable handwritten signature and **stamp** it anywhere
- **Manual redaction boxes**: place black boxes, then *Apply Permanent Redactions* (burned into the page bitmap)
- **OCR Repair**: one-click to add an invisible searchable text layer

**QuickFix tab**
- **Secure redaction** by patterns (IBAN, TCKN, PNR, TC- tail) + your own regex
- **Find → Replace** visual edits (white patch + new text)
- **OCR repair** (Vision) adds invisible text layer

> ✅ All processing is **local** (no network). App Sandbox with **user-selected read/write** only.

## Build (XcodeGen)
1. Install Xcode 15+ and Command Line Tools.
2. `brew install xcodegen`
   - Optional: `brew install xcpretty` (nicer `xcodebuild` logs; Makefile falls back if missing)
   - `make build` runs `./scripts/security_check.sh` and fails if network entitlement or ATS arbitrary loads are enabled
3. ```bash
   cd PDFQuickFix
   xcodegen generate
   open PDFQuickFix.xcodeproj
   ```
4. Run (**⌘R**) the **PDFQuickFix** scheme.

## Notes & limitations
- Supports standard **AcroForm** fields; **dynamic XFA** forms are not supported by PDFKit.
- Certificate-based digital signatures (PKCS#7/PAdES) are not included in this starter (visual signing only). Can be added later using SecKey + CMS.
- Page organize (merge/split/reorder) and export to PDF/A are possible next steps.

## Architecture updates
- Shared `QuickFixOptionsModel` / `QuickFixOptionsForm` now centralize the QuickFix tab and sheet option UI + regex/find/replace parsing so logging, validation, and manual redaction handling stay in sync.
- `DocumentValidationRunner` encapsulates the `PDFDocumentSanitizer` job lifecycle (open + validation, cancellation, progress guards) so ReaderView, ReaderControllerPro, and StudioController share consistent loading state rather than reimplement the job tracking in each controller.
- Tests now include `ReaderLoadingTests` that open a simple PDF through the reader/studio controllers and guard the runner, helping trace the freeze you saw when loading documents.

## Roadmap (optional)
- Page organizer (insert/delete/move/rotate, merge/split)
- Batch actions + Finder Quick Action
- Digital ID signing (PAdES-Basic) + validation UI
- Compress/optimize (image downsampling, grayscale, metadata scrub)
- Template packs for aviation and finance docs

MIT license for the starter. Verify outputs for your compliance needs.
## Profiling large PDFs

In Debug builds the app emits signposts and basic performance metrics.

- Use Instruments (Points of Interest or System Trace) and filter for the subsystem `com.pdfquickfix` and signpost names like:
  - `SanitizerOpen`
  - `ValidationQuick` / `ValidationFull`
  - `ReaderOpen`
  - `ReaderApplyDocument`
  - `StudioOpen`
  - `StudioFinishOpen`
  - `RenderThumbnail`
  - `RenderCacheHit`
  - `StudioEnsureThumbnail`
  - `StudioPrefetch`
  - `StudioPageChanged`
  - `PDFViewDocumentSet`

- When you open a document in the Reader/Studio (Debug), the console prints a summary like:

  ```text
  [PerfMetrics]
  thumbnails requested: 320
  thumbnails rendered:  280
  thumbnail cache hits: 40
  reader open avg:      85.2 ms (3 samples)
  studio open avg:      120.5 ms (3 samples)
  ```


Use this to compare branches and track regressions when working on large-document performance.

## Development
For detailed development instructions, architecture notes, and workflows, please refer to [agent.md](agent.md).
