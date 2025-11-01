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

## Roadmap (optional)
- Page organizer (insert/delete/move/rotate, merge/split)
- Batch actions + Finder Quick Action
- Digital ID signing (PAdES-Basic) + validation UI
- Compress/optimize (image downsampling, grayscale, metadata scrub)
- Template packs for aviation and finance docs

MIT license for the starter. Verify outputs for your compliance needs.
