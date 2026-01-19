# Implementation Plan: Ollama DeepSeek OCR Integration (Fallback to Vision)
Last updated: 2026-01-18
Status: Implemented (Done)

## 1) Executive Summary
- **Goal:** Add an OCR backend using `deepseek-ocr:3b` via Ollama, auto-prefer it when available, and automatically fall back to the current Vision OCR when Ollama/model is unavailable or fails. Also add a multi-model local AI layer for summary/translation/PII detection/extraction with a user-visible AI interaction log.
- **Why now:** You’re installing a local OCR model and want higher-quality OCR on scanned PDFs while keeping PDFQuickFix’s “local-first” posture.
- **Who benefits:** Users who rely on OCR Repair (searchable text layer), pattern redaction, and Find→Replace on scanned documents.
- **High-level approach (1–3 bullets):**
  - Introduce an OCR provider abstraction (Vision = fallback, Ollama DeepSeek = preferred when available).
  - Add robust availability detection + timeouts; on failure, fall back to Vision transparently.
  - Make DeepSeek auto-preferred when available, with a UI toggle/picker to override.
- **Key risks (top 3):**
  - macOS App Sandbox constraints: without `com.apple.security.network.client`, the app likely cannot call Ollama’s local HTTP API (even on `127.0.0.1`).
  - Output format: DeepSeek OCR must provide layout (bounding boxes) to support redaction and Find→Replace accurately.
  - Performance/UX: OCR is per-page; LLM OCR may be significantly slower and can hang without strict timeouts/cancellation.
- **Target milestones (high-level):**
  - Discovery: validate sandbox feasibility + DeepSeek OCR output shape
  - Design: provider interface + parsing + matching strategy
  - Build: provider implementations + engine integration + UI
  - Hardening: tests, timeouts, error handling, docs

## 2) Scope
### In Scope
- Add an OCR provider abstraction used by `PDFQuickFixEngine`.
- Add an Ollama/DeepSeek OCR provider with availability detection.
- Add a user-facing option to enable/disable and see “available/not available” status.
- Transparent fallback to current Vision OCR when Ollama is unavailable/fails.
- Allow OCR runs from image inputs (PNG/JPEG) by importing images and running OCR to produce a searchable PDF (or extracting text for AI tools).
- Add optional AI-assisted image preprocessing (auto-crop + deskew) for image inputs prior to OCR.
- Add a local AI task layer (summary, translation, PII detection, field extraction) that uses Ollama models.
- Add settings to choose the default local AI model and optionally override per-task.
- Add in-feature model selection for AI tasks (per-task override from the AI Tools pane).
- Add an in-app AI interaction log so users can see prompts, responses, model, timing, and errors.
- Add a user-configurable AI request timeout and allow summary on selected pages.
- Tests for selection/fallback behavior (using mocks, not real Ollama).
- Documentation updates (README + troubleshooting).

### Out of Scope
- Bundling Ollama or `deepseek-ocr:3b` with the app.
- Supporting remote Ollama hosts or any non-local inference.
- Full document-layout preservation (tables, reading order) beyond existing behavior.
- Model fine-tuning or OCR quality benchmarking beyond basic acceptance checks.
- Auto-redaction based on LLM-provided boxes (redaction remains Vision-backed for correctness).

### Assumptions
- The preferred user experience is: “If Ollama DeepSeek OCR is available, use it automatically; otherwise use Vision.”
- OCR integration must not reduce correctness of secure redaction (i.e., never skip redaction due to OCR failure).
- If DeepSeek OCR cannot provide bounding boxes reliably, we may limit its use to “searchable layer only” (no pattern-based redaction / Find→Replace).
- Default local AI model for text tasks should prioritize speed/latency over raw quality; current local default: `deepseek-r1:8b` with optional selection of heavier models in Settings.
- DeepSeek OCR via Ollama accepts image inputs (PNG/JPEG), enabling image → OCR → searchable PDF flows.

### Constraints
- Current repo policy: “local-only (no network)” and build-time security checks that fail if network entitlements are added (`scripts/security_check.sh`). This plan assumes we will update policy + checks to allow **local-only** Ollama calls.
- DeepSeek-OCR via Ollama requires version 0.13.0+ and is sensitive to prompt formatting (newlines/punctuation). citeturn0search0
- Recommended prompts include `<|grounding|>` for layout-aware output; “Free OCR.” / “Extract the text in the image.” for plain text. citeturn0search0
- App Sandbox is enabled with user-selected file access only (`Sources/PDFQuickFix/PDFQuickFix.entitlements`).
- Target: macOS 13+.

## 3) Success Criteria
- **Functional acceptance criteria:**
  - When the model is available, OCR runs auto-prefer DeepSeek for recognition.
  - When Ollama/model is not available, OCR runs automatically fall back to Vision with no crash and a clear non-blocking status message.
  - Secure redaction and Find→Replace continue to function correctly; OCR failure never results in unredacted sensitive content.
  - Users can run AI tasks (summary, translation, PII detection, extraction) using local models without leaving the machine.
  - Users can view AI interaction history for a run (prompt, response, model, duration).
- **Non-functional requirements (NFRs):** (performance, reliability, security, privacy, cost)
  - OCR is bounded by timeouts (per page + per document); no indefinite hangs.
  - AI tasks use a user-configurable timeout to avoid long-running stalls.
  - No document content leaves the machine; no remote endpoints are used.
  - Fallback is deterministic and logged (reason + provider chosen).
  - Auto-preferred behavior is deterministic and can be overridden in UI.
  - AI task calls have timeouts and cancellation; large documents do not block the UI.
- **Observability criteria:** (metrics, logs, traces, dashboards, alerts)
  - Log selected OCR provider per run and any fallback reason (e.g., “model missing”, “timeout”, “parse error”).
  - Optional: surface a short “OCR provider status” line in UI (Available/Unavailable + reason).
- **Operational criteria:** (on-call readiness, runbooks, rollback)
  - Rollback = disable toggle; no migrations required.
  - Troubleshooting steps documented (install Ollama, pull model, verify availability).
  - AI interaction log is scoped per run/session and can be cleared.

## 4) Current State
- **Existing architecture/components:**
  - `Sources/PDFQuickFix/PDFQuickFixEngine.swift` uses Vision (`VNRecognizeTextRequest`) for OCR.
  - OCR output drives: (a) searchable invisible text overlay and (b) pattern redaction + Find→Replace bounding boxes.
- **Relevant systems/integrations:**
  - App Sandbox is enabled; network entitlements are explicitly disallowed by `scripts/security_check.sh`.
- **Data flows & storage:**
  - Pages are rasterized into `CGImage`, OCR’d, then redactions/replacements are burned into a bitmap and exported to a new PDF.
- **Known pain points/limitations:**
  - Vision OCR quality varies across fonts/scans; users may want an alternative OCR engine.
  - Without bounding boxes from OCR, redaction and replacement cannot be positioned correctly.
  - Local Ollama spike: line-level boxes appear with `<|grounding|>Extract the text in the image.` on simple layouts, but prompts are inconsistent and word-level boxes were not observed.

## 5) Proposed Solution Overview
### Architecture (Conceptual)
- **Key components:**
  - `OCRProvider` protocol: `recognize(image) -> OCRResult` (internal model containing text + bounding boxes).
  - `VisionOCRProvider` (wraps existing Vision path).
  - `OllamaDeepSeekOCRProvider` (calls Ollama + parses structured output).
  - `OCRProviderSelector`: chooses provider based on user preference + runtime availability; falls back to Vision.
  - `LocalAITaskRouter`: routes tasks to a selected Ollama model.
  - `OllamaModelRegistry`: discovers available local models and stores default selections.
  - `AIInteractionLog`: captures prompts/responses + metadata for UI display.
- **Interfaces/APIs:**
  - Provider interface must support: word/line boxes sufficient to build redaction rectangles and overlay searchable text.
  - With `<|grounding|>` prompts, DeepSeek-OCR outputs `<|ref|>` and `<|det|>` tags that include coordinate information for text elements; parsing must preserve mapping and order. citeturn0search1
  - Tag labels include element types like `title`, `text`, `image`, `table`, `formula`; we should map/ignore types consistently. citeturn0search6
  - Coordinates are normalized to a [0, 999] space with top-left origin; we must convert to pixel/point coordinates. citeturn0search8
  - **Hybrid decision:** use DeepSeek for OCR overlay only when no redaction/Find→Replace is active; Vision remains the source of truth for redaction/Find→Replace boxes.
  - AI tasks should return structured JSON when possible (summary + key fields), with robust parse failure handling and fallback to “plain text” when needed.
  - If DeepSeek only yields plain text, define a “search-only mode” that bypasses redaction/replace features when DeepSeek is selected.
- **Data model changes:**
  - Add an OCR provider setting to QuickFix options (e.g., `ocrProvider = .vision | .ollamaDeepSeek`), plus optional config (timeout/model name).
- **Security & access control:**
  - Allow local Ollama access via network entitlement; enforce local-only usage in code.
  - Enforce local-only usage in code: reject non-local Ollama hosts; clear env vars that redirect Ollama.
- **Failure modes & resilience:**
  - Ollama missing / model missing / server down → fallback to Vision.
  - Output parse failure / invalid boxes → fallback to Vision.
  - Timeout → fallback to Vision (and record reason).

### Tradeoffs Considered
- **Option A: Call Ollama HTTP API from the app**
  - Pros: simplest implementation, no external helper.
  - Cons: likely requires `com.apple.security.network.client` (breaks current security gate and “no network” promise).
- **Option B: Run `ollama` CLI from the sandboxed app**
  - Pros: avoids adding URLSession code.
  - Cons: may still be blocked because sandbox restrictions typically apply to child processes; also harder to guarantee local-only.
- **Option C: Dedicated helper (XPC/service) with narrowly scoped responsibility**
  - Pros: main app can remain “no network”; helper does the Ollama call.
  - Cons: higher engineering complexity; still introduces a component with network entitlement unless Ollama offers non-network IPC.
- **Decision + rationale**
  - **Option A (direct local Ollama HTTP)** with automatic fallback to Vision, because you approved adding network entitlement so long as fallback is guaranteed.
  - **Hybrid overlay:** DeepSeek used only for OCR overlay when no redaction/Find→Replace is active; Vision used for redaction/Find→Replace to preserve correctness.
### What would change the decision (trigger conditions)
- If DeepSeek OCR cannot provide reliable bounding boxes, we restrict its usage to “searchable layer only”.

## 6) Work Breakdown Structure
Provide a phased plan with epics and tasks. Include dependencies and acceptance criteria.

### 6.1 Phases & Milestones
- **Phase 0 — Discovery/Alignment:** Validate DeepSeek output format feasibility
- **Phase 1 — Design:** OCRProvider API + parsing contract + UX spec
- **Phase 2 — Build:** Implement providers + selection/fallback + integrate with engine/UI
- **Phase 3 — Test & Hardening:** Unit tests, timeouts/cancellation, regression checks, docs
- **Phase 4 — Rollout:** Ship opt-in, add troubleshooting, gather feedback
- **Phase 5 — Post-Launch:** Improve prompts/parsing, performance, expand language/layout support

### 6.2 Detailed Task Plan (Table)
| ID | Status | Work Item | Owner Role | Est. | Dependencies | Deliverables | Acceptance Criteria |
|---:|--------|-----------|------------|------|--------------|--------------|--------------------|
| P0.1 | Done | Confirm desired behavior: where DeepSeek OCR is used (OCR layer only vs also redaction/replace) | PM/Eng Lead | S | — | Requirements note | Decision documented and shared |
| P0.2 | Done | Update security policy + checks to allow local Ollama access (network entitlement) | macOS Eng | S | — | Updated entitlements + `security_check.sh` | Build passes security checks with local-only policy enforced |
| P0.3 | Done | Evaluate `deepseek-ocr:3b` output: can it emit JSON with word/line bounding boxes? | macOS Eng | M | P0.1 | Spike notes + recommended prompt | Line-level boxes observed with `<|grounding|>Extract the text in the image.`; word-level boxes not observed |
| P1.1 | Done | Define `OCRProvider` protocol and internal OCR result model (words/lines + boxes) | macOS Eng | M | P0.3 | Design doc + types | Design reviewed; supports current Vision features |
| P1.2 | Done | Design matching strategy: map regex/find→replace onto OCR result boxes | macOS Eng | M | P1.1 | Algorithm notes + examples | Redaction/replacement boxes are deterministic and testable |
| P1.3 | Done | Define UX: provider toggle/picker + “availability status” messaging | PM/Design | S | P0.1 | UI spec | UX reviewed; default auto-prefer behavior is clear |
| P2.1 | Done | Implement `VisionOCRProvider` wrapper returning internal OCR model | macOS Eng | M | P1.1 | PR with provider + adapter | Existing functionality unchanged (baseline tests pass) |
| P2.2 | Done | Implement `OllamaDeepSeekOCRProvider` (spike-chosen integration path) | macOS Eng | M | P0.2, P0.3, P1.1 | PR with provider + parsing | Provider returns valid boxes; errors are surfaced and recoverable |
| P2.3 | Done | Implement availability checks (Ollama installed, model present) + timeouts | macOS Eng | S | P2.2 | PR with checker + configuration | Unavailable states are detected quickly (<1s) |
| P2.4 | Done | Wire provider selection + fallback into `PDFQuickFixEngine` | macOS Eng | M | P2.1, P2.2, P1.2 | PR updating engine selection | On any provider failure, Vision path runs and output is produced |
| P2.5 | Done | Add UI controls to enable/disable DeepSeek OCR and show status | macOS Eng | S | P1.3, P2.3 | PR updating UI | Users can enable feature; UI reflects availability accurately |
| P2.6 | Done | Implement Ollama client + model registry for local AI tasks | macOS Eng | M | P1.3 | PR with model discovery + selection | Settings can list local models and select defaults |
| P2.7 | Done | Implement AI task router (summary/translation/PII detection/extraction) | macOS Eng | M | P2.6 | PR with task APIs + prompts | Tasks return structured outputs or plain text fallback |
| P2.8 | Done | Build AI Settings UI (default model + optional per-task overrides) | macOS Eng | S | P2.6 | PR with Settings UI | Users can select default AI model; overrides persist |
| P2.9 | Done | Build AI Interaction Log UI (per-run log of prompts/responses) | macOS Eng | M | P2.7 | PR with log view | Users can inspect model, task, prompt, response, timing |
| P2.10 | Done | Add AI Tools per-task model picker in the task pane | macOS Eng | S | P2.8 | UI update | Users can override the current task’s model without leaving the AI Tools tab |
| P2.11 | Done | Add AI timeout setting + summary page selection | macOS Eng | S | P2.7 | Settings + AI Tools update | AI tasks respect configurable timeouts; summary can target selected pages |
| P2.12 | Done | Accept PNG/JPEG inputs for OCR flows (import → OCR → searchable PDF) | macOS Eng | M | P2.4 | UI + pipeline update | Users can pick/drop images, optionally auto-crop/deskew, run OCR, and receive a searchable PDF output |
| P3.1 | Done | Add unit tests for provider selection/fallback using mocked providers | macOS Eng | S | P2.4 | Test PR | Tests pass and cover key fallback reasons |
| P3.2 | Done | Add “timeout & cancellation” hardening for long OCR runs | macOS Eng | M | P2.4 | PR with cancellation/timeouts | Large PDFs do not hang; cancellation stops work promptly |
| P3.3 | Done | Update docs: README + troubleshooting steps for Ollama model setup | PM/Eng | S | P2.5 | Docs PR | Setup instructions validated on a clean machine |
| P3.4 | Done | Add tests for AI task router + JSON parsing | macOS Eng | S | P2.7 | Test PR | Tasks handle malformed outputs gracefully |
| P3.5 | Done | Add tests for AI interaction logging (privacy + truncation rules) | macOS Eng | S | P2.9 | Test PR | Logs store only expected fields and sizes |
| P4.1 | Done | Rollout: ship feature auto-preferred when available + gather feedback on OCR quality | PM/Eng | S | P3.3 | Release note + feedback plan | No regressions; users can self-diagnose availability |
| P5.1 | Done | Post-launch: OCR quality + robustness improvements | macOS Eng | L | P4.1 | Follow-up PR(s) | Improved speed/accuracy without breaking fallback |
| P5.1a | Done | Image OCR quality pass (contrast normalization, shadow removal, DPI normalization) | macOS Eng | M | P5.1 | Preprocess pipeline update | Higher OCR accuracy on photo inputs; no regressions on scans |
| P5.1b | Done | DeepSeek prompt + parser hardening (adaptive prompts, retry on empty detections, improved box parsing) | macOS Eng | M | P5.1 | Prompt/parse update + tests | More stable detections; fewer empty/invalid runs |
| P5.1c | Done | Performance + caching (reuse OCR per page/image, throttle large inputs, progress estimates) | macOS Eng | M | P5.1 | Caching + UX update | Reduced runtime on large documents; predictable UI |
| P5.1d | Done | OCR quality metrics (confidence/empty pages/fallback reasons report) | macOS Eng | S | P5.1 | Metrics/report view | Users can diagnose OCR quality quickly |

### 6.3 Dependency Graph (Optional but Recommended)
- Critical path: P0.2 → P0.3 → P1.1 → P2.2 → P2.4 → P3.1
- Parallel tracks:
  - UX spec (P1.3) can run alongside provider/model design (P1.1).
  - Docs (P3.3) can start once UX language is finalized (P1.3).

### 6.4 Completion Checklist (Plan Hygiene)
- [x] Status column updated for tasks touched this go
- [x] "Last updated" line refreshed
- [x] Sub-plans summary updated and links valid (if sub-plans exist)
- [x] Completed sub-plans summarized and deleted (if applicable)

## 7) Testing & Quality Strategy
- **Test pyramid plan:** unit (selection/fallback + parsing) / integration (engine uses provider interface) / manual e2e (small sample PDFs with Ollama installed).
- **Test data & environments:**
  - Small scanned PDF fixtures for manual validation.
  - Unit tests use mocked provider outputs; no Ollama dependency in CI.
- **Performance testing:** (load, latency, capacity)
  - Measure per-page OCR latency and total processing time with/without DeepSeek.
  - Add “max pages / max DPI” guidance for DeepSeek mode if needed.
- **Security testing:** (threat model, SAST/DAST, access checks)
  - Threat model: ensure no accidental remote calls; reject non-local hosts.
  - Validate security gate behavior (and explicitly document/approve any policy changes).
- **Quality gates:** (lint, CI, code review, coverage thresholds if used)
  - `make ci-home` and `make security-check` must pass before enabling by default.

## 8) Rollout Plan
- **Release strategy:** auto-prefer DeepSeek when available; allow manual override in UI.
- **Migration strategy:** none.
- **Monitoring during rollout:** log provider usage + fallback reasons; spot-check sample documents.
- **Rollback plan:** disable toggle; fallback is automatic; no persistent state needed.
- **Communication plan:** update README and in-app tooltip: “Requires local Ollama + model installed.”

## 9) Operations
- **Runbooks:** “Ollama not found”, “Model not pulled”, “Timeouts”, “Parsing failed”.
- **On-call readiness:** not applicable (local app), but include a troubleshooting checklist.
- **SLOs/SLIs:** not applicable.
- **Cost considerations:** local-only compute; warn users that LLM OCR may be slower and CPU/GPU intensive.

## 10) Risks, Mitigations, and Contingencies
| Risk | Likelihood | Impact | Mitigation | Contingency/Trigger |
|------|------------|--------|------------|---------------------|
| Local-only policy regression via network entitlement | Medium | High | Enforce local-only host checks and update security gate | Disable DeepSeek mode if non-local detected |
| DeepSeek output lacks word/line-level boxes | Medium | High | P0.3 evaluate; require JSON contract | If missing, restrict DeepSeek to “search-only” OCR layer |
| OCR too slow / hangs on large PDFs | Medium | High | Strict timeouts + cancellation + UI messaging | Auto-fallback to Vision on timeout; provide guidance for DPI/pages |
| Privacy regression via remote Ollama host | Low–Med | High | Enforce local-only host in code; clear env overrides | Disable DeepSeek mode if non-local detected |
| AI interaction log exposes too much content | Medium | Medium | Truncate prompts/responses; allow user to clear logs | Make logging opt-in or scoped per run |

## 11) Open Questions
Prioritize questions that could change scope, sequencing, or architecture.
- None (decisions locked):
  - Use DeepSeek boxes for OCR overlay only; do not use them for redaction/Find→Replace.
  - Do not accept line/block boxes for redaction; Vision remains the source of truth.
  - DeepSeek used only for OCR overlay; Vision handles redaction/Find→Replace.
  - AI interaction logs are in-memory per run by default, with an opt-in setting to persist.

## 12) Sub-plans Summary
- (none)

## 13) Next Actions
- Top 5 actions to start execution immediately (by ID)
  - P5.1
