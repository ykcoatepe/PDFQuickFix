# Cleanup Evidence

Cleanup Evidence is a privacy-safe local receipt for a QuickFix or sanitize operation. It helps a person verify what changed without copying document contents into the audit record. It supports the app, Finder Quick Action, and folder batch review surfaces.

## The problem

A successfully written PDF is not proof that the intended cleanup happened. Page counts can change, metadata can remain, a text layer can survive a visual redaction, or a batch can contain skipped and failed files. Keeping full extracted text in a report would create a second sensitive-data store.

Cleanup Evidence records facts and comparisons instead: hashes, byte and page counts, searchable-text counts, metadata field names, annotation and outline counts, OCR counters, redaction-check counts, warnings, and a verdict.

## Review flow

```text
source PDF + output PDF
          |
          v
  document facts + SHA-256
          |
          +--> page comparison --> changed-page review
          |
          +--> redaction counters/status
          |
          v
 Passed / Review required / Failed
          |
          v
 optional privacy-safe JSON export
```

The before/after engine processes pages serially. It compares a bounded render and a SHA-256 fingerprint of normalized extractable text. It classifies each page as visually changed, text-layer changed, or unchanged. The report stores fingerprints and counts, not the normalized text.

## Verdicts

| Verdict | Meaning | Required action |
| --- | --- | --- |
| `passed` | Automated checks found no known review condition | Still spot-check the final output before a sensitive handoff |
| `reviewRequired` | A result is ambiguous or needs human inspection | Review warnings and changed pages before sharing |
| `failed` | Processing or a confirmed verification condition failed | Do not treat the output as ready to share |

Redaction candidate text found elsewhere in the output is `reviewRequired` by default because a string match does not prove that the original redaction location leaked. It becomes `failed` only after the caller marks the detection as a confirmed leak.

## Single-file schema

The current schema version is `1.0`.

| Field | Type | Description |
| --- | --- | --- |
| `schemaVersion` | string | Evidence schema version |
| `operationKind` | `quickFix` or `sanitize` | Operation that created the output |
| `sanitizeProfile` | string or null | Sanitization profile when applicable |
| `source`, `output` | object | Document facts for both files |
| `quickFixTelemetry` | object or null | Privacy-safe OCR/redaction counters |
| `comparison` | object or null | Compared, matching, changed page counts and maximum difference ratio |
| `redactionVerification` | object or null | Status and candidate counts |
| `verdict` | string | `passed`, `reviewRequired`, or `failed` |
| `warnings` | string array | Human-readable review conditions |
| `generatedAt` | date | Receipt generation time |

Each document-facts object contains `fileName`, `sha256`, `byteCount`, `pageCount`, `searchableTextPageCount`, `searchableTextCharacterCount`, `isEncrypted`, `metadataFieldLabels`, `annotationCount`, and `outlineCount`.

QuickFix telemetry contains counts for redaction rectangles, suppressed OCR runs, local/cloud/Vision/disabled/empty OCR pages, and local OCR fallbacks. It deliberately has no provider endpoint, model, credential, extracted-text, or metadata-value field.

## Batch manifest

The folder workflow builds a batch manifest from the batch plan and report. It includes the sanitize profile, totals, elapsed time, aggregate verdict, review count, and one status entry per planned file.

The export uses basenames and hashed identifiers. It excludes absolute paths, extracted document text, metadata values, and raw processing errors. A skipped, failed, not-processed, or evidence-unavailable entry stays visible so a partial run cannot look complete.

## How to review an output

1. Confirm the source and output hashes differ when cleanup was expected to change the file.
2. Confirm page counts match the intended operation.
3. Inspect every warning and every page classified as changed.
4. Confirm removed metadata labels match the handoff goal.
5. Search the output for sensitive terms when the selected profile preserves searchable text.
6. Treat `passed` as a technical signal, not a compliance certification.

## Trade-offs

- Hashes prove file identity, not correctness. Human review is still required for sensitive outputs.
- Low-resolution visual comparison keeps memory bounded but is not a forensic pixel comparison.
- Text fingerprints detect text-layer changes without retaining text, but they cannot explain the semantic meaning of a change.
- Omitting raw batch errors protects paths and sensitive context, but gives the exported manifest less debugging detail than the live app receipt.

## Related

- [Sanitize for Sharing](sanitize-for-sharing.md)
- [CLI reference](cli-reference.md)
- [Architecture](architecture.md)
