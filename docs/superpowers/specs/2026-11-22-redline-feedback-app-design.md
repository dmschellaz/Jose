# Redline — AI Feedback Capture for Claude Code (Design Spec)

*Working name: "Redline". Date: 2026-11-22. Status: draft for review.*

## 1. Purpose

A macOS menu bar app that records a spoken walkthrough of an app you're building. It watches your screen, marks up what you're talking about, and produces a feedback report (Markdown plus annotated screenshots) that Claude Code can act on to make revisions.

The first use case is reviewing **web apps running in a browser** (e.g. `localhost:3000` in Chrome, Safari or Arc).

### Success criteria
- From pressing the hotkey to having a paste-ready prompt on the clipboard takes **one hotkey to start, one to stop**. Nothing else is required.
- In Claude Code, the pasted prompt alone is enough for it to locate each issue (by URL/route, screenshot and quote) and make the change, without follow-up questions in the common case.
- Manual mode works with no network calls during the session.

### Prior art and positioning
- **Clicky / HeyClicky:** voice + screen AI buddy that points and draws on screen. The original is MIT Swift ([farzaa/clicky](https://github.com/farzaa/clicky)) and used as an implementation reference. Its output is speech, not a report.
- **Annotate, Xannotate, Remarc, PinVari, Jompter:** screen + voice feedback for coding agents. In all of them **the user draws**.
- **Redline's difference:** an optional AI that draws on screen *while you talk*, so you can see and correct its understanding before the report is written.

## 2. Scope

**In v1:** menu bar shell, hotkeys, three modes (Manual / Live / Chatty), screen capture, on-device speech-to-text, browser URL capture, on-screen overlay drawing (by user and by AI), report generation, clipboard hand-off.

**Out of scope (YAGNI):** video recording, Windows, cloud STT, backend/proxy server, accounts, native-app or iOS Simulator context (accessibility tree), MCP server, report editing UI. The last two are listed as possible phase 4.

**Platform:** macOS 26 (Tahoe) or later, Apple Silicon. This is a personal tool, so targeting the current OS lets us use `SpeechAnalyzer` without fallbacks.

## 3. User experience

### 3.1 Modes

| Mode | During session | Model calls | Intended for |
|---|---|---|---|
| **Manual** | You narrate. Hold **⌥ (Option)** to draw with a pen; tap **⌃⌥⇧M** to mark a moment. No live AI. | 1 at end (report) | Lowest token use |
| **Live** | AI draws circles/arrows/highlights and a short caption for what it thinks you mean. Silent. You can still use the pen. | ~1 per finished sentence + 1 report | See and correct the AI's understanding |
| **Chatty** | Live, plus the AI speaks a short confirmation and may ask one clarifying question. | ~1 per sentence + speech + 1 report | Hands-free, conversational review |

The mode is picked from the menu bar dropdown. The selection is remembered, and the default is set in Settings.

### 3.2 Session flow
1. Press **⌃⌥⇧F** to start. A small recording pill appears near the menu bar showing the mode and elapsed time, and a soft start chime plays.
2. Navigate your app and talk. Clicks, URL changes and sentences are logged. Depending on the mode, marks appear.
3. Press **⌃⌥⇧F** again to stop. The pill shows "Writing report…".
4. When done: the report folder is written, the prompt is copied to the clipboard, and a notification appears ("5 items copied — paste into Claude Code") with an **Open folder** action.
5. **Cancel** in the pill (click twice to confirm) or the menu cancels the session and discards it. Esc isn't used, because a global Esc would steal it from the app being reviewed.

All hotkeys can be rebound in Settings.

### 3.3 Output

Folder: `~/Feedback/<app-slug>-YYYY-MM-DD-HHmm/`. The output root can be changed in Settings. `<app-slug>` comes from the page title or host of the first captured URL, e.g. `localhost-3000` or `myapp`.

```
feedback.md       numbered feedback items
01-billing.png    annotated screenshot per item (PNG, display-native resolution, capped at 2560px wide)
02-navbar.png
raw/              clean (unannotated) keyframes
session.json      full timeline, for debugging and "Regenerate report"
```

`feedback.md` format:

```markdown
# Feedback: myapp — 2026-11-22 14:30
Reviewed at: http://localhost:3000 · 6m 12s · mode: Live

## 1. Billing card padding is too tight
- **Where:** `/settings/billing` — the "Current plan" card
- **Problem:** Text touches the card edge on the right; looks cramped.
- **Wanted:** More inner padding, roughly matching the cards on /settings/profile.
- **You said:** "this card feels really cramped, the text is basically touching the edge"
- **Screenshot:** ![](01-billing.png) — red circle marks the card

## 2. …

---
## Full transcript
[00:12] this card feels really cramped…
[00:31] (clicked "Upgrade") …
```

Clipboard text:

```
Read ~/Feedback/myapp-2026-11-22-1430/feedback.md and the screenshots it links, then make each revision in this project. Ask me if an item is ambiguous.
```

## 4. Architecture

Native Swift 6, SwiftUI with AppKit bridging, `LSUIElement = true` (no Dock icon). One Xcode project. Swift packages: `KeyboardShortcuts` (rebindable hotkeys) and the Anthropic HTTP API via a thin in-house client (no SDK dependency needed for two endpoints' worth of use).

```
            ┌────────────── SessionController (state machine) ──────────────┐
 Hotkeys ──▶│ idle → recording → finalizing → done / failed                 │
            └──┬─────────┬──────────┬───────────┬────────────┬──────────────┘
               │         │          │           │            │
        CaptureService  Speech   Context     Overlay     LiveAnnotator ──▶ Voice
        (frames)       Service   Service     (draw)      (Live/Chatty)    (Chatty)
               │         │          │           ▲            │
               └─────────┴────┬─────┴───────────┴────────────┘
                         SessionTimeline (append-only events)
                              │ on stop
                         ReportBuilder ──▶ disk + clipboard + notification
```

### 4.1 Components

Each unit has one job and a narrow interface; the SessionController is the only thing that wires them together.

**AppShell**
- `NSStatusItem` with a menu: mode picker, Start/Stop, Recent sessions (opens folder), Regenerate last report, Settings, Quit.
- Settings window (SwiftUI): Claude API key (stored in **Keychain**), live model, report model, output root, hotkeys, default mode, voice choice (Chatty).
- First-run onboarding: requests Screen Recording, Microphone, Speech Recognition, Accessibility (for the event tap), and Automation (browser URL). Each step deep-links into the matching System Settings pane and re-checks on return.

**HotkeyService**
- Registers ⌃⌥⇧F (toggle session), ⌃⌥⇧M (mark moment) and Esc (cancel, only while recording) via `KeyboardShortcuts`.
- The pen modifier (hold ⌥) is detected by the listen-only `CGEvent` tap in ContextService (flagsChanged). This follows Clicky's finding that event taps detect modifier-only gestures more reliably than AppKit global monitors.
- The pen activates only when **⌥ is held alone** (no other modifier) for ≥ 150 ms, and is cancelled if another key or modifier is pressed. This way pressing ⌃⌥⇧F or ⌃⌥⇧M never triggers the pen.

**CaptureService**
- `SCStream` on the display currently under the cursor (it switches displays when the cursor moves to another one). Phase 1 takes keyframes on events and every 5 s. Phase 2 adds a 2 fps in-memory ring buffer of the last 10 s for Live mode.
- `SCContentFilter` **excludes Redline's own windows** (overlay and pill), so every frame is clean.
- `snapshot(at:)` returns the buffered frame closest to a timestamp. `captureNow()` grabs a fresh full-resolution frame via `SCScreenshotManager`. A fresh frame is taken on every click (about 300 ms after, to catch the result), on every finished sentence, and on every ⌃⌥⇧M.
- Keyframes are persisted to `raw/` as they're taken (not held only in memory), so a crash still leaves usable material.

**ContextService**
- Listen-only `CGEvent` tap: left clicks (position, display, time) and modifier changes.
- Frontmost app and window title via `NSWorkspace` / `CGWindowListCopyWindowInfo`.
- Browser URL: when the frontmost app is Chrome, Safari or Arc, AppleScript reads the active tab URL every 1 s and on every click, and emits `urlChanged` events.
- Interface: an `AsyncStream<ContextEvent>`.

**SpeechService**
- `AVAudioEngine` input, with **voice processing** (echo cancellation, so Chatty's own voice isn't transcribed) enabled only in Chatty mode because it ducks other audio,, feeding `SpeechAnalyzer` + `SpeechTranscriber` (on-device).
- Emits `volatile` (partial) and `final` sentence results with start/end timestamps. Partials drive a live caption in the pill; finals go into the timeline and trigger LiveAnnotator.
- Also emits `userStartedSpeaking`, used for barge-in in Chatty.

**Overlay**
- One borderless, transparent, non-activating `NSPanel` per display. Level `.screenSaver`, `collectionBehavior` `[.canJoinAllSpaces, .fullScreenAuxiliary]`, `ignoresMouseEvents = true`.
- Renders `Annotation` values in a SwiftUI `Canvas`:
  ```swift
  enum Shape { case circle(center, radius), rect(CGRect), arrow(from, to), highlight(CGRect), stroke([CGPoint]) }
  struct Annotation { id, shape, caption: String?, color, author: .user | .ai, createdAt, displayID }
  ```
- AI marks fade out after 6 s. User pen strokes fade after 4 s. Every annotation stays in the timeline regardless.
- **Pen:** while ⌥ is held, the panel under the cursor sets `ignoresMouseEvents = false` and captures drag strokes. On release it goes back to click-through, and a snapshot is taken.
- All coordinates are stored in **global screen points**. A single `CoordinateMapper` converts image pixels ↔ display points ↔ global points, handling Retina scale, display origin, and AppKit's flipped y-axis. Most of the unit tests live here.

**LiveAnnotator** (Live and Chatty)
- Triggered by each final sentence. It sends:
  - the frame at the sentence's midpoint, downscaled to 1280px wide (JPEG, about 1.5k image tokens)
  - the last 3 sentences, clicks during the sentence (converted to image coordinates), and the current URL
  - a system prompt explaining the job: "mark what the user is referring to; prefer one shape; caption ≤ 8 words"
- Asks for an `annotate` result via structured outputs (forced `tool_choice` is rejected by current models):
  ```json
  { "marks": [ { "shape": "circle|rect|arrow|highlight", "x": 0, "y": 0, "w": 0, "h": 0,
                 "x2": 0, "y2": 0, "caption": "string" } ],
    "say": "string (Chatty only, ≤ 15 words, optional)",
    "question": "string (Chatty only, optional)" }
  ```
  Coordinates are in the downscaled image's pixel space. CoordinateMapper converts them back.
- **Throttling:** at most one request in flight. If a newer sentence finishes while one is pending, the pending result is still drawn, and only the newest queued sentence is sent next (intermediate ones are skipped live but still appear in the report).
- Default model: `claude-haiku-5-5` for speed; configurable to `claude-sonnet-5-5`. Requests time out after 8 s and are dropped silently. Live marks are a nice-to-have, never blocking.
- Each response is logged to the timeline as `aiAnnotation` (with the sentence id it answers), so ReportBuilder can reuse the AI's understanding.

**Voice** (Chatty)
- `AVSpeechSynthesizer` with the voice chosen in Settings (premium/personal voices if installed). Speaks `say`, then `question` if present.
- Barge-in: `userStartedSpeaking` stops speech immediately.
- Rate-limited: it won't speak more often than once per 10 s unless it is asking a question, so it doesn't narrate every sentence.

**SessionTimeline**
- Append-only, time-ordered events:
  `sentence(id, text, start, end)`, `click(point, display, t)`, `urlChanged(url, title, t)`, `keyframe(id, file, t, reason)`, `userMark(annotation)`, `aiAnnotation(sentenceId, annotations, say?)`, `momentMarked(t)`.
- `Codable`; written to `session.json` incrementally (every 5 s and on stop).

**ReportBuilder**
1. **Segment:** group sentences into candidate moments. A boundary is a gap ≥ 4 s, a URL change, or an explicit ⌃⌥⇧M.
2. **Pick keyframes:** for each moment, use the keyframe nearest to the moment's last user mark, AI mark or click, falling back to the moment's midpoint.
3. **Compose:** draw that moment's user and AI annotations onto the clean keyframe (Core Graphics, same style as the overlay). Save as `NN-<slug>.png`.
4. **Write-up:** one call to the report model (default `claude-sonnet-5-5`, configurable to `claude-opus-5-5`) with the full transcript, the timeline summary (URLs, clicks, AI marks), and the annotated moment images (downscaled to 1280px for the call; full resolution on disk). Structured outputs (`output_config.format` with a JSON schema; forced `tool_choice` is rejected by current models) return `items[]`: `{title, momentIds[], where, problem, wanted, quote, imageCaption}`. The model may merge moments into one item, or drop moments that aren't feedback (small talk, "ok next page").
5. **Render** `feedback.md` from the items (templated in Swift, not model-written Markdown, so the format is stable), plus the full transcript.
6. **Hand off:** copy the prompt, post the notification.
- **Regenerate:** re-runs steps 4–6 from `session.json` + `raw/` (e.g. after fixing an API key or switching models).

### 4.2 SessionController
State machine: `idle → recording(mode) → finalizing → done | failed`. It owns service lifetimes. Start brings up Capture, Speech, Context and Overlay (plus LiveAnnotator/Voice by mode). Stop tears them down in reverse and runs ReportBuilder. The services communicate with the controller only through `AsyncStream`s, so each can be tested with fakes.

## 5. Error handling

| Situation | Behavior |
|---|---|
| Missing permission at start | Session doesn't start. The Setup window opens, listing each missing permission with a button that requests it or opens its System Settings pane. |
| Screen Recording grant not appearing | Known macOS quirk: grants only register when launched as a `.app` (not from Terminal). Onboarding says so; dev builds launch via `open`. |
| No API key | Manual mode records normally. At stop it writes `raw/`, `session.json`, and a fallback `feedback.md` (one section per moment with screenshot and transcript, no AI write-up), then copies that. Live and Chatty refuse to start and suggest Manual. |
| Network/API failure during Live | Marks silently skipped; recording continues. A small "AI offline" dot in the pill. |
| Report call fails | Same fallback `feedback.md` as no-key; notification offers "Regenerate". |
| Browser URL unavailable (Automation denied, unsupported browser) | `Where:` uses window title only. No error. |
| Very long session (> 20 min) | Moments beyond the report model's image budget are sent as text only; their screenshots are still saved and linked. |
| Crash mid-session | `raw/` and periodically-saved `session.json` survive; "Regenerate last report" works on them. |

## 6. Privacy and cost

- Speech-to-text runs on-device. Audio is never stored or sent anywhere.
- Screenshots leave the machine only for Claude API calls (Live/Chatty per sentence, and the report). Manual mode sends nothing until stop.
- API key lives in Keychain. There's no telemetry.
- **Token use estimates** (images ≈ 1.5k tokens at 1280px): Live and Chatty use about 2–3k input tokens per sentence; a typical 5-minute session with ~30 sentences is ~60–90k input tokens on the live model. The report call is roughly 15–30k input tokens. Manual mode uses only the report call. The recording pill's tooltip shows a running token count for the current session, and `session.json` records the total.

## 7. Testing

**Unit tests (XCTest / Swift Testing):**
- `CoordinateMapper`: Retina vs non-Retina, display arrangements (left/above/negative origins), image downscale round-trips.
- `annotate` / `write_report` tool parsing: valid, partial and malformed payloads; out-of-bounds coordinates get clamped.
- ReportBuilder segmentation and keyframe selection: given fixture timelines → expected moments and frames.
- Markdown rendering: fixture items → golden `feedback.md`.
- SessionController state transitions with fake services (start/stop/cancel, failure paths, no-key fallback).
- LiveAnnotator throttling: burst of sentences → at most one in flight, newest wins.

**Manual checklist (each phase):** fresh-install permission flow; overlay click-through doesn't steal clicks; pen works on both monitors; overlay excluded from screenshots; Chatty voice isn't transcribed; full-screen Spaces; paste prompt into Claude Code in a real project and confirm it reads the images.

## 8. Build phases

Each phase is independently usable.

1. **Manual mode end-to-end:** AppShell, onboarding, HotkeyService, CaptureService, ContextService, SpeechService, Overlay (pen only), SessionTimeline, ReportBuilder, clipboard hand-off.
2. **Live mode:** LiveAnnotator, AI annotations in Overlay, AI marks feeding ReportBuilder.
3. **Chatty mode:** Voice, barge-in, clarifying questions (answers are just the next sentence in the transcript).
4. **Optional, later:** review sheet to edit or delete items before copying; MCP server ("grab my latest feedback"); iOS Simulator / native app context.

## 9. Open decisions (defaults chosen; change if desired)
- **Name:** "Redline" is a working name.
- **Hotkeys:** ⌃⌥⇧F / ⌃⌥⇧M / hold ⌥ for pen. (Changed from ⌃⌥F / ⌃⌥M because window managers such as Magnet use ⌃⌥ + letters; ⌃⌥F is Magnet's "Center Third".) Hold-⌥ may conflict with apps that use Option-drag; if so, change the pen to hold ⌃⌥.
- **Distribution:** local Xcode builds signed with your personal team; no notarization or auto-update in v1.
