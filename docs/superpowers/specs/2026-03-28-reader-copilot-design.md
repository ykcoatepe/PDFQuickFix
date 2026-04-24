## PDFQuickFix Reader Copilot Design

Date: 2026-03-28
Status: Proposed
Scope: Extend the existing product without changing the current Reader, QuickFix, Studio, and Split information architecture.

### Goal

Add a Reader-first document copilot that helps the user understand open PDFs faster, while preserving PDFQuickFix's current positioning as a local Acrobat Pro replacement. The new capability should feel native inside Reader, use local LLMs by default, and reuse shared AI infrastructure so the same core can later power richer QuickFix experiences.

### Product Direction

PDFQuickFix remains a power-user PDF workspace. The new differentiator is local document intelligence, not a separate AI product. Reader becomes the primary surface for fast comprehension tasks, while QuickFix remains the home for heavier AI and document-processing workflows.

### Current-State Constraints

- The app already has four top-level modes: Reader, QuickFix, Studio, and Split.
- Reader already contains right-panel state (`isRightPanelVisible`) and document lifecycle logic in `ReaderControllerPro`.
- QuickFix already owns OCR, local AI tasks, AI activity logging, and model configuration.
- The product has recently focused on stability in QuickFix and split/merge workflows; this work should avoid broad structural churn.
- The app is local-first. Ollama-backed LLM usage is the default model path.

### User Problem

Today the user can process PDFs and run AI tasks, but the "understand this document while I read it" workflow is still too detached from the main reading experience. The user should not need to switch modes just to get a summary, ask a question, or explain a selected passage.

### Proposed Surface

Add a new Copilot section to the Reader right panel.

The Reader copilot supports these V1 interactions:

- Quick Summary: summarize the full document or an explicit page range
- Ask This Document: free-form questions grounded in the current PDF
- Explain Selection: explain or simplify the user's current text selection
- Current Page Digest: summarize the active page
- Key Sections: derive a lightweight section map from document content
- Jump to Cited Page: navigate from an answer back to cited pages

This keeps the reading workflow intact. The user opens a PDF, reads normally, and invokes lightweight intelligence in-context. QuickFix remains available for OCR, redaction, extraction, long-running AI jobs, and future deeper analysis.

### Interaction Model

#### Reader

- Reader stays the primary reading surface.
- The user opens the Copilot panel from the existing right-side panel affordance.
- Copilot exposes a small set of high-value actions and a question input.
- Responses render inline in the panel with page citations.
- Citation taps jump the document to the referenced page.

#### QuickFix

- QuickFix remains the heavy AI workspace.
- Reader-originated context can later be handed off to QuickFix for deeper or longer-running tasks.
- The first release does not move existing QuickFix tasks into Reader.

### Architecture

The system should be split into three layers so V1 starts Reader-first but the design naturally evolves into a shared dual-surface model.

#### 1. Shared AI Core

Introduce a document-intelligence service layer that is separate from Reader and QuickFix UI code.

Responsibilities:

- extract and normalize text from `PDFDocument`
- support scoped inputs such as current page, page range, or current selection
- chunk long documents into bounded segments
- retrieve the most relevant chunks for a given prompt
- build prompts for summary and Q&A tasks
- attach page-level citations to results
- call the configured local model
- record interactions in the existing AI activity store

This is the main seam that enables later reuse in both Reader and QuickFix.

#### 2. Reader Copilot Surface

Extend `ReaderControllerPro` and Reader-side views with minimal new state for:

- current copilot task
- user query
- in-flight request state
- latest answer payload
- citation navigation
- selection-aware context

The Reader surface should remain intentionally narrow and optimized for short-lived interactions.

#### 3. QuickFix AI Surface

QuickFix continues to own heavy AI and processing flows. Over time, the same shared core can support richer analysis features there without duplicating prompt, retrieval, and citation logic.

### Retrieval Strategy

V1 should not add a heavyweight indexing system.

Use bounded text extraction plus chunk retrieval:

- extract text per page or per small page window
- keep metadata tying each chunk to page numbers
- retrieve a limited set of chunks per request
- assemble prompts from those chunks and the user's question or task

This is materially better than the current `maxInputCharacters` truncation-only model and is sufficient for local-first Reader workflows.

### Citations and Trust

Answers should include page citations whenever the answer is grounded in document text. Trust is a core product property for this feature. A useful answer without traceability is weaker than a shorter answer with explicit page references.

V1 citation requirements:

- each answer includes one or more referenced pages when grounding exists
- citations are clickable
- clicking a citation navigates Reader to the corresponding page
- if grounding is weak or incomplete, the UI should indicate that rather than implying certainty

### V1 Scope

Ship the smallest set that creates a strong "Reader copilot" experience:

- Reader right-panel Copilot UI
- Quick Summary
- Ask This Document
- Explain Selection
- Current Page Digest
- Key Sections
- page citations with page-jump navigation
- chunked retrieval for long documents
- AI Activity logging for document-copilot interactions

### Explicit V1 Non-Goals

To keep the release focused, V1 does not include:

- full-document indexing or background vector storage
- multi-document knowledge bases
- autonomous agents that decide and apply document edits
- batch Q&A across many files
- moving structured extraction into Reader
- cloud dependencies as a default path
- automatic redact/split/fill recommendations that directly change the document

### V2 Expansion Path

Once V1 proves the Reader copilot surface, the next layer can extend the same shared core:

- selected-pages-only Q&A and summarization
- compare two documents
- send Reader context into QuickFix as a heavier task
- saved prompts and prompt presets
- richer section maps and semantic outlines
- session memory for a document review flow
- deeper QuickFix analysis powered by the same retrieval and citation stack

### Risks

#### Hallucinated or weakly grounded answers

Mitigation: require bounded retrieval, attach citations, and surface uncertainty instead of overstating confidence.

#### Performance on large PDFs

Mitigation: chunk by page ranges, cap retrieval sets, and avoid synchronous full-document prompt assembly on the main thread.

#### UI clutter in Reader

Mitigation: keep Copilot scoped to the existing right panel rather than introducing another top-level mode.

#### Product confusion between Reader and QuickFix

Mitigation: keep Reader focused on fast comprehension and QuickFix focused on heavier AI and document-processing workflows.

### Validation Plan

The first implementation should be considered complete only if it verifies:

- the Reader workflow remains stable for normal open, navigate, search, and save flows
- copilot requests work on short and long PDFs
- citations reliably navigate to the expected page
- selection-based explanation works with actual PDF selections
- AI activity logs capture Reader copilot interactions without breaking existing QuickFix logging
- large-document behavior remains responsive enough for normal reading

### Recommendation

Start with a thin Reader copilot surface backed by a shared document-intelligence core. This gives PDFQuickFix a stronger Acrobat replacement story immediately, keeps the user's main workflow in Reader, and creates a clean path to a future dual-surface model where Reader and QuickFix share the same AI foundation.
