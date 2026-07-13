# PDFQuickFix Documentation

Start here when the feature map in the project README is not enough. These documents separate learning, task instructions, technical facts, and design rationale so you can find the right level of detail quickly.

## Learn the product

- [Get started with PDFQuickFix](getting-started.md) is a tutorial that takes a new user from build to a verified sanitized copy.
- [Sanitize for Sharing](sanitize-for-sharing.md) is the task guide for one-file, Finder, folder, and CLI cleanup workflows.

## Look up technical details

- [CLI reference](cli-reference.md) lists every command, option, output contract, and exit behavior in `PDFQuickFixCLI`.
- [Cleanup Evidence](cleanup-evidence.md) defines the receipt and batch-manifest contracts, verdicts, privacy boundaries, and before/after comparison behavior.

## Understand the design

- [Architecture](architecture.md) explains the app, framework, CLI, local-AI, and verification boundaries.
- [Product thesis](../PRODUCT_THESIS.md) explains the privacy-first product direction.
- [Design system](../DESIGN.md) defines the visual language and interaction rules.

## Build and contribute

- [Contributing](../CONTRIBUTING.md) covers prerequisites, build commands, validation, and pull-request expectations.
- [Agent guide](../agent.md) records repository layout and operational conventions.
- [Changelog](../CHANGELOG.md) tracks shipped and unreleased user-visible changes.

Archived implementation plans live under [`docs/superpowers/`](superpowers/). They explain historical intent, but the source, tests, and reference documents above describe the current product.
