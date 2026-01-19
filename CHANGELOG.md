# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), 
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Local Ollama DeepSeek OCR overlay with automatic Vision fallback for redaction-safe flows
- QuickFix OCR provider selector (auto DeepSeek vs Vision only)
- Local AI tools (summary, translation, PII scan, field extraction)
- AI Activity log with optional persistence and prompt/response truncation
- DeepSeek availability status in QuickFix Options
- OCR report (provider usage, fallbacks, empty OCR pages)
- Progress updates during QuickFix runs
- PNG/JPEG input support (image → searchable PDF)
- AI image preprocessing (auto-crop, deskew, enhancement) for photo OCR
- Per-task model picker in AI Tools
- AI request timeout setting and summary page selection

### Changed
- Security checks now allow local-only Ollama access (127.0.0.1) while still blocking non-local network use
- DeepSeek OCR now retries prompts and caches results for stability/performance

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
