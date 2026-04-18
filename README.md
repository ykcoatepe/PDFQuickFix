# PDFQuickFix (macOS)

A local, on‑device macOS app for **reading, repairing, redacting, organizing, splitting, and merging PDFs** — with optional local AI tools for OCR and document workflows.

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

**Studio tab**
- Visual page organizer with **insert / delete / duplicate / reorder / rotate**
- Page thumbnails, drag-and-drop ordering, and quick actions
- Shared document handoff from Reader for edit/organize flows
- Large-document guards and background validation during open

**Split tab**
- Split PDFs by **max pages**, **number of parts**, **explicit page breaks**, **target size**, or **outline chapters**
- Merge multiple PDFs with source reordering, deduplication, blank-page insertion, and safe fallback policies
- Recent split/merge job history plus Finder reveal actions

**AI Tools tab**
- **Secure redaction** by patterns (IBAN, TCKN, PNR, TC- tail) + your own regex
- **Find → Replace** visual edits (white patch + new text)
- **OCR repair** (Local OCR by default, Vision fallback) adds invisible text layer
- **Local AI tools** (summary, translation, PII scan, field extraction)
- **Accepts PDF, PNG, and JPEG inputs** (images are converted to searchable PDFs during OCR)
- **Optional AI auto-crop, deskew, and enhancement** for image inputs (toggle in Options)
- **OCR report** with provider usage, fallback counts, and empty OCR pages
- **Progress updates** during QuickFix runs (pages processed)
- **Visible in the top mode switcher** (Reader | AI Tools | Studio | Split)

> ✅ All processing is **local** by default. When enabled, the app talks only to `127.0.0.1:11434` for Ollama. Optional **cloud OCR fallback** can be enabled in Options.

## Build (XcodeGen)
1. Install Xcode 15+ and Command Line Tools.
2. `brew install xcodegen`
   - Optional: `brew install xcpretty` (nicer `xcodebuild` logs; Makefile falls back if missing)
   - `make build` runs `./scripts/security_check.sh` and fails if non-local network entitlements or ATS arbitrary loads are enabled
3. ```bash
   cd PDFQuickFix
   xcodegen generate
   open PDFQuickFix.xcodeproj
   ```
4. Run (**⌘R**) the **PDFQuickFix** scheme.

## Local AI (Ollama) setup
1. Install Ollama and start it.
2. Pull models:
   - OCR: `ollama pull qwen2.5vl:7b` (recommended) or `ollama pull minicpm-v:8b`
   - Optional OCR fallback: `ollama pull deepseek-ocr:3b`
   - Text tasks (default): `ollama pull deepseek-r1:8b` (or any local model you prefer)
3. In **Settings → Local AI**, click **Refresh Models** and pick a default model.

### Notes
- Local OCR is used **only** for the OCR overlay when no redaction/Find→Replace/manual redactions are active.
- Redaction and Find→Replace always use Vision for correct boxes.
- AI Activity logs are in-memory per run by default; persistence is opt-in in Settings.
- AI Activity prompts/responses are truncated to keep logs lightweight.
- AI request timeout is configurable in **Settings → Local AI**.
- AI task models can be overridden per task in **AI Tools** or from **Settings → Task Overrides**.
- Local OCR availability status is shown in **Options** with a Refresh button.
- Cloud OCR fallback (Google Vision) is opt-in and requires an API key in Options.

## Troubleshooting (Ollama)
- **No models listed:** make sure Ollama is running and `ollama list` shows your models.
- **Local OCR not used:** confirm `qwen2.5vl:7b` or `minicpm-v:8b` is installed and OCR provider is set to Auto.
- **Local OCR status says Unavailable:** ensure Ollama is running, then click **Refresh** in Options.
- **AI tasks say “No local model available”:** open Settings, refresh, and select a default model.
- **Want to force Vision OCR:** set OCR engine to “Vision only” in AI Tools → Options.

## Feedback (OCR quality)
If you want to report OCR quality or performance, please include:
- Which OCR provider was used (Auto/Local/Cloud/Vision only)
- Model name and Ollama version
- Page count, DPI, and whether redaction/Find→Replace were enabled
- Any timeouts or fallbacks observed
- A short, non-sensitive sample screenshot or description of errors (avoid sharing sensitive content)

## User Test Plan (New Features)
Use this checklist to validate the new OCR/AI features end-to-end.

### Prerequisites
- Ollama running locally (`ollama serve`)
- Models installed:
  - `ollama pull qwen2.5vl:7b` (or `minicpm-v:8b`)
  - Optional: `ollama pull deepseek-ocr:3b`
  - `ollama pull deepseek-r1:8b` (or your preferred text model)

### OCR (Local + fallback)
1. Open a scanned PDF with **no redaction/Find→Replace/manual redactions**.
2. In AI Tools → Options, set **OCR engine** to **Auto (Local OCR if available)**.
   - Expected: Local OCR status shows **Available** (after Refresh if needed).
3. Run QuickFix.
   - Expected: Output PDF is searchable; OCR layer added.
4. Add any redaction rule (e.g., default patterns), run QuickFix again.
   - Expected: Vision OCR used for boxes; output remains searchable.
5. Stop Ollama (or remove the OCR model) and run QuickFix again.
   - Expected: Automatic fallback to Vision; no crash.
6. Enable **Cloud OCR fallback** and provide a valid Google Vision API key.
   - Expected: If local OCR fails, cloud OCR runs and output remains searchable.

### OCR from Images (PNG/JPEG)
1. In AI Tools, click **Choose PDF or Image…** and select a PNG or JPEG.
2. Run QuickFix.
   - Expected: Output PDF is created next to the image and is searchable.
3. Run an AI task (Summary/Translate/etc.).
   - Expected: OCR text is used to produce the AI result.
4. Optional: enable **Auto-crop & deskew images (AI)** in Options for better OCR on photos.

### AI Tools (Summary / Translate / PII / Extraction)
1. In Settings → Local AI, click **Refresh Models** and select a default model.
2. In the AI Tools tab, under **Local AI Tools**, run **Summary** on a text‑heavy PDF.
   - Expected: Summary output appears and is logged.
   - Optional: enter a page range (e.g. `1-2, 5`) to summarize selected pages only.
3. Run **Translation** with a target language.
   - Expected: Translated output appears.
4. Run **PII Scan** and **Field Extraction**.
   - Expected: JSON output (pretty‑printed when valid).

### AI Activity Log
1. Open **AI Activity** from the menu or the AI Tools tab.
2. Verify each AI run appears with task, model, and prompt/response.
3. Toggle persistence in Settings, restart the app, and confirm logs persist.
4. Turn persistence off and confirm logs clear.

## Notes & limitations
- Supports standard **AcroForm** fields; **dynamic XFA** forms are not supported by PDFKit.
- Certificate-based digital signatures (PKCS#7/PAdES) are not included in this starter (visual signing only). Can be added later using SecKey + CMS.
- Export to PDF/A, batch workflows, and stronger signing/validation are still future work.

## Architecture updates
- Shared `QuickFixOptionsModel` / `QuickFixOptionsForm` now centralize the QuickFix tab and sheet option UI + regex/find/replace parsing so logging, validation, and manual redaction handling stay in sync.
- `DocumentValidationRunner` encapsulates the `PDFDocumentSanitizer` job lifecycle (open + validation, cancellation, progress guards) so ReaderView, ReaderControllerPro, and StudioController share consistent loading state rather than reimplement the job tracking in each controller.
- Tests now include `ReaderLoadingTests` that open a simple PDF through the reader/studio controllers and guard the runner, helping trace the freeze you saw when loading documents.

## Roadmap (optional)
- Batch actions + Finder Quick Action
- Digital ID signing (PAdES-Basic) + validation UI
- Export to PDF/A
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
