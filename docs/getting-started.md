# Get Started with PDFQuickFix

You will build the macOS app, open a PDF, create a privacy-clean outbound copy, and verify the result without changing the original. By the end, you will also know where Reader, QuickFix, Studio, and Split fit.

## What you'll need

- macOS 13 or later
- Xcode 15 or later with Command Line Tools
- Homebrew
- A non-sensitive PDF you can use as a sample

Local AI is optional. The cleanup workflow in this tutorial does not require Ollama, LM Studio, an API key, or internet access.

## Step 1: Build and launch the app

From the repository root, run:

```bash
make bootstrap
make build
make run
```

`make bootstrap` installs XcodeGen when needed. `make build` regenerates the Xcode project, runs the repository security check, and creates `build/Build/Products/Release/PDFQuickFix.app`. `make run` opens that Release build.

You should see the PDFQuickFix window with **Reader**, **QuickFix**, **Studio**, and **Split** in the top mode switcher.

## Step 2: Open and inspect a PDF

1. Stay in **Reader** and choose **Open**.
2. Select the sample PDF.
3. Search for a known phrase and move through a few pages.

The document should remain readable and searchable. Reader is the inspection surface. Use **Studio** when you need page organization or visual editing, **QuickFix** for OCR and heavier cleanup jobs, and **Split** for split/merge workflows.

## Step 3: Create a safer outbound copy

Choose **File > Export > Sanitize for Sharing…**, select `privacy-clean`, and save to a new filename such as `sample-sanitized.pdf`.

The strict profile rasterizes the pages, removes outlines, and scrubs metadata. It intentionally gives up searchable text and editability for a smaller data-leak surface. The source PDF remains untouched.

After export, PDFQuickFix opens Cleanup Evidence and a before/after review. Confirm that the output page count is correct and review any page marked as changed.

## Step 4: Verify before sharing

In the review window:

1. Check the verdict. **Passed** means the automated checks found no condition that requires review. It is not a legal or compliance guarantee.
2. Inspect source and output SHA-256 hashes and page counts.
3. Open **Before / After** and inspect changed pages.
4. Use **Export Evidence…** if the handoff needs a local JSON receipt.
5. Open the sanitized PDF and confirm that expected sensitive text is no longer searchable.

The evidence receipt stores hashes, counts, labels, statuses, and warnings. It does not store extracted document text or metadata values.

## Step 5: Choose the next workflow

- Use [Sanitize for Sharing](sanitize-for-sharing.md) for Finder, batch, profile, and troubleshooting instructions.
- Use [CLI reference](cli-reference.md) for repeatable local automation.
- Use [Cleanup Evidence](cleanup-evidence.md) to interpret verdicts and JSON fields.
- Use [Architecture](architecture.md) to understand local processing, optional network paths, and module ownership.

## What you built

You now have a Release build and a separate sanitized outbound copy with a local review trail. The original PDF was not overwritten, and you verified the output instead of treating sanitization as an automatic guarantee.
