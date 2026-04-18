# Design System — PDFQuickFix

## Product Context
- **What this is:** A native macOS app for repairing, redacting, sanitizing, organizing, splitting, and merging sensitive PDFs before they are shared.
- **Who it's for:** Operations-heavy users, consultants, finance/travel/aviation-adjacent teams, and privacy-conscious power users who handle risky PDFs often enough that mistakes matter.
- **Space/industry:** PDF tools, document utilities, privacy-first desktop productivity.
- **Project type:** Native macOS productivity app with multi-workbench flows.

## Aesthetic Direction
- **Direction:** Forensic Desk
- **Decoration level:** Intentional
- **Mood:** Calm, serious, and trustworthy. It should feel like a well-lit document workbench, not a chat toy and not a generic SaaS dashboard.
- **Reference sites:** [PDF Expert](https://pdfexpert.com/), [Adobe Acrobat](https://www.adobe.com/acrobat.html)

### Design thesis
PDFQuickFix should look like the fastest safe place to inspect a document, clean it, and produce a safer outbound copy.

The visual language should borrow:
- the speed and Mac-likeness of PDF Expert,
- none of Acrobat's cloud-heavy marketing noise,
- and a stronger "document operations" identity than either of them.

This means:
- dark graphite shell around the app,
- light paper surfaces where document results matter,
- restrained but memorable accents,
- clear workbench framing instead of generic floating cards.

## Typography
- **Display/Hero:** SF Pro Display
  Used for workbench titles, first-run empty states, and major mode headers. It keeps the app native to macOS and trustworthy.
- **Body:** SF Pro Text
  Used for form labels, descriptions, and supporting copy. High legibility beats novelty here.
- **UI/Labels:** SF Pro Text Semibold
  Used for segmented controls, chips, section headers, and action labels.
- **Data/Tables:** SF Mono
  Used for logs, OCR/report metrics, file metadata, and validation output.
- **Code:** SF Mono
- **Loading:** Native Apple system fonts. Do not add bundled web-style fonts to the app unless there is a marketing site later.

### Type scale
- Display XL: 28pt / 32
- Display L: 24pt / 28
- Title: 20pt / 24
- Section: 15pt / 20 semibold
- Body: 13pt / 18
- Body Small: 12pt / 16
- Meta / Caption: 11pt / 14
- Mono Small: 11pt / 14

### Typography rules
- Use sentence case, not all caps, for almost everything.
- Reserve bold for task framing and primary outcomes, not for every label.
- Logs and metrics switch to mono immediately so the app feels operational, not decorative.

## Color
- **Approach:** Restrained with one warm signal accent and one cool support accent
- **Primary accent:** `#C96A3D`
  Burnt vermilion. Use for primary actions, active emphasis, progress accents, and selected state highlights when the moment is action-oriented.
- **Secondary accent:** `#5C8A7A`
  Oxidized teal. Use for "safe / resolved / verified" states, secondary emphasis, and subtle assistive highlights.
- **Neutrals:**
  - `#0F1113` app background
  - `#171A1E` sidebar / chrome background
  - `#22262B` primary surface
  - `#2B3137` elevated surface
  - `#E9E2D6` primary text on dark
  - `#B8B0A3` muted text on dark
  - `#F4F0E8` paper surface
  - `#D9D0C3` paper border
  - `#2A2620` ink text on paper
- **Semantic:**
  - success `#4E8F68`
  - warning `#D2A24B`
  - error `#B94C45`
  - info `#4F7FA8`
- **Dark mode strategy:** The app shell is dark-first. Document previews, reports, and result summaries can use light "paper" panels inside that shell. Do not build a second fully separate dark-vs-light brand.

### Color rules
- Avoid pure white on pure black. Use warm off-white on graphite.
- Avoid default macOS accent blue as the primary brand signal.
- Do not make redaction look like an error state only. It is a core product action and needs a deliberate, controlled accent treatment.
- Purple gradients, neon AI highlights, and generic glassmorphism are out.

## Spacing
- **Base unit:** 8px
- **Density:** Comfortable, leaning compact on operational surfaces
- **Scale:** 4, 8, 12, 16, 24, 32, 48, 64

### Spacing rules
- Major workbench sections should breathe with 24-32pt spacing.
- Dense controls inside cards can tighten to 12-16pt.
- Empty states should feel poster-like, with larger vertical gaps and stronger composition.

## Layout
- **Approach:** Hybrid
- **Grid:** Stable shell, expressive workbench interiors
- **Max content width:** 900-960pt for focused workbench screens like Split/Merge and QuickFix
- **Border radius scale:**
  - small 8
  - medium 12
  - large 18
  - hero/workbench 24

### Layout rules
- The app shell should stay disciplined and native.
- Mode-specific workbenches should feel like dedicated stations, not generic forms dropped into a window.
- Empty states should lead with one primary action, one secondary path, and visible recent work.
- Reader/Studio/Split/QuickFix should each have a clear "header + work surface + status footer" rhythm.
- Reports and result summaries should use paper-like panels inside the dark shell so output feels inspectable.

## Motion
- **Approach:** Minimal-functional
- **Easing:** `easeOut` for enter, `easeInOut` for panel shifts, `easeIn` for dismiss
- **Duration:** micro 80ms, short 160ms, medium 240ms, long 360ms

### Motion rules
- Motion should help orientation, not add personality for its own sake.
- Use subtle slide/fade transitions for sidebars, inspectors, and workbench swaps.
- Avoid springy toy motion. This is a serious tool.

## Safe Choices
- Native macOS typography and control idioms stay intact.
- Dark shell plus bright document surfaces preserve the current app's strongest visual instinct.
- Focused content widths and segmented workbench layouts stay aligned with user expectations for a desktop utility.

## Risks
- **Warm paper-and-graphite palette in a pro utility category**
  Most competitors go cold blue-gray. The gain is a more distinctive, trustworthy identity. The cost is less generic enterprise neutrality.
- **Document-workbench framing instead of generic card UI**
  Screens should feel like stations with intent. The gain is stronger product memory. The cost is a bit more custom layout work.
- **Operational emphasis over AI spectacle**
  AI stays supportive, not visually dominant. The gain is trust. The cost is less immediate "AI product" signaling.

## Implementation Notes
- There are currently two parallel token systems in the app:
  - `AppTheme` in [Sources/PDFQuickFix/AppTheme.swift](/Users/yordamkocatepe/Projects/PDFQuickFix/Sources/PDFQuickFix/AppTheme.swift:6)
  - `AppColors` / `AppLayout` in [Sources/PDFQuickFix/Utilities.swift](/Users/yordamkocatepe/Projects/PDFQuickFix/Sources/PDFQuickFix/Utilities.swift:198)
- Future UI work should converge these into one token source instead of extending both.
- Current UI already hints at the right direction:
  - dark shell and focused toolbar in [ContentView.swift](/Users/yordamkocatepe/Projects/PDFQuickFix/Sources/PDFQuickFix/ContentView.swift:136)
  - document-first empty state in [ReaderProView.swift](/Users/yordamkocatepe/Projects/PDFQuickFix/Sources/PDFQuickFix/ReaderProView.swift:970)
  - workbench framing in [SplitView.swift](/Users/yordamkocatepe/Projects/PDFQuickFix/Sources/PDFQuickFix/SplitView.swift:17)
  - card-based AI workflow in [QuickFixTab.swift](/Users/yordamkocatepe/Projects/PDFQuickFix/Sources/PDFQuickFix/QuickFixTab.swift:62)

## Screen-Level Guidance

### Reader
- Feel like a document desk.
- Make the home screen larger, calmer, and more deliberate.
- Replace generic "drop here" vibes with "Open a PDF to inspect, clean, or repair."

### QuickFix / AI Tools
- Present as a cleanup station, not a playground.
- Keep the top action row strong and obvious.
- Reports should look reviewable, almost like evidence packets.

### Studio
- Emphasize page operations and safe export flows.
- Duplicate, reorder, rotate, and sanitize should read like production tools.

### Split / Merge
- This should feel like an assembly bench.
- Source, options, destination, and outcome should read in a clear top-to-bottom narrative.

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-04-18 | Adopted "Forensic Desk" direction | Fits the privacy-first PDF cleanup wedge better than generic SaaS or AI-native styling |
| 2026-04-18 | Kept app shell dark-first | Preserves current product feel while allowing light paper surfaces where outputs matter |
| 2026-04-18 | Chose native SF Pro / SF Mono typography | Best balance of Mac-native trust, readability, and implementation realism |
| 2026-04-18 | Introduced warm vermilion + oxidized teal accents | Makes the product memorable without drifting into trendy AI color language |
