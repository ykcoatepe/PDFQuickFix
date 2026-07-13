# PDFQuickFix CLI Reference

`PDFQuickFixCLI` exposes inspection, repair, single-file sanitization, and batch sanitization for local automation. It requires macOS 13 or later and uses the same `PDFCore` and `PDFQuickFixKit` frameworks as the app.

## Build

Generate the Xcode project and build the CLI target:

```bash
make generate
./scripts/run_xcodebuild.sh -project PDFQuickFix.xcodeproj \
  -scheme PDFQuickFixCLI \
  -configuration Release \
  -derivedDataPath build \
  build
```

The binary is written to:

```text
build/Build/Products/Release/PDFQuickFixCLI
```

The examples below use:

```bash
CLI=build/Build/Products/Release/PDFQuickFixCLI
```

## Commands

### `inspect`

```text
pdfquickfix-cli inspect <input.pdf>
```

Parses the file with `PDFCore` and prints one compact JSON object.

| Field | Type | Meaning |
| --- | --- | --- |
| `file` | string | Input basename |
| `size` | integer | Input byte count |
| `pageCount` | integer | Page count reported by Core Graphics |
| `encrypted` | boolean | Whether Core Graphics reports encryption |
| `xrefType` | string | Currently always `unknown` |
| `hasObjStm` | boolean | Currently `false`; object streams are not exposed reliably |
| `revisions` | integer | Currently `0`, meaning unknown |

Example:

```bash
"$CLI" inspect Contract.pdf
```

### `repair`

```text
pdfquickfix-cli repair <input.pdf> <output.pdf> [--no-size-limit]
```

Runs `PDFRepairService` and prints its JSON result. `--no-size-limit` disables the repair service's normal input-size guard. Use it only when the machine has enough memory for the document.

Example:

```bash
"$CLI" repair damaged.pdf repaired.pdf
```

### `sanitize`

```text
pdfquickfix-cli sanitize <input.pdf> <output.pdf> \
  [--profile <privacy-clean|light-clean|keep-editable>] \
  [--preset <path>]
```

The default profile is `privacy-clean`. A preset overrides `--profile` regardless of argument order.

The command prints compact JSON with:

| Field | Type | Meaning |
| --- | --- | --- |
| `profile` | string | Swift profile value: `privacyClean`, `lightClean`, or `keepEditable` |
| `inputBytes` | integer | Source byte count |
| `outputBytes` | integer | Written output byte count |
| `pageCount` | integer | Output page count |
| `searchableText` | boolean | Whether trimmed extractable text exists in the output |
| `output` | string | Output basename |

Example:

```bash
"$CLI" sanitize Contract.pdf Contract-sanitized.pdf --profile privacy-clean
```

### `sanitize-batch`

```text
pdfquickfix-cli sanitize-batch <inputDir> <outputDir> \
  [--profile <privacy-clean|light-clean|keep-editable>] \
  [--preset <path>] [--recursive] [--dry-run] [--overwrite]
```

| Option | Default | Effect |
| --- | --- | --- |
| `--profile <name>` | `privacy-clean` | Selects the sanitize profile |
| `--preset <path>` | none | Loads a versioned JSON preset and overrides `--profile` |
| `--recursive` | off | Descends into subdirectories and preserves relative paths |
| `--dry-run` | off | Produces a plan/report without writing outputs |
| `--overwrite` | off | Replaces existing destination files instead of skipping them |
| `--help`, `-h` | n/a | Prints command help and exits successfully |

Progress is written to standard error. The sorted, pretty-printed JSON report is written to standard output, so automation can redirect JSON without mixing in progress messages.

The report includes input and output directories, profile, recursion and dry-run flags, processed/skipped/failed totals, elapsed milliseconds, and per-file results. Each file result includes relative input/output paths, status, optional byte counts, optional searchability, optional elapsed time, and an error message when processing failed.

Recursive mode rejects an output directory inside the input directory. Hidden files, package contents, symlinked directories, and non-PDF files are skipped. Existing outputs are skipped unless `--overwrite` is present.

Example:

```bash
"$CLI" sanitize-batch "$HOME/Documents/PDFs" "$HOME/Documents/Sanitized" \
  --profile light-clean --recursive > batch-report.json
```

## Profiles and presets

Profile names accept camel case, kebab case, or underscore-separated input. The documented kebab-case forms are preferred.

| Profile | Structure | Metadata and outlines | Search/edit expectation |
| --- | --- | --- | --- |
| `privacy-clean` | Rasterizes every page | Scrubs metadata and removes outlines | Not searchable; not structurally editable |
| `light-clean` | Rebuilds PDF data | Scrubs metadata, sanitizes annotations, removes outlines | Searchable text may remain |
| `keep-editable` | Keeps the current structure | Scrubs metadata and removes outlines; annotations remain | Intended to preserve editing/form affordances |

Preset schema version `1` contains a non-empty name and a camel-case profile value:

```json
{
  "version": 1,
  "name": "Searchable outbound",
  "profile": "lightClean"
}
```

Missing `version` is treated as version 1. Future versions are rejected.

## Exit behavior

- Success exits with status `0`.
- Missing arguments, unknown commands/options/profiles, unreadable inputs, invalid presets, write failures, and repair/sanitize errors exit nonzero.
- `sanitize-batch` exits nonzero when one or more files fail. Skipped files alone do not make the command fail.

## Related

- [Sanitize for Sharing](sanitize-for-sharing.md)
- [Cleanup Evidence](cleanup-evidence.md)
- [Architecture](architecture.md)
