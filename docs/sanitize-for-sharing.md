# Sanitize for Sharing

Use Sanitize for Sharing when you need a safer outbound copy of a PDF while keeping the original untouched. The app, Finder Quick Action, batch sheet, and CLI all use the same sanitizer core, so choose the surface that fits the handoff.

For a first run from build to verified output, start with [Get Started with PDFQuickFix](getting-started.md). For every CLI flag and JSON field, use the [CLI reference](cli-reference.md).

## Surfaces

- Reader or Studio: **File > Export > Sanitize for Sharing...** for the open document.
- Finder: select one or more PDFs, then choose **Quick Actions > PDFQuickFix/Sanitize PDF for Sharing**.
- App batch flow: **File > Sanitize Folder...** for a directory of PDFs.
- CLI single file: `pdfquickfix-cli sanitize input.pdf output.pdf --profile privacy-clean`
- CLI folder: `pdfquickfix-cli sanitize-batch input-dir output-dir --profile light-clean --recursive`

## Profiles

| Profile | Best for | What it does |
| --- | --- | --- |
| `privacy-clean` | Highest privacy for external sharing | Rasterizes pages, removes outlines, and scrubs metadata. Output is not searchable by design. |
| `light-clean` | Searchable outbound copies | Rebuilds PDF data, sanitizes annotations, removes outlines, and scrubs metadata while preserving searchable text when possible. |
| `keep-editable` | Internal review copies that still need form/edit affordances | Keeps the current PDF structure, leaves annotations editable, removes outlines, and scrubs metadata. |

`privacy-clean` is the default for Finder, app export, and CLI sanitize flows. Use `light-clean` only when searchable text matters after handoff. Use `keep-editable` only when the recipient needs to continue editing or filling forms.

## Recommended Workflow

1. Work from a copy or use the app export flows that write a separate output file.
2. Apply redactions, replacements, metadata cleanup, or OCR repair before the final sanitize export.
3. Choose the strictest profile that still preserves the recipient's required workflow.
4. Save sanitized outputs outside the source folder when running recursive batch jobs.
5. Open the output and verify page count, readability, searchability expectations, and redaction coverage before sharing.

Reader, Studio, and the Finder receipt open a cleanup review after a successful single-file sanitized export. Use **Evidence** to inspect the selected profile, source/output hashes, file facts, removed metadata labels, and overall verdict. Use **Before / After** to move through changed pages and inspect the source snapshot beside the exported copy. **Export Evidence…** writes a privacy-safe JSON receipt; it stores counts, hashes, labels, and status only, never extracted document text or metadata values.

The app batch receipt shows aggregate and per-file Passed, Review, or Failed verdicts. **View Evidence** opens the detailed receipt for a processed file, while **Export Evidence…** writes one privacy-safe JSON manifest for the run. The manifest uses hashed file identifiers and basenames; it does not include absolute paths, extracted document text, metadata values, or raw processing errors.

## CLI Examples

Create a rasterized outbound copy:

```bash
pdfquickfix-cli sanitize Contract.pdf Contract-sanitized.pdf --profile privacy-clean
```

Create searchable outbound copies for a folder:

```bash
pdfquickfix-cli sanitize-batch ~/Documents/PDFs ~/Documents/Sanitized --profile light-clean --recursive
```

Plan a batch without writing files:

```bash
pdfquickfix-cli sanitize-batch ~/Documents/PDFs ~/Documents/Sanitized --dry-run --recursive
```

Use a preset file:

```json
{
  "version": 1,
  "name": "Searchable outbound",
  "profile": "lightClean"
}
```

```bash
pdfquickfix-cli sanitize-batch ~/Documents/PDFs ~/Documents/Sanitized --preset sanitize-preset.json
```

## Output Review Checklist

- Open the sanitized output, not the original.
- Confirm sensitive metadata is gone or no longer relevant to the handoff.
- Confirm expected redactions are visually present and original text is not extractable where redaction or replacement was used.
- Confirm `privacy-clean` outputs are intentionally not searchable.
- For `light-clean` or `keep-editable`, search for a few known safe terms and a few sensitive terms before sending.
- Keep the CLI JSON report or the app batch evidence manifest with the handoff record when working in batches.
- For Reader, Studio, Finder, or QuickFix exports, keep the Cleanup Evidence JSON receipt when the handoff needs a verifiable local audit record.

## Boundaries

Sanitize for Sharing reduces accidental data exposure; it is not a compliance guarantee. Always review the final output when handling regulated, legal, medical, financial, or otherwise sensitive documents.

Cleanup Evidence is also not a certification. See [Cleanup Evidence](cleanup-evidence.md) for its verdict rules, privacy boundary, and batch-manifest contract.
