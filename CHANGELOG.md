# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), 
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Reader and Studio now load the complete PDF outline, including headings beyond the former 500-item limit in very large manuals. Outline loading remains on demand for massive documents.
- Reader and Studio track native form and application edits, protect document/window close and quit with Save / Don't Save / Cancel, and retain edits if a replacement cannot open.
- Pending native text edits are committed before asynchronous document replacement or workbench changes. Cancelled or failed saves cannot authorize closing a dirty document.
- Save and export paths validate supported outline destinations, page counts, encryption and permission preservation before replacing a destination. Unsupported remote-bookmark edits and unverifiable owner-access saves now fail without overwriting the destination.
- Editable sanitization reliably removes outlines; removed bookmark entries no longer reappear during PDFKit serialization.
- Search callbacks from cleared queries or previous documents are ignored, and Reader's page counter follows native navigation and resets on close.
- Form controls now use the SDK's named checkbox, radio and push-button types, with serialized flag coverage.
- Release tags now run regression and OCR fallback checks before the shared build/security checks; the local build helper uses the same build entry point.
- Updated archived planning and shipped-feature labels, and documented how to run the optional manual performance harness.

## [1.1.0] - 2026-07-13

### Added
- Cleanup Evidence receipts for QuickFix and sanitize outputs with source/output SHA-256 hashes, document facts, OCR/redaction counters, warnings, and Passed/Review/Failed verdicts
- Before/after cleanup review with changed-page navigation, visual and text-layer comparison, and removed metadata labels
- Privacy-safe batch evidence manifests with aggregate and per-file verdicts, hashed identifiers, and no extracted text, metadata values, absolute paths, or raw errors
- Fuller Reader/Studio editing suite with save/write-back, password-protected PDF open, search, undo/redo, annotation editing, signature stamps, form design, bookmark editing, metadata cleanup, and persistent measurement tools
- Safer export workflows for optimized, metadata-clean, flattened, encrypted, image, text, selected-page, and sanitized copies
- Document Health share-readiness signals, metadata warnings, replacement/redaction overlay warnings, and exportable health reports
- Local AI redaction-candidate and share-readiness review tasks with grounded JSON output and page-selection support
- Finder Quick Action service: **PDFQuickFix/Sanitize PDF for Sharing** creates local `-sanitized.pdf` outbound copies from selected PDFs in Finder
- Finder sanitize receipt window with per-file status and automatic reveal of the first sanitized output
- Regression coverage for Finder pasteboard PDF filtering, collision-safe output names, and source-preserving sanitize writes
- Sanitize for Sharing guide covering Finder, app export, batch, CLI, profiles, and output review checks
- Local Ollama OCR overlay with automatic Vision fallback for redaction-safe flows
- QuickFix OCR provider selector (auto Local OCR vs Vision only)
- Local OCR model selection (qwen2.5vl/minicpm-v) with optional DeepSeek fallback
- Optional Google Vision OCR fallback (opt-in, API key required)
- Local AI tools (summary, translation, PII scan, field extraction)
- AI Activity log with optional persistence and prompt/response truncation
- Local OCR availability status in QuickFix Options
- OCR report (provider usage, fallbacks, empty OCR pages)
- Progress updates during QuickFix runs
- PNG/JPEG input support (image → searchable PDF)
- AI image preprocessing (auto-crop, deskew, enhancement) for photo OCR
- Per-task model picker in AI Tools
- AI request timeout setting and summary page selection

### Changed
- Finder sanitize receipts now expose detailed evidence and before/after review; batch receipts expose aggregate and per-file evidence when processed files are available
- The UI now uses `AppTheme` as its single design-token source
- Reader and Studio now protect export/save paths from leaking transient selection helpers or unsafe replacement/redaction text layers
- Encrypted-document validation and export paths now prefer unlocked snapshots so locked source files do not block safe outbound copies
- README and project docs now describe Finder, app-menu, batch, and CLI sanitize surfaces as shipped cleanup workflows
- Security checks validate sandbox entitlements and ATS settings; local AI provider URL validation restricts Ollama/LM Studio to loopback hosts. Optional Google Vision OCR remains an explicit cloud feature.
- Local OCR now retries prompts and caches results for stability/performance

## [1.0.0] - 2025-12-11

### Added

#### Reader Tab
- Open, Save As, and Print PDF documents
- Search inside PDF with result highlighting
- Thumbnails sidebar with continuous scroll
- Zoom and rotate controls
- Annotations: highlight selection, notes, rectangles
- Form filling (AcroForm) directly in the viewer
- Signature creation and stamping
- Manual redaction boxes with permanent apply
- OCR repair (Vision) for searchable text layer

#### QuickFix Tab
- Secure pattern-based redaction (IBAN, TCKN, PNR, TC- tail)
- Custom regex support for redaction
- Find → Replace visual edits (white patch + new text)
- OCR repair integration

#### Studio Tab
- Visual editing tools (text, shapes, images)
- Edit, select, move, and resize objects
- Page organization (insert, delete, reorder)
- Undo/redo support
- Context menus for quick actions

#### Performance
- Large document optimization (7500+ pages support)
- Streaming PDF loader for memory efficiency
- Virtual page provider for on-demand rendering
- Background task coordinator
- Memory pressure monitoring

### Technical
- macOS 13.0+ (Ventura) minimum deployment target
- Swift 5.9 with SwiftUI MVVM architecture
- PDFCore framework for low-level PDF parsing
- PDFQuickFixKit for repair services
- 23 unit tests covering core functionality
- GitHub Actions CI/CD pipeline
- App Sandbox with user-selected read/write access only
