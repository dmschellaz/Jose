# Redline Phase 2 (Live Mode) Implementation Plan

**Goal:** In Live mode, after each sentence the user finishes, the AI draws a circle, rect, arrow or highlight plus a short caption on screen over what it thinks the user means. The marks feed the final report.

**Spec:** `docs/superpowers/specs/2026-11-22-redline-feedback-app-design.md` §3.1, §4.1 LiveAnnotator, §5, §6. Phase 1 plan: `2026-11-22-redline-phase1-manual-mode.md` (its Global Constraints still apply).

## Shared contract (already committed, don't change without coordinating)

- `RedlineCore/Live/LiveTypes.swift`: `LiveFrame`, `TimelineObserving`, `TokenReporting`, `LiveStatus`, `TokenUsage +`.
- `SessionContext.mode`: services can see which mode the session runs in.
- `ReportResult.liveTokens` / `liveModel`.
- `Pricing`: `claude-haiku-5-5` costs $0.10 / $0.50 per million tokens.

## Decisions

- **Live model:** defaults to `claude-haiku-5-5` and can be set to `claude-sonnet-5-5` in Settings.
  - Effort `low`, structured outputs (`output_config.format`), `max_tokens` 2000.
  - Send `fallbacks: "default"` only for Sonnet; Haiku has no server-side fallback.
- **Request timeout:** 8 s. A timeout or any error drops the result silently and sets status `.offline`.
- **Throttle:** at most one request in flight. While one is pending, keep only the newest sentence and send it next. Intermediate sentences are skipped live but stay in the report.
- **Frame:** the frame nearest the sentence's midpoint, taken from the app's 2 fps, 10 s in-memory ring buffer. When nothing is buffered, use a fresh capture.
- **Coordinates:** the model answers in the JPEG's pixel space. Convert with `CoordinateMapper.global(fromImagePoint:imageSize:on:)` and clamp to the image.
- **Timeline:** each answer is logged as `.aiAnnotation(sentenceID:annotations:say:)` with `author: .ai`, `createdAt` = the sentence's end time, and the frame's display id.
- **Overlay:** AI marks fade out after 6 s. The caption is drawn next to the mark in a small rounded label, in AI blue.
- **Report:**
  - AI marks are composited into the PNGs with their captions.
  - The report request tells the model what the AI marked ("AI marked: <caption>"), and that blue marks are the live AI's guesses and red marks are the reviewer's.
- **No API key:** Live refuses to start and suggests Manual (spec §5).
- **Tokens:** live tokens are summed into `session.json`'s token total and shown on the island as a second cost line.

## Tracks (run in parallel; each owns only its files)

| Track | Owns | Deliverable |
|---|---|---|
| A: Core annotator | `Live/AnnotateRequest.swift`, `Live/LiveAnnotator.swift`, `Session/SessionController.swift`, tests | Request/parse, throttled annotator service, controller forwards events and sums live tokens |
| B: Frame buffer | `App/Redline/Services/CaptureService.swift` (+ new app files) | 2 fps SCStream ring buffer, `liveFrame(near:)` |
| C: App UI | `AppSettings`, `SettingsView`, `MenuContent`, `RecordingPill`, `OverlayView`, `OnboardingWindow` text | Mode picker, live model setting, captions, offline dot, live cost line |
| D: Report | `Report/Moment.swift`, `Claude/ReportRequest.swift`, `Imaging/AnnotationCompositor.swift`, `Report/MarkdownRenderer.swift`, tests | AI marks in report prompt, captions in PNGs |

**Integration (lead):** `AppModel` wiring, docs, the manual test.
