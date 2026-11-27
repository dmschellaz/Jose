# Redline Phase 3 (Chatty Mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Chatty mode is Live mode plus a voice. It says a short line (at most 12 words) only when it's unsure or the reviewer changes topic. When two or more on-screen things fit, it asks one clarifying question. The question is spoken and shown in the island with 2–3 option buttons and Skip. The reviewer answers by clicking or by speaking, and the Q&A carries into the report.

**Architecture:** All decision logic goes in `RedlineCore`, where it's unit-tested:
- the Q&A timeline events,
- Q&A in moments, the report prompt and `feedback.md`,
- the Chatty request schema and its parsing,
- `ChattyConversation`, which handles turn-taking (line rate limit, one open question, how answers are matched),
- `MicGate`, a thread-safe "ignore the mic now" flag,
- `LiveAnnotator`'s Chatty path.

The app adds:
- `VoiceService` (`AVSpeechSynthesizer`). It closes the mic gate while speaking and lifts the session's output mute only for that line.
- A gate check in `SpeechService`'s audio pipe, which replaces gated audio with silence.
- A voice picker in Settings.
- Wiring in `AppModel`.
- A question bar and a **Stop talking** button in the island.

**Tech Stack:** Swift 6.2 (Swift 6 language mode), SwiftUI + AppKit, AVFoundation (`AVSpeechSynthesizer`, `AVAudioEngine`), Speech (`SpeechAnalyzer`), CoreAudio (existing `SystemAudio`), Swift Testing, XcodeGen, Claude Messages API over `URLSession`.

**Spec:** `docs/superpowers/specs/2026-11-22-redline-feedback-app-design.md`. **§10 "Phase 3 addendum: Chatty mode" is binding** and overrides the Chatty text in §3.1 and §4.1 (Voice, barge-in, voice processing, the `say`/`question` schema). Earlier plans: `2026-11-22-redline-phase1-manual-mode.md` (its Global Constraints still apply) and `2026-11-22-redline-phase2-live-mode.md` (its Decisions still apply to everything Chatty shares with Live).

## Global Constraints

- macOS deployment target **26.0**, Apple Silicon. Swift tools version **6.2**, Swift 6 language mode. Full Xcode is required.
- Build and test commands always start with `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer;`. They are:
  - `make test`: the core package, via `swift test`.
  - `make app`: XcodeGen plus `xcodebuild` Debug.
  - `make run`: build and launch through LaunchServices.
  - Single test files: `cd Packages/RedlineCore && swift test --filter "<FileOrSuite>|<Other>"`.
- **Baseline:** on branch `phase3-chatty-mode` before Task 1, `make test` reports `Test run with 129 tests in 7 suites passed`.
- Claude API:
  - Endpoint and version: `POST https://api.anthropic.com/v1/messages`, header `anthropic-version: 2026-10-21`.
  - Never send `temperature`, `top_p` or `top_k`.
  - **No forced `tool_choice`.** Use structured outputs, `output_config.format` (`json_schema`).
  - Check `stop_reason` for `refusal`/`max_tokens` before reading content (`ClaudeHTTPClient` already does).
- Live model (shared by Live and Chatty):
  - Defaults to `claude-haiku-5-5`; `claude-sonnet-5-5` can be chosen in Settings.
  - Effort `low`, `max_tokens` 2000.
  - Thinking is `disabled` for Haiku and `between_tools` for Sonnet 5.5.
  - `fallbacks: "default"` (plus header `anthropic-beta: server-side-fallback-2026-07-01`) only for Sonnet.
  - 8 s timeout, after which the result is dropped silently and status becomes `.offline`.
  - At most one request in flight; while one is pending, only the newest sentence waits to go next.
  - Frames are JPEG at most 1280 px wide. The model answers in the JPEG's pixel space.
- **Live behaviour is unchanged when the session isn't Chatty.** Same system prompt, same schema (`marks` only), same events. Chatty only extends the system prompt and the schema.
- Report model: Haiku 5.5, Sonnet 5.5 (default) or Opus 5.5, effort `medium`, `max_tokens` 16000. No fallbacks for Haiku.
- Chatty values (spec §10):
  - A spoken line is **≤ 12 words** and only when unsure or on a topic switch. **At most 1 line per 10 s**; questions are exempt.
  - Questions are asked only when 2+ on-screen things fit or the change is unclear. Each has **2–3 options of ≤ 4 words**, plus **Skip**.
  - The reviewer answers by click, or by voice (the next finished sentence). An unanswered question is **skipped after 20 s**. **One open question at a time.**
- Timeline (spec §10):
  - `aiQuestion(id, sentenceID, text, options, t)` and `questionAnswered(id, answer, via: click | voice | skipped, t)`.
  - Phase 2 `session.json` files must still decode.
- Report:
  - Each moment carries its Q&A.
  - A `feedback.md` item gets a `Clarified: <question> → <answer>` line.
  - The report prompt treats answers as the reviewer's own words.
- Voice: `AVSpeechSynthesizer` with a built-in voice picked in Settings. No third-party voices, no extra account.
- Audio:
  - Sessions keep the Mac's output muted (`SystemAudio`). The mute is lifted only while a line is spoken, then put back.
  - **Mic gate:** while speaking, plus a **300 ms tail**, mic input is ignored. Voice processing is not used.
  - **No barge-in.** The island has **Stop talking** instead.
- Out of scope: barge-in, third-party voices, multi-turn conversations.
- All stored coordinates are **global Quartz points** (origin at the top-left of the primary display, y down).
- API key only in Keychain. No telemetry.
- **Swift 6 pitfalls already hit in this project:**
  1. A closure formed inside `@MainActor` code is `@MainActor`-isolated. If a system API calls it off the main thread, it **traps at runtime** (audio taps, `AVSpeechSynthesizerDelegate`, CoreAudio listeners). Build such closures in `nonisolated` helpers, or make delegate methods `nonisolated` and hop with `Task { @MainActor in … }` carrying only Sendable values.
  2. A nested `try #require` inside another `#require(...)` doesn't compile. Unwrap step by step, one `let x = try #require(...)` per line.
  3. Every test file needs `import Foundation` (with `import Testing` and `@testable import RedlineCore`).
  4. `SessionController` has private `generation`, `starting` and `pendingCancel` guards. They stop stale async work and double starts. Don't remove them or reorder them around `await`s.
  5. Synthesized `Codable` on an enum with associated values encodes `{"caseName":{"label":value}}`, and unlabeled values as `_0`. New cases are backward compatible for decoding. Renaming an existing case or label is not.

## Decisions this plan makes (the spec doesn't settle them)

1. **What is spoken when a question opens:** only the question's text. The options are shown, not read out, and the `say` from the same answer is dropped. A question also resets the 10 s line clock, so no remark comes straight after it.
2. **Voice answer:** the first finished sentence that *started* at or after the moment the question was asked. A sentence already under way doesn't count. That sentence is also sent to the live model with "You asked: …", so its mark reflects the answer.
3. **Sanitising:**
   - `say` is cut to its first 12 words and each option to its first 4.
   - Options are de-duplicated (ignoring case) and capped at 3.
   - A question with an empty text, or fewer than 2 usable options, is dropped.
4. **Skipped questions** get no `Clarified:` line. They appear in the transcript as "(question skipped)" and in the report prompt as "(not answered)". A question still open when the session stops is logged as skipped.
5. **`say` in the timeline:** stored on `aiAnnotation.say` only when it was actually spoken and the answer had marks. A silent or rate-limited `say` isn't stored.
6. **Mute lifting:** the mute is lifted only if Redline's own mute is in place (`SystemAudio.isMutedByRedline`). If the user had muted the Mac themselves, Chatty stays silent rather than unmuting them. At session stop the voice is cut without re-muting, because `AppModel` restores audio right after.
7. **Gated audio** is replaced with zeros rather than dropped. That way the analyzer's timeline, and so sentence times, stay in step with the session clock.

## File Structure

```
Packages/RedlineCore/Sources/RedlineCore/
  Timeline/TimelineEvent.swift          (modify) AnswerVia, aiQuestion, questionAnswered
  Report/MarkdownRenderer.swift         (modify) transcript lines for Q&A and spoken lines; Clarified line
  Report/Moment.swift                   (modify) Clarification, Moment.clarifications, segmenter
  Session/SessionController.swift       (modify) review filter keeps Q&A of chosen sentences
  Claude/ReportRequest.swift            (modify) Q&A lines per moment; system prompt
  Report/ReportBuilder.swift            (modify) passes answered Q&A per item to the renderer
  Live/LiveTypes.swift                  (modify) LiveQuestion, LiveAnswer
  Live/AnnotateRequest.swift            (modify) Chatty prompt + schema, parseAnswer
  Live/ChattyConversation.swift         (create) turn-taking rules
  Input/MicGate.swift                   (create) thread-safe mic gate with tail
  Live/LiveAnnotator.swift              (modify) Chatty path, onSpeak/onQuestion, answer/skip, expiry
Packages/RedlineCore/Tests/RedlineCoreTests/
  TimelineTests.swift, MarkdownTests.swift, MomentTests.swift, SessionControllerTests.swift,
  ReportRequestTests.swift, ReportBuilderTests.swift, AnnotateRequestTests.swift,
  ChattyConversationTests.swift (create), MicGateTests.swift (create), LiveAnnotatorTests.swift
App/Redline/
  Services/SpeechService.swift          (modify) gate in AudioPipe, `gate` property
  Services/SystemAudio.swift            (modify) isMutedByRedline
  Services/VoiceService.swift           (create) AVSpeechSynthesizer voice, mic gate, mute lifting
  Debug/DebugHarness.swift              (modify) `mode:` parameter
  Debug/DebugMenu.swift                 (modify) mic gate + voice checks
  Settings/AppSettings.swift            (modify) Chatty available, voiceIdentifier
  Settings/SettingsView.swift           (modify) Chatty voice section
  MenuContent.swift                     (modify) Chatty selectable, key note for Live and Chatty
  AppModel.swift                        (modify) wiring
  UI/RecordingPill.swift                (modify) question bar, Stop talking, status for Chatty
docs/TRY-IT.md                          (modify) "Try Chatty mode"
```

---

### Task 1: Q&A timeline events and transcript lines

**Files:**
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Timeline/TimelineEvent.swift`
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Report/MarkdownRenderer.swift` (`TranscriptBuilder` only; its `switch` is exhaustive)
- Test: `Packages/RedlineCore/Tests/RedlineCoreTests/TimelineTests.swift`, `Packages/RedlineCore/Tests/RedlineCoreTests/MarkdownTests.swift`

**Interfaces:**
- Consumes: existing `TimelineEvent`, `SessionStore`, `SessionFolder.create(root:slug:date:timeZone:)`, `MomentSegmenter.segment(_:)`, `FallbackReport.quotedCaptions(_:)`.
- Produces:
  - `public enum AnswerVia: String, Codable, Sendable { case click, voice, skipped }`
  - `TimelineEvent.aiQuestion(id: UUID, sentenceID: UUID, text: String, options: [String], t: Double)`
  - `TimelineEvent.questionAnswered(id: UUID, answer: String, via: AnswerVia, t: Double)` (`answer` is `""` when skipped)
  - `.time` returns `t` for both.
  - Transcript lines:
    - `(AI asked "<q>", options: "<a>", "<b>")`
    - `(picked "<answer>")` for click
    - no line for voice (the sentence is already there)
    - `(question skipped)`
    - `(AI marked … and said "<say>")` when `say` is set

- [ ] **Step 1: Write the failing tests**

Append to `Packages/RedlineCore/Tests/RedlineCoreTests/TimelineTests.swift`:
```swift
@Test func questionEventTimes() {
    #expect(TimelineEvent.aiQuestion(id: UUID(), sentenceID: UUID(), text: "Which card?", options: ["Billing", "Profile"], t: 4).time == 4)
    #expect(TimelineEvent.questionAnswered(id: UUID(), answer: "Billing", via: .click, t: 6).time == 6)
}

@Test func questionEventsRoundTripThroughDisk() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = try SessionFolder.create(root: dir, slug: "chatty", date: Date(timeIntervalSince1970: 1_700_000_000), timeZone: .gmt)
    let q = UUID()
    let doc = SessionDocument(
        metadata: SessionMetadata(startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil, mode: .chatty,
                                  displays: [], tokens: TokenUsage()),
        events: [
            .sentence(id: UUID(), text: "make it bigger", start: 1, end: 2),
            .aiQuestion(id: q, sentenceID: UUID(), text: "Which button?", options: ["Save", "Cancel"], t: 3),
            .questionAnswered(id: q, answer: "Save", via: .click, t: 4),
            .questionAnswered(id: UUID(), answer: "", via: .skipped, t: 30),
        ])
    try SessionStore.save(doc, to: folder)
    #expect(try SessionStore.load(from: folder) == doc)
}

/// A session.json written by phase 2 (no Chatty events) must still open, e.g. for "Regenerate Last Report".
@Test func phase2SessionFileStillDecodes() throws {
    let json = """
    {
      "events" : [
        { "urlChanged" : { "t" : 0.5, "title" : "Home", "url" : "http://localhost:3000/" } },
        { "sentence" : { "end" : 3, "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF", "start" : 1, "text" : "this card is cramped" } },
        { "aiAnnotation" : {
            "annotations" : [ { "author" : "ai", "caption" : "Billing card", "createdAt" : 3, "displayID" : 1,
                                "id" : "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
                                "shape" : { "rect" : { "_0" : [[10, 20], [30, 40]] } } } ],
            "sentenceID" : "6F9619FF-8B86-D011-B42D-00C04FC964FF" } },
        { "momentMarked" : { "t" : 4 } }
      ],
      "metadata" : {
        "displays" : [ { "frame" : [[0, 0], [1512, 982]], "id" : 1, "scale" : 2 } ],
        "mode" : "live",
        "startedAt" : "2026-11-23T14:30:00Z",
        "tokens" : { "input" : 10, "output" : 2 }
      }
    }
    """
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = try SessionFolder.create(root: dir, slug: "phase2", date: Date(timeIntervalSince1970: 1_700_000_000), timeZone: .gmt)
    try Data(json.utf8).write(to: folder.documentURL)
    let doc = try SessionStore.load(from: folder)
    #expect(doc.metadata.mode == .live)
    #expect(doc.events.count == 4)
    guard case let .aiAnnotation(sentenceID, annotations, say) = doc.events[2] else { Issue.record("no aiAnnotation"); return }
    #expect(sentenceID == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    #expect(annotations.first?.caption == "Billing card")
    #expect(say == nil)
    #expect(MomentSegmenter.segment(doc.events).count == 1)
}
```

Append to `Packages/RedlineCore/Tests/RedlineCoreTests/MarkdownTests.swift`:
```swift
@Test func transcriptShowsChattyQuestionsAnswersAndSpokenLines() {
    let q = UUID()
    let lines = TranscriptBuilder.lines([
        .aiAnnotation(sentenceID: UUID(), annotations: [
            Annotation(shape: .rect(.zero), caption: "Save", author: .ai, createdAt: 1, displayID: 1),
        ], say: "Now on billing."),
        .aiQuestion(id: q, sentenceID: UUID(), text: "Which button?", options: ["Save", "Cancel"], t: 2),
        .questionAnswered(id: q, answer: "Save", via: .click, t: 3),
        .questionAnswered(id: UUID(), answer: "the save one", via: .voice, t: 4),
        .questionAnswered(id: UUID(), answer: "", via: .skipped, t: 5),
    ])
    #expect(lines.map(\.text) == [
        "(AI marked \"Save\" and said \"Now on billing.\")",
        "(AI asked \"Which button?\", options: \"Save\", \"Cancel\")",
        "(picked \"Save\")",
        "(question skipped)",
    ])
    #expect(lines.map(\.t) == [1, 2, 3, 5])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter "TimelineTests|MarkdownTests"`
Expected: compile errors, including `type 'TimelineEvent' has no member 'aiQuestion'`.

- [ ] **Step 3: Add the events**

In `Packages/RedlineCore/Sources/RedlineCore/Timeline/TimelineEvent.swift`, insert this between `KeyframeRef` and `TimelineEvent`:
```swift
/// How a Chatty clarifying question was closed.
public enum AnswerVia: String, Codable, Sendable {
    /// The reviewer clicked one of the options in the island.
    case click
    /// The reviewer's next finished sentence was taken as the answer.
    case voice
    /// Skip was clicked, nobody answered within 20 s, or the session ended first.
    case skipped
}
```

Replace the `TimelineEvent` enum with:
```swift
/// Everything that happens during a session. All times are seconds since session start.
public enum TimelineEvent: Codable, Equatable, Sendable {
    case sentence(id: UUID, text: String, start: Double, end: Double)
    case click(point: CGPoint, displayID: UInt32, t: Double)
    case urlChanged(url: String, title: String?, t: Double)
    case keyframe(KeyframeRef, reason: KeyframeReason)
    case userMark(Annotation)
    case aiAnnotation(sentenceID: UUID, annotations: [Annotation], say: String?)
    case momentMarked(t: Double)
    /// Chatty: the live AI asked about sentence `sentenceID`; `options` are the 2–3 answer buttons.
    case aiQuestion(id: UUID, sentenceID: UUID, text: String, options: [String], t: Double)
    /// Chatty: question `id` was closed. `answer` is the option clicked or the sentence said, "" when skipped.
    case questionAnswered(id: UUID, answer: String, via: AnswerVia, t: Double)

    public var time: Double {
        switch self {
        case let .sentence(_, _, start, _): return start
        case let .click(_, _, t): return t
        case let .urlChanged(_, _, t): return t
        case let .keyframe(ref, _): return ref.t
        case let .userMark(a): return a.createdAt
        case let .aiAnnotation(_, annotations, _): return annotations.first?.createdAt ?? 0
        case let .momentMarked(t): return t
        case let .aiQuestion(_, _, _, _, t): return t
        case let .questionAnswered(_, _, _, t): return t
        }
    }
}
```

- [ ] **Step 4: Add the transcript lines**

In `Packages/RedlineCore/Sources/RedlineCore/Report/MarkdownRenderer.swift`, replace the body of `TranscriptBuilder.lines(_:)` with:
```swift
    public static func lines(_ events: [TimelineEvent]) -> [TranscriptLine] {
        events.sorted { $0.time < $1.time }.compactMap { e in
            switch e {
            case let .sentence(_, text, start, _): return TranscriptLine(t: start, text: text)
            case let .click(_, _, t): return TranscriptLine(t: t, text: "(click)")
            case let .urlChanged(url, _, t): return TranscriptLine(t: t, text: "(opened \(FallbackReport.pathOf(url)))")
            case let .momentMarked(t): return TranscriptLine(t: t, text: "(marked moment)")
            case let .userMark(a): return TranscriptLine(t: a.createdAt, text: "(drew on screen)")
            case let .aiAnnotation(_, anns, say):
                guard !anns.isEmpty else { return nil }
                let captions = FallbackReport.quotedCaptions(anns)
                var text = captions.isEmpty ? "(AI marked the screen" : "(AI marked \(captions)"
                if let say, !say.isEmpty { text += " and said \"\(say)\"" }
                return TranscriptLine(t: e.time, text: text + ")")
            case let .aiQuestion(_, _, text, options, t):
                let choices = options.map { "\"\($0)\"" }.joined(separator: ", ")
                return TranscriptLine(t: t, text: "(AI asked \"\(text)\", options: \(choices))")
            case let .questionAnswered(_, answer, via, t):
                switch via {
                case .click: return TranscriptLine(t: t, text: "(picked \"\(answer)\")")
                case .voice: return nil   // the answer is the reviewer's next sentence, already listed
                case .skipped: return TranscriptLine(t: t, text: "(question skipped)")
                }
            case .keyframe: return nil
            }
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter "TimelineTests|MarkdownTests"`
Expected: all pass, including the 4 new tests. The existing `transcriptIncludesContextEvents` still passes, because `say: nil` lines are unchanged and an empty-marks `aiAnnotation` is still skipped.

Then run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make test`
Expected: `Test run with 133 tests in 7 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add Packages/RedlineCore/Sources/RedlineCore/Timeline/TimelineEvent.swift Packages/RedlineCore/Sources/RedlineCore/Report/MarkdownRenderer.swift Packages/RedlineCore/Tests/RedlineCoreTests/TimelineTests.swift Packages/RedlineCore/Tests/RedlineCoreTests/MarkdownTests.swift
git commit -m "feat(core): Chatty question and answer timeline events"
```

---

### Task 2: Q&A in moments and in the review filter

**Files:**
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Report/Moment.swift`
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Session/SessionController.swift` (`writeReport(including:)` filter only)
- Test: `Packages/RedlineCore/Tests/RedlineCoreTests/MomentTests.swift`, `Packages/RedlineCore/Tests/RedlineCoreTests/SessionControllerTests.swift`

**Interfaces:**
- Consumes: `TimelineEvent.aiQuestion`, `.questionAnswered` and `AnswerVia` (Task 1).
- Produces:
  ```swift
  public struct Clarification: Codable, Equatable, Sendable {
      public var questionID: UUID
      public var question: String
      public var options: [String]
      public var answer: String?      // nil when skipped or never answered
      public var via: AnswerVia?      // nil when never answered
      public var t: Double            // when it was asked
      public var isAnswered: Bool     // via == .click || via == .voice
      public init(questionID: UUID, question: String, options: [String], answer: String? = nil, via: AnswerVia? = nil, t: Double)
  }
  ```
  - `Moment.clarifications: [Clarification]` (default `[]`). A question belongs to the moment of its `sentenceID`, falling back to the nearest moment by time.
  - `SessionController.writeReport(including:)` keeps an `aiQuestion` only if its sentence is included, and a `questionAnswered` only if its question was kept.

- [ ] **Step 1: Write the failing tests**

Append to `Packages/RedlineCore/Tests/RedlineCoreTests/MomentTests.swift`:
```swift
@Test func questionsAndAnswersAttachToTheirSentencesMoment() {
    let first = UUID(), q1 = UUID(), q2 = UUID()
    // The question about the first sentence came late (t = 9.5), nearer to moment 2 by time.
    let m = MomentSegmenter.segment([
        .sentence(id: first, text: "make this bigger", start: 0, end: 2),
        .aiQuestion(id: q1, sentenceID: first, text: "Which button?", options: ["Save", "Cancel"], t: 9.5),
        .sentence(id: UUID(), text: "and this row", start: 10, end: 12),
        .questionAnswered(id: q1, answer: "Save", via: .click, t: 11),
        .aiQuestion(id: q2, sentenceID: UUID(), text: "Which row?", options: ["Top", "Bottom"], t: 12.5),
    ])
    #expect(m.count == 2)
    #expect(m[0].clarifications == [Clarification(questionID: q1, question: "Which button?", options: ["Save", "Cancel"],
                                                  answer: "Save", via: .click, t: 9.5)])
    #expect(m[0].clarifications[0].isAnswered)
    // Unknown sentence: nearest moment. Never answered: no answer, not answered.
    #expect(m[1].clarifications.map(\.question) == ["Which row?"])
    #expect(m[1].clarifications[0].answer == nil && m[1].clarifications[0].via == nil && !m[1].clarifications[0].isAnswered)
}

@Test func skippedQuestionsHaveNoAnswer() {
    let id = UUID(), q = UUID()
    let m = MomentSegmenter.segment([
        .sentence(id: id, text: "fix the header", start: 0, end: 2),
        .aiQuestion(id: q, sentenceID: id, text: "Logo or title?", options: ["Logo", "Title"], t: 3),
        .questionAnswered(id: q, answer: "", via: .skipped, t: 23),
    ])
    #expect(m[0].clarifications.count == 1)
    #expect(m[0].clarifications[0].via == .skipped)
    #expect(m[0].clarifications[0].answer == nil)
    #expect(!m[0].clarifications[0].isAnswered)
}
```

In `Packages/RedlineCore/Tests/RedlineCoreTests/SessionControllerTests.swift`, inside `@MainActor @Suite struct SessionControllerTests`, add after `reviewHoldsReportThenWritesOnlySelectedSentences`:
```swift
    @Test func reviewKeepsQuestionsOfChosenSentencesOnly() async throws {
        let builder = FakeBuilder()
        let (c, _) = makeController(builder: builder)
        c.holdReportForReview = true
        await c.start(mode: .chatty)
        let keep = UUID(), drop = UUID(), qKeep = UUID(), qDrop = UUID()
        c.handle(.sentence(id: keep, text: "keep me", start: 1, end: 2))
        c.handle(.aiQuestion(id: qKeep, sentenceID: keep, text: "Which card?", options: ["Billing", "Profile"], t: 2.5))
        c.handle(.questionAnswered(id: qKeep, answer: "Billing", via: .click, t: 3))
        c.handle(.sentence(id: drop, text: "drop me", start: 5, end: 6))
        c.handle(.aiQuestion(id: qDrop, sentenceID: drop, text: "Which row?", options: ["Top", "Bottom"], t: 6.5))
        c.handle(.questionAnswered(id: qDrop, answer: "", via: .skipped, t: 27))
        await c.stop()
        await c.writeReport(including: [keep])
        let doc = try #require(builder.document)
        let questionIDs = doc.events.compactMap { e -> UUID? in
            switch e {
            case let .aiQuestion(id, _, _, _, _): id
            case let .questionAnswered(id, _, _, _): id
            default: nil
            }
        }
        #expect(questionIDs == [qKeep, qKeep])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter "MomentTests|SessionControllerTests"`
Expected: compile error `cannot find 'Clarification' in scope`.

- [ ] **Step 3: Add `Clarification` and attach Q&A to moments**

In `Packages/RedlineCore/Sources/RedlineCore/Report/Moment.swift`, insert after `SentenceRef`:
```swift
/// A clarifying question the live AI asked in Chatty mode, and how it was answered.
public struct Clarification: Codable, Equatable, Sendable {
    public var questionID: UUID
    public var question: String
    public var options: [String]
    /// The option clicked or the sentence said. nil when skipped or never answered.
    public var answer: String?
    /// nil when the question was never closed (e.g. a crashed session).
    public var via: AnswerVia?
    /// When it was asked (seconds since session start).
    public var t: Double

    public var isAnswered: Bool { via == .click || via == .voice }

    public init(questionID: UUID, question: String, options: [String], answer: String? = nil, via: AnswerVia? = nil, t: Double) {
        self.questionID = questionID
        self.question = question
        self.options = options
        self.answer = answer
        self.via = via
        self.t = t
    }
}
```

In `struct Moment`, add after `public var keyframe: KeyframeRef?`:
```swift
    /// Chatty questions about this moment's sentences, in the order asked.
    public var clarifications: [Clarification] = []
```

In `MomentSegmenter.segment(_:)`, replace step 3 and step 4 (from `// 3. Attach marks and clicks to the nearest moment.` to the end of the `for i in moments.indices` loop) with:
```swift
        // 3. Attach marks, clicks and questions to their moment.
        func nearest(_ t: Double) -> Int {
            moments.indices.min { distance(t, moments[$0]) < distance(t, moments[$1]) }!
        }
        func owner(of sentenceID: UUID) -> Int? {
            moments.firstIndex { $0.sentences.contains { $0.id == sentenceID } }
        }
        var urls: [(url: String, t: Double)] = []
        var keyframes: [KeyframeRef] = []
        var answers: [UUID: (answer: String, via: AnswerVia)] = [:]
        for e in sorted {
            switch e {
            case let .userMark(a):
                let i = nearest(a.createdAt)
                moments[i].userMarks.append(a)
            case let .aiAnnotation(sentenceID, anns, _):
                // The AI answers one sentence; its marks belong to that sentence's moment.
                let o = owner(of: sentenceID)
                for a in anns {
                    moments[o ?? nearest(a.createdAt)].aiMarks.append(a)
                }
            case let .aiQuestion(id, sentenceID, text, options, t):
                moments[owner(of: sentenceID) ?? nearest(t)].clarifications.append(
                    Clarification(questionID: id, question: text, options: options, t: t))
            case let .questionAnswered(id, answer, via, _):
                answers[id] = (answer, via)
            case let .click(_, _, t):
                let i = nearest(t)
                moments[i].clickTimes.append(t)
            case let .urlChanged(url, _, t): urls.append((url, t))
            case let .keyframe(ref, _): keyframes.append(ref)
            default: break
            }
        }

        // 4. URL, keyframe and answers per moment.
        for i in moments.indices {
            moments[i].url = urls.last(where: { $0.t <= moments[i].start + 1 })?.url ?? urls.first?.url
            moments[i].keyframe = KeyframeSelector.select(for: moments[i], from: keyframes)
            for j in moments[i].clarifications.indices {
                guard let a = answers[moments[i].clarifications[j].questionID] else { continue }
                moments[i].clarifications[j].via = a.via
                moments[i].clarifications[j].answer = a.via == .skipped ? nil : a.answer
            }
        }
        return moments
```

- [ ] **Step 4: Keep Q&A of chosen sentences in the review filter**

In `Packages/RedlineCore/Sources/RedlineCore/Session/SessionController.swift`, in `writeReport(including:)`, replace:
```swift
        if let ids = sentenceIDs {
            doc.events = doc.events.filter { e in
                switch e {
                case let .sentence(id, _, _, _): return ids.contains(id)
                case let .aiAnnotation(id, _, _): return ids.contains(id)
                default: return true
                }
            }
        }
```
with:
```swift
        if let ids = sentenceIDs {
            // A question goes with the sentence it asked about; its answer goes with the question.
            let keptQuestions = Set(doc.events.compactMap { e -> UUID? in
                guard case let .aiQuestion(qid, sid, _, _, _) = e, ids.contains(sid) else { return nil }
                return qid
            })
            doc.events = doc.events.filter { e in
                switch e {
                case let .sentence(id, _, _, _): return ids.contains(id)
                case let .aiAnnotation(id, _, _): return ids.contains(id)
                case let .aiQuestion(_, sid, _, _, _): return ids.contains(sid)
                case let .questionAnswered(qid, _, _, _): return keptQuestions.contains(qid)
                default: return true
                }
            }
        }
```
Don't change anything else in this file. The `generation`, `starting` and `pendingCancel` guards stay exactly as they are.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter "MomentTests|SessionControllerTests"`
Expected: all pass.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make test`
Expected: `Test run with 136 tests in 7 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add Packages/RedlineCore/Sources/RedlineCore/Report/Moment.swift Packages/RedlineCore/Sources/RedlineCore/Session/SessionController.swift Packages/RedlineCore/Tests/RedlineCoreTests/MomentTests.swift Packages/RedlineCore/Tests/RedlineCoreTests/SessionControllerTests.swift
git commit -m "feat(core): moments carry Chatty questions and answers"
```

---

### Task 3: Q&A in the report prompt and in feedback.md

**Files:**
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Claude/ReportRequest.swift`
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Report/MarkdownRenderer.swift` (`ReportContext`, `MarkdownRenderer.render`)
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Report/ReportBuilder.swift`
- Test: `Packages/RedlineCore/Tests/RedlineCoreTests/ReportRequestTests.swift`, `Packages/RedlineCore/Tests/RedlineCoreTests/MarkdownTests.swift`, `Packages/RedlineCore/Tests/RedlineCoreTests/ReportBuilderTests.swift`

**Interfaces:**
- Consumes: `Clarification`, `Moment.clarifications` (Task 2).
- Produces:
  - `ReportRequest.clarificationLine(_ c: Clarification) -> String`. It returns `AI asked: "<q>" Reviewer answered: "<a>"`, or `AI asked: "<q>" (not answered)`.
  - Each moment's text block gets one such line per clarification, after `Reviewer said:`.
  - The system prompt says answers are the reviewer's own words.
  - `ReportContext.clarifications: [Int: [Clarification]]`, keyed by 0-based item index. It's a new last init parameter, `clarifications: [Int: [Clarification]] = [:]`.
  - `MarkdownRenderer` writes `- **Clarified:** <question> → <answer>` after `You said` for each answered clarification.
  - `ReportBuilder` fills `clarifications` for every item (AI or fallback) from its `momentIDs`, keeping only answered ones.

- [ ] **Step 1: Write the failing tests**

Append to `Packages/RedlineCore/Tests/RedlineCoreTests/ReportRequestTests.swift`:
```swift
@Test func momentTextCarriesQuestionsAndAnswers() {
    var m = Moment(id: 1, start: 0, end: 2, sentences: [SentenceRef(id: UUID(), text: "make it bigger", start: 0, end: 2)])
    m.clarifications = [
        Clarification(questionID: UUID(), question: "Which button?", options: ["Save", "Cancel"], answer: "Save", via: .click, t: 3),
        Clarification(questionID: UUID(), question: "Text or button?", options: ["Text", "Button"], answer: nil, via: .skipped, t: 9),
    ]
    let req = ReportRequest.make(model: "m", input: ReportInput(moments: [m], images: [:], transcript: [], startURL: nil))
    let text = req.messages[0].content.compactMap { block -> String? in
        if case let .text(t) = block, t.hasPrefix("Moment 1") { t } else { nil }
    }.first
    #expect(text == """
    Moment 1 [00:00–00:02] on unknown page
    Reviewer said: make it bigger
    AI asked: "Which button?" Reviewer answered: "Save"
    AI asked: "Text or button?" (not answered)
    """)
}

@Test func systemPromptTreatsAnswersAsTheReviewersWords() {
    #expect(ReportRequest.systemPrompt.contains("clarifying question the live AI asked"))
    #expect(ReportRequest.systemPrompt.contains("The answer is the reviewer's own words"))
}
```

Append to `Packages/RedlineCore/Tests/RedlineCoreTests/MarkdownTests.swift`:
```swift
@Test func rendersClarifiedLinesForAnsweredQuestions() {
    let ctx = ReportContext(appName: "app", startURL: nil, startedAt: Date(timeIntervalSince1970: 0), duration: 5,
                            mode: .chatty, transcript: [], imageFiles: [:], timeZone: .gmt,
                            clarifications: [0: [
                                Clarification(questionID: UUID(), question: "Which card?", options: ["Billing", "Profile"],
                                              answer: "Billing", via: .click, t: 3),
                                Clarification(questionID: UUID(), question: "Ignored?", options: ["Yes", "No"],
                                              answer: nil, via: .skipped, t: 4),
                            ]])
    let md = MarkdownRenderer.render(items: [item], context: ctx)
    #expect(md.contains("- **You said:** \"this card feels really cramped\"\n- **Clarified:** Which card? → Billing\n"))
    #expect(!md.contains("Ignored?"))
}
```

Append to `Packages/RedlineCore/Tests/RedlineCoreTests/ReportBuilderTests.swift`:
```swift
@Test func answeredQuestionsReachFeedbackMarkdown() async throws {
    var (doc, folder) = try makeSession()
    let q = UUID(), skipped = UUID()
    doc.events += [
        .aiQuestion(id: q, sentenceID: UUID(), text: "Which card?", options: ["Billing card", "Plan card"], t: 2.5),
        .questionAnswered(id: q, answer: "Billing card", via: .voice, t: 4),
        .aiQuestion(id: skipped, sentenceID: UUID(), text: "Smaller font too?", options: ["Yes", "No"], t: 4.5),
        .questionAnswered(id: skipped, answer: "", via: .skipped, t: 25),
    ]
    // Fallback report (no key): still one Clarified line, for the answered question only.
    _ = await ReportBuilder(llm: nil, model: "m", timeZone: .gmt).build(document: doc, folder: folder)
    let fallback = try String(contentsOf: folder.feedbackURL, encoding: .utf8)
    #expect(fallback.contains("- **Clarified:** Which card? → Billing card\n"))
    #expect(fallback.components(separatedBy: "**Clarified:**").count == 2)

    // AI report: the item that lists moment 1 gets the same line.
    let llm = FakeLLM(text: #"{"items":[{"title":"Loosen billing card padding","moment_ids":[1],"where":"/billing","problem":"cramped","wanted":"more padding","quote":"this card is too cramped","image_caption":""}]}"#)
    _ = await ReportBuilder(llm: llm, model: "claude-sonnet-5-5", timeZone: .gmt).build(document: doc, folder: folder)
    let ai = try String(contentsOf: folder.feedbackURL, encoding: .utf8)
    #expect(ai.contains("## 1. Loosen billing card padding"))
    #expect(ai.contains("- **Clarified:** Which card? → Billing card\n"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter "ReportRequestTests|MarkdownTests|ReportBuilderTests"`
Expected: compile error `extra argument 'clarifications' in call`.

- [ ] **Step 3: Add Q&A to the report request**

In `Packages/RedlineCore/Sources/RedlineCore/Claude/ReportRequest.swift`, in `systemPrompt`, replace:
```swift
    Use the blue marks as hints, but trust the reviewer's words and red marks over them.

```
with:
```swift
    Use the blue marks as hints, but trust the reviewer's words and red marks over them.

    Some moments also show a clarifying question the live AI asked while the reviewer talked, and the reviewer's \
    answer. The answer is the reviewer's own words: treat it like anything else they said, and prefer it over the \
    AI's guesses.

```

In `make(model:input:)`, replace:
```swift
            blocks.append(.text("\(header)\nReviewer said: \(m.text.isEmpty ? "(nothing)" : m.text)"))
```
with:
```swift
            var said = "\(header)\nReviewer said: \(m.text.isEmpty ? "(nothing)" : m.text)"
            for c in m.clarifications { said += "\n" + clarificationLine(c) }
            blocks.append(.text(said))
```

Add after `aiMarksNote(_:)`:
```swift
    /// `AI asked: "Which card?" Reviewer answered: "Billing"`, or `AI asked: "Which card?" (not answered)`.
    static func clarificationLine(_ c: Clarification) -> String {
        let asked = "AI asked: \"\(c.question)\""
        guard c.isAnswered, let answer = c.answer else { return asked + " (not answered)" }
        return asked + " Reviewer answered: \"\(answer)\""
    }
```

- [ ] **Step 4: Render the Clarified line**

In `Packages/RedlineCore/Sources/RedlineCore/Report/MarkdownRenderer.swift`, replace `ReportContext` with:
```swift
public struct ReportContext: Sendable {
    public var appName: String
    public var startURL: String?
    public var startedAt: Date
    public var duration: Double
    public var mode: SessionMode
    public var transcript: [TranscriptLine]
    /// Keyed by 0-based item index.
    public var imageFiles: [Int: String]
    public var timeZone: TimeZone
    /// Chatty questions behind each item, keyed by 0-based item index. Only answered ones are rendered.
    public var clarifications: [Int: [Clarification]]

    public init(appName: String, startURL: String?, startedAt: Date, duration: Double, mode: SessionMode,
                transcript: [TranscriptLine], imageFiles: [Int: String], timeZone: TimeZone = .current,
                clarifications: [Int: [Clarification]] = [:]) {
        self.appName = appName
        self.startURL = startURL
        self.startedAt = startedAt
        self.duration = duration
        self.mode = mode
        self.transcript = transcript
        self.imageFiles = imageFiles
        self.timeZone = timeZone
        self.clarifications = clarifications
    }
}
```

In `MarkdownRenderer.render(items:context:)`, replace:
```swift
            line("You said", item.quote.isEmpty ? "" : "\"\(item.quote)\"")
```
with:
```swift
            line("You said", item.quote.isEmpty ? "" : "\"\(item.quote)\"")
            for c in context.clarifications[i] ?? [] {
                if c.isAnswered, let answer = c.answer { line("Clarified", "\(c.question) → \(answer)") }
            }
```

- [ ] **Step 5: Pass Q&A per item from the builder**

In `Packages/RedlineCore/Sources/RedlineCore/Report/ReportBuilder.swift`, in `build(document:folder:)`, replace:
```swift
        let context = ReportContext(appName: SessionFolder.slug(fromURL: startURL), startURL: startURL,
                                    startedAt: document.metadata.startedAt, duration: duration, mode: document.metadata.mode,
                                    transcript: transcript, imageFiles: imageFiles, timeZone: timeZone)
```
with:
```swift
        let momentsByID = Dictionary(uniqueKeysWithValues: moments.map { ($0.id, $0) })
        var clarifications: [Int: [Clarification]] = [:]
        for (i, item) in items.enumerated() {
            let answered = item.momentIDs.compactMap { momentsByID[$0] }.flatMap(\.clarifications).filter(\.isAnswered)
            if !answered.isEmpty { clarifications[i] = answered }
        }
        let context = ReportContext(appName: SessionFolder.slug(fromURL: startURL), startURL: startURL,
                                    startedAt: document.metadata.startedAt, duration: duration, mode: document.metadata.mode,
                                    transcript: transcript, imageFiles: imageFiles, timeZone: timeZone,
                                    clarifications: clarifications)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter "ReportRequestTests|MarkdownTests|ReportBuilderTests"`
Expected: all pass. `systemPromptExplainsBothMarkColours` and `rendersGoldenMarkdown` are unchanged and still pass.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make test`
Expected: `Test run with 140 tests in 7 suites passed`.

- [ ] **Step 7: Commit**

```bash
git add Packages/RedlineCore/Sources/RedlineCore/Claude/ReportRequest.swift Packages/RedlineCore/Sources/RedlineCore/Report/MarkdownRenderer.swift Packages/RedlineCore/Sources/RedlineCore/Report/ReportBuilder.swift Packages/RedlineCore/Tests/RedlineCoreTests/ReportRequestTests.swift Packages/RedlineCore/Tests/RedlineCoreTests/MarkdownTests.swift Packages/RedlineCore/Tests/RedlineCoreTests/ReportBuilderTests.swift
git commit -m "feat(core): Chatty answers in the report prompt and feedback.md"
```

---

### Task 4: Chatty annotate request and answer parsing

**Files:**
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Live/LiveTypes.swift`
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Live/AnnotateRequest.swift` (whole file replaced below)
- Test: `Packages/RedlineCore/Tests/RedlineCoreTests/AnnotateRequestTests.swift`

**Interfaces:**
- Consumes: `MessagesRequest`, `JSONValue`, `LiveFrame`, `CoordinateMapper`, `ClaudeError` (existing).
- Produces:
  - `public struct LiveQuestion: Equatable, Sendable { var text: String; var options: [String]; init(text:options:) }`
  - `public struct LiveAnswer: Equatable, Sendable { var marks: [Annotation]; var say: String; var question: LiveQuestion?; init(marks:say:question:) }`
  - `AnnotateRequest` limits: `maxSayWords = 12`, `maxOptionWords = 4`, `minOptions = 2`, `maxOptions = 3`.
  - `AnnotateRequest.chattyPrompt: String`, `AnnotateRequest.chattySchema: JSONValue` (`schema` is unchanged).
  - `AnnotateRequest.make(model:frame:sentence:recentSentences:clicks:url:chatty: Bool = false, answering: String? = nil) -> MessagesRequest`
  - `AnnotateRequest.parseAnswer(_ text: String, frame: LiveFrame, createdAt: Double) throws -> LiveAnswer`
  - `parse(_:frame:createdAt:)` keeps its signature and returns `parseAnswer(...).marks`.

- [ ] **Step 1: Write the failing tests**

Append to `Packages/RedlineCore/Tests/RedlineCoreTests/AnnotateRequestTests.swift`. It goes in the same file so the private `json(_:)` helper is in scope.
```swift
@Suite struct ChattyAnnotateRequestTests {
    @Test func chattyRequestAddsSayAndQuestion() throws {
        let req = AnnotateRequest.make(model: "claude-haiku-5-5", frame: liveTestFrame(), sentence: "make it bigger",
                                       recentSentences: [], clicks: [], url: nil, chatty: true)
        let body = try json(req)
        #expect(body["tool_choice"] == nil)
        #expect(body["temperature"] == nil)
        let system = try #require(body["system"] as? String)
        #expect(system.hasPrefix(AnnotateRequest.systemPrompt))
        #expect(system.hasSuffix(AnnotateRequest.chattyPrompt))
        let oc = try #require(body["output_config"] as? [String: Any])
        #expect(oc["effort"] as? String == "low")
        let format = try #require(oc["format"] as? [String: Any])
        let schema = try #require(format["schema"] as? [String: Any])
        let props = try #require(schema["properties"] as? [String: Any])
        #expect(Set(props.keys) == ["marks", "say", "question"])
        #expect(Set(schema["required"] as? [String] ?? []) == ["marks", "say", "question"])
        #expect(schema["additionalProperties"] as? Bool == false)
        let question = try #require(props["question"] as? [String: Any])
        #expect(Set(question["required"] as? [String] ?? []) == ["text", "options"])
        #expect(question["additionalProperties"] as? Bool == false)
    }

    @Test func liveRequestKeepsTheLiveSchemaAndPrompt() {
        let req = AnnotateRequest.make(model: "claude-haiku-5-5", frame: liveTestFrame(), sentence: "x",
                                       recentSentences: [], clicks: [], url: nil)
        #expect(req.system == AnnotateRequest.systemPrompt)
        #expect(req.output_config?.format?.schema == AnnotateRequest.schema)
        guard case let .object(root) = AnnotateRequest.schema, case let .object(props)? = root["properties"] else {
            Issue.record("bad schema"); return
        }
        #expect(Set(props.keys) == ["marks"])
    }

    @Test func answeringSentenceCarriesTheQuestion() {
        func text(_ req: MessagesRequest) -> String {
            req.messages[0].content.compactMap { if case let .text(s) = $0 { s } else { nil } }.joined()
        }
        let answering = AnnotateRequest.make(model: "claude-haiku-5-5", frame: liveTestFrame(), sentence: "the billing one",
                                             recentSentences: [], clicks: [], url: nil, chatty: true, answering: "Which card?")
        #expect(text(answering).contains("You asked: Which card?"))
        #expect(text(answering).contains("Reviewer just said: the billing one"))
        let plain = AnnotateRequest.make(model: "claude-haiku-5-5", frame: liveTestFrame(), sentence: "the billing one",
                                         recentSentences: [], clicks: [], url: nil, chatty: true)
        #expect(!text(plain).contains("You asked"))
    }

    @Test func parseAnswerReadsSayAndQuestion() throws {
        let text = #"{"marks":[{"shape":"rect","x":10,"y":10,"w":100,"h":50,"caption":"Save"}],"say":" I marked the left card. ","question":{"text":" Which card? ","options":["Billing card"," Profile card "]}}"#
        let a = try AnnotateRequest.parseAnswer(text, frame: liveTestFrame(), createdAt: 2)
        #expect(a.marks.count == 1)
        #expect(a.marks.first?.caption == "Save")
        #expect(a.say == "I marked the left card.")
        #expect(a.question == LiveQuestion(text: "Which card?", options: ["Billing card", "Profile card"]))
    }

    @Test func parseAnswerCapsWordsAndOptions() throws {
        let text = #"{"marks":[],"say":"one two three four five six seven eight nine ten eleven twelve thirteen","question":{"text":"Which card?","options":["Billing card","The profile card on the right","billing CARD","Team card","Usage card"]}}"#
        let a = try AnnotateRequest.parseAnswer(text, frame: liveTestFrame(), createdAt: 0)
        #expect(a.say == "one two three four five six seven eight nine ten eleven twelve")
        #expect(a.question?.options == ["Billing card", "The profile card on", "Team card"])
    }

    @Test func parseAnswerDropsQuestionsWithoutTwoOptions() throws {
        func question(_ q: String) throws -> LiveQuestion? {
            try AnnotateRequest.parseAnswer(#"{"marks":[],"say":"","question":"# + q + "}", frame: liveTestFrame(), createdAt: 0).question
        }
        #expect(try question(#"{"text":"","options":[]}"#) == nil)
        #expect(try question(#"{"text":"Which?","options":["Only one"]}"#) == nil)
        #expect(try question(#"{"text":"Which?","options":["A"," ","a"]}"#) == nil)
        #expect(try question(#"{"text":"  ","options":["A","B"]}"#) == nil)
        #expect(try question(#"{"text":"Which?","options":["A","B"]}"#) == LiveQuestion(text: "Which?", options: ["A", "B"]))
    }

    @Test func liveAnswerHasNoChattyFields() throws {
        let a = try AnnotateRequest.parseAnswer(#"{"marks":[]}"#, frame: liveTestFrame(), createdAt: 0)
        #expect(a == LiveAnswer(marks: [], say: "", question: nil))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter AnnotateRequestTests`
Expected: compile errors, including `extra argument 'chatty' in call` and `cannot find 'LiveQuestion' in scope`.

- [ ] **Step 3: Add the shared answer types**

Append to `Packages/RedlineCore/Sources/RedlineCore/Live/LiveTypes.swift`:
```swift
/// A clarifying question from the live model (Chatty): read aloud, and shown in the island with its
/// options as buttons plus Skip.
public struct LiveQuestion: Equatable, Sendable {
    public var text: String
    /// 2–3 short answers, at most 4 words each.
    public var options: [String]

    public init(text: String, options: [String]) {
        self.text = text
        self.options = options
    }
}

/// Everything one live answer holds. Outside Chatty mode `say` is "" and `question` is nil.
public struct LiveAnswer: Equatable, Sendable {
    public var marks: [Annotation]
    /// A short line to speak, at most 12 words; "" to stay silent.
    public var say: String
    public var question: LiveQuestion?

    public init(marks: [Annotation], say: String, question: LiveQuestion?) {
        self.marks = marks
        self.say = say
        self.question = question
    }
}
```

- [ ] **Step 4: Replace AnnotateRequest.swift**

Replace the whole of `Packages/RedlineCore/Sources/RedlineCore/Live/AnnotateRequest.swift` with the code below. `systemPrompt`, the mark schema, `thinking(for:)` and the mark-conversion loop are unchanged from phase 2.
```swift
import CoreGraphics
import Foundation

/// Builds the Live-mode "annotate" request and turns its answer into on-screen AI marks.
/// In Chatty mode the same request also asks for a short spoken line and an optional clarifying question.
public enum AnnotateRequest {
    /// At most this many marks are kept from one answer.
    public static let maxMarks = 3
    /// Chatty limits (spec §10): a spoken line is at most 12 words; a question has 2–3 options of at most 4 words.
    public static let maxSayWords = 12
    public static let maxOptionWords = 4
    public static let minOptions = 2
    public static let maxOptions = 3
    /// Boxes thinner than this (image pixels) are widened to it around their centre, so a point or a
    /// one-line answer still makes a visible mark.
    static let minBox: Double = 16
    /// How far an arrow's tail starts from its tip, in image pixels.
    static let arrowLength = CGSize(width: 70, height: 40)

    public static let systemPrompt = """
    You watch a reviewer talk through an app on their screen. After each sentence they say, you get a \
    screenshot of their display and you mark what the reviewer is referring to, so they can see you understood.

    - Find the thing on screen the reviewer means and give its bounding box: x, y is its top-left corner and \
    w, h its size, in the screenshot's pixel space (origin top-left, x right, y down). Fit the box tightly \
    around the element (the card, button, column or text), and always give real values: w and h are never 0.
    - The mouse pointer is visible in the screenshot. Reviewers usually rest it on what they are talking about, \
    so use it with their words. Their recent clicks are given in the same pixel space.
    - shape says how to draw the mark around that box: "circle" for a small thing or a single value, "rect" for \
    a card, panel or area, "highlight" for a line of text, "arrow" to point at something small or easily missed.
    - Prefer one mark; use two or three only if they clearly point at several things.
    - caption: the change the reviewer is asking for, as a short instruction of at most 8 words, written like a \
    note on a printout: "Rename to NSR revenue", "Make this purple", "Show in thousands". Don't describe what is \
    there now. If they only point at something without asking for a change, name it briefly.
    - If the sentence doesn't refer to anything on screen (thinking aloud, "ok, next"), return no marks.
    """

    /// Appended to `systemPrompt` in Chatty mode.
    public static let chattyPrompt = """
    Chatty mode is on: as well as marking, you can talk to the reviewer. What you put in say and question is read aloud.
    - say: one short line of at most 12 words, or "" to stay silent. Stay silent most of the time and just mark. \
    Speak only when your mark might be wrong ("I marked the left card. Is that it?") or when the reviewer has \
    moved on to a new topic or page ("Now looking at billing."). Never repeat their words or describe your mark.
    - question: ask only when two or more things on screen fit what they said, or when the change they want is \
    unclear. text is the question, at most 12 words, and must make sense heard on its own. options are 2 or 3 \
    short answers of at most 4 words each; they are shown as buttons. When you ask, still mark your best guess \
    and leave say "". When you don't need to ask, give text "" and options [].
    - If you just asked a question, this sentence is the reviewer's answer: mark what they picked and don't ask again.
    """

    public static let schema: JSONValue = makeSchema(chatty: false)
    public static let chattySchema: JSONValue = makeSchema(chatty: true)

    static func makeSchema(chatty: Bool) -> JSONValue {
        func num() -> JSONValue { .object(["type": .string("number")]) }
        func str() -> JSONValue { .object(["type": .string("string")]) }
        let keys = ["shape", "x", "y", "w", "h", "caption"]
        let mark: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "shape": .object([
                    "type": .string("string"),
                    "enum": .array(["circle", "rect", "arrow", "highlight"].map(JSONValue.string)),
                ]),
                "x": num(), "y": num(), "w": num(), "h": num(),
                "caption": str(),
            ]),
            "required": .array(keys.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
        var properties: [String: JSONValue] = ["marks": .object(["type": .string("array"), "items": mark])]
        var required: [JSONValue] = [.string("marks")]
        if chatty {
            properties["say"] = str()
            properties["question"] = .object([
                "type": .string("object"),
                "properties": .object([
                    "text": str(),
                    "options": .object(["type": .string("array"), "items": str()]),
                ]),
                "required": .array([.string("text"), .string("options")]),
                "additionalProperties": .bool(false),
            ])
            required += [.string("say"), .string("question")]
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required),
            "additionalProperties": .bool(false),
        ])
    }

    /// - Parameters:
    ///   - sentence: the sentence just finished.
    ///   - recentSentences: earlier sentences for context, oldest first (the current one excluded).
    ///   - clicks: clicks since the previous sentence, in global points, on `frame.display`.
    ///   - chatty: adds `chattyPrompt` and the `say`/`question` fields.
    ///   - answering: the question this sentence answers (Chatty voice answer), if any.
    public static func make(model: String, frame: LiveFrame, sentence: String, recentSentences: [String],
                            clicks: [CGPoint], url: String?, chatty: Bool = false, answering: String? = nil) -> MessagesRequest {
        var lines: [String] = []
        lines.append("Page: \(url ?? "unknown")")
        lines.append("Screenshot size: \(Int(frame.pixelSize.width.rounded()))x\(Int(frame.pixelSize.height.rounded())) px")
        if !recentSentences.isEmpty {
            lines.append("Earlier sentences:\n" + recentSentences.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !clicks.isEmpty {
            let pts = clicks.map { p -> String in
                let ip = CoordinateMapper.imagePoint(fromGlobal: p, imageSize: frame.pixelSize, on: frame.display)
                return "(\(Int(ip.x.rounded())), \(Int(ip.y.rounded())))"
            }
            lines.append("Clicks (image px): " + pts.joined(separator: ", "))
        }
        if let answering {
            lines.append("You asked: \(answering)\nThis sentence is the reviewer's answer.")
        }
        lines.append("Reviewer just said: \(sentence)")

        return MessagesRequest(
            model: model,
            max_tokens: 2000,
            system: chatty ? systemPrompt + "\n\n" + chattyPrompt : systemPrompt,
            messages: [.init(role: "user", content: [.jpeg(frame.jpeg), .text(lines.joined(separator: "\n"))])],
            output_config: .init(effort: "low", format: .init(schema: chatty ? chattySchema : schema)),
            thinking: thinking(for: model),
            fallbacks: model.hasPrefix("claude-sonnet") ? "default" : nil)
    }

    /// Thinking off: a live mark is a quick look, and reasoning made answers several seconds slower.
    /// Haiku turns it off with "disabled"; Sonnet 5.5 rejects that and uses "between_tools" (no tools here).
    static func thinking(for model: String) -> MessagesRequest.Thinking? {
        if model.hasPrefix("claude-haiku") { return .init(type: "disabled") }
        if model.hasPrefix("claude-sonnet-5-5") { return .init(type: "between_tools") }
        return nil
    }

    private struct Mark: Decodable {
        var shape: String
        var x, y, w, h: Double
        var caption: String
    }
    private struct Question: Decodable {
        var text: String
        var options: [String]
    }
    /// `say` and `question` are only present in Chatty answers.
    private struct Envelope: Decodable {
        var marks: [Mark]
        var say: String?
        var question: Question?
    }

    /// Converts the model's answer into AI annotations in global points (see `parseAnswer`).
    public static func parse(_ text: String, frame: LiveFrame, createdAt: Double) throws -> [Annotation] {
        try parseAnswer(text, frame: frame, createdAt: createdAt).marks
    }

    /// Reads a Live or Chatty answer.
    /// - Marks: a box with no position at all is dropped, a too-thin one is widened, everything is clamped to
    ///   the image, and at most `maxMarks` are kept.
    /// - `say` is trimmed to `maxSayWords` words.
    /// - The question is trimmed. Its options are cut to `maxOptionWords` words, de-duplicated ignoring case and
    ///   capped at `maxOptions`. It is dropped if its text is empty or fewer than `minOptions` options remain.
    public static func parseAnswer(_ text: String, frame: LiveFrame, createdAt: Double) throws -> LiveAnswer {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
        } catch {
            throw ClaudeError.invalidJSON(String(text.prefix(200)))
        }
        return LiveAnswer(marks: annotations(envelope.marks, frame: frame, createdAt: createdAt),
                          say: words(envelope.say ?? "", max: maxSayWords),
                          question: envelope.question.flatMap(liveQuestion))
    }

    /// The first `max` words of `s`, with runs of whitespace collapsed; "" when blank.
    static func words(_ s: String, max: Int) -> String {
        s.split(whereSeparator: \.isWhitespace).prefix(max).joined(separator: " ")
    }

    private static func liveQuestion(_ q: Question) -> LiveQuestion? {
        let text = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var options: [String] = []
        for option in q.options.map({ words($0, max: maxOptionWords) }) where !option.isEmpty {
            if !options.contains(where: { $0.caseInsensitiveCompare(option) == .orderedSame }) { options.append(option) }
        }
        options = Array(options.prefix(maxOptions))
        guard !text.isEmpty, options.count >= minOptions else { return nil }
        return LiveQuestion(text: text, options: options)
    }

    private static func annotations(_ marks: [Mark], frame: LiveFrame, createdAt: Double) -> [Annotation] {
        let size = frame.pixelSize
        guard size.width > 0, size.height > 0 else { return [] }
        let bounds = CGRect(origin: .zero, size: size)
        let display = frame.display
        func global(_ p: CGPoint) -> CGPoint {
            CoordinateMapper.global(fromImagePoint: p, imageSize: size, on: display)
        }
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
        }
        func globalRect(_ r: CGRect) -> CGRect {
            let a = global(CGPoint(x: r.minX, y: r.minY)), b = global(CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
        /// Image pixels → points (the frame covers the whole display).
        let pointsPerPixel = display.frame.width / size.width

        var out: [Annotation] = []
        for m in marks {
            guard [m.x, m.y, m.w, m.h].allSatisfy(\.isFinite), !(m.x == 0 && m.y == 0 && m.w == 0 && m.h == 0) else { continue }
            var box = CGRect(x: m.x, y: m.y, width: m.w, height: m.h).standardized
            box = box.insetBy(dx: -max(0, minBox - box.width) / 2, dy: -max(0, minBox - box.height) / 2)
            box = box.intersection(bounds)
            guard !box.isNull, box.width >= 1, box.height >= 1 else { continue }

            let shape: AnnotationShape
            switch m.shape {
            case "circle":
                let radius = max(box.width, box.height) / 2 * 1.15 + 4
                shape = .circle(center: global(CGPoint(x: box.midX, y: box.midY)), radius: radius * pointsPerPixel)
            case "rect":
                shape = .rect(globalRect(box.insetBy(dx: -4, dy: -4).intersection(bounds)))
            case "highlight":
                shape = .highlight(globalRect(box))
            case "arrow":
                // Points at the box's left edge from up-left, or from the right when there's no room.
                let fromLeft = box.minX - 4 - arrowLength.width >= 0
                let tip = CGPoint(x: fromLeft ? box.minX - 4 : box.maxX + 4, y: box.midY)
                let tail = CGPoint(x: tip.x + (fromLeft ? -arrowLength.width : arrowLength.width),
                                   y: tip.y - arrowLength.height)
                shape = .arrow(from: global(clamp(tail)), to: global(clamp(tip)))
            default:
                continue
            }
            let caption = m.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Annotation(shape: shape, caption: caption.isEmpty ? nil : caption, author: .ai,
                                  createdAt: createdAt, displayID: display.id))
            if out.count == maxMarks { break }
        }
        return out
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter AnnotateRequestTests`
Expected: all pass: the 10 existing tests in `AnnotateRequestTests`, including `schemaIsStrict` and `malformedThrowsInvalidJSON`, and 7 new ones in `ChattyAnnotateRequestTests`.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make test`
Expected: `Test run with 147 tests in 8 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add Packages/RedlineCore/Sources/RedlineCore/Live/LiveTypes.swift Packages/RedlineCore/Sources/RedlineCore/Live/AnnotateRequest.swift Packages/RedlineCore/Tests/RedlineCoreTests/AnnotateRequestTests.swift
git commit -m "feat(core): Chatty say and question in the live request"
```

---

### Task 5: ChattyConversation (turn-taking rules)

**Files:**
- Create: `Packages/RedlineCore/Sources/RedlineCore/Live/ChattyConversation.swift`
- Test: `Packages/RedlineCore/Tests/RedlineCoreTests/ChattyConversationTests.swift`

**Interfaces:**
- Consumes: `LiveQuestion` (Task 4), `TimelineEvent.aiQuestion`/`.questionAnswered`, `AnswerVia` (Task 1).
- Produces:
  ```swift
  public struct ChattyConversation: Sendable {
      public static let lineInterval: Double = 10
      public struct Question: Equatable, Sendable, Identifiable {
          public var id: UUID; public var sentenceID: UUID; public var text: String
          public var options: [String]; public var askedAt: Double
          public var event: TimelineEvent   // .aiQuestion(id:sentenceID:text:options:t: askedAt)
      }
      public struct Outcome: Equatable, Sendable {
          public var asked: Question?; public var speak: String?; public var said: String?
          public init(asked: Question? = nil, speak: String? = nil, said: String? = nil)
      }
      public private(set) var open: Question?
      public init()
      public mutating func reset()
      public mutating func respond(say: String, question: LiveQuestion?, sentenceID: UUID, at t: Double) -> Outcome
      public mutating func answer(_ answer: String, via: AnswerVia, at t: Double) -> TimelineEvent?
      public mutating func expire(_ id: UUID, at t: Double) -> TimelineEvent?
      public mutating func voiceAnswer(text: String, start: Double, at t: Double) -> (question: Question, event: TimelineEvent)?
  }
  ```
  All times are seconds since session start.

- [ ] **Step 1: Write the failing tests**

`Packages/RedlineCore/Tests/RedlineCoreTests/ChattyConversationTests.swift`:
```swift
import Testing
import Foundation
@testable import RedlineCore

private let which = LiveQuestion(text: "Which button?", options: ["Save", "Cancel"])

@Suite struct ChattyConversationTests {
    let sentence = UUID()

    @Test func questionOpensAndOnlyItsTextIsSpoken() throws {
        var c = ChattyConversation()
        let out = c.respond(say: "I marked Save.", question: which, sentenceID: sentence, at: 5)
        let q = try #require(out.asked)
        #expect(out.speak == "Which button?")
        #expect(out.said == nil)
        #expect(c.open == q)
        #expect(q.askedAt == 5 && q.sentenceID == sentence && q.options == ["Save", "Cancel"])
        #expect(q.event == .aiQuestion(id: q.id, sentenceID: sentence, text: "Which button?", options: ["Save", "Cancel"], t: 5))
    }

    @Test func onlyOneQuestionAtATime() throws {
        var c = ChattyConversation()
        let first = try #require(c.respond(say: "", question: which, sentenceID: sentence, at: 5).asked)
        // A second question while one is open is dropped; the question also counts as the last spoken line.
        let soon = c.respond(say: "I marked Save.", question: LiveQuestion(text: "Which row?", options: ["Top", "Bottom"]),
                             sentenceID: UUID(), at: 8)
        #expect(soon == ChattyConversation.Outcome())
        #expect(c.open == first)
        // Later, the remark from the same answer may still be spoken, but the question stays dropped.
        let later = c.respond(say: "I marked Save.", question: LiveQuestion(text: "Which row?", options: ["Top", "Bottom"]),
                              sentenceID: UUID(), at: 15)
        #expect(later == ChattyConversation.Outcome(speak: "I marked Save.", said: "I marked Save."))
        #expect(c.open == first)
    }

    @Test func remarksAtMostEveryTenSeconds() {
        var c = ChattyConversation()
        #expect(c.respond(say: " Now on billing. ", question: nil, sentenceID: sentence, at: 0)
                == ChattyConversation.Outcome(speak: "Now on billing.", said: "Now on billing."))
        #expect(c.respond(say: "Now on profile.", question: nil, sentenceID: sentence, at: 9.9) == ChattyConversation.Outcome())
        #expect(c.respond(say: "Now on profile.", question: nil, sentenceID: sentence, at: 10).speak == "Now on profile.")
        #expect(c.respond(say: "   ", question: nil, sentenceID: sentence, at: 60) == ChattyConversation.Outcome())
    }

    @Test func questionsIgnoreTheLineLimit() {
        var c = ChattyConversation()
        _ = c.respond(say: "Now on billing.", question: nil, sentenceID: sentence, at: 0)
        let out = c.respond(say: "", question: which, sentenceID: sentence, at: 3)
        #expect(out.asked != nil)
        #expect(out.speak == "Which button?")
    }

    @Test func clickAnswerClosesTheQuestion() throws {
        var c = ChattyConversation()
        let q = try #require(c.respond(say: "", question: which, sentenceID: sentence, at: 5).asked)
        #expect(c.answer("Save", via: .click, at: 7) == .questionAnswered(id: q.id, answer: "Save", via: .click, t: 7))
        #expect(c.open == nil)
        #expect(c.answer("Cancel", via: .click, at: 8) == nil)
    }

    @Test func voiceAnswerIsTheNextSentenceAfterTheQuestion() throws {
        var c = ChattyConversation()
        let q = try #require(c.respond(say: "", question: which, sentenceID: sentence, at: 5).asked)
        // A sentence already under way when the question came isn't the answer.
        #expect(c.voiceAnswer(text: "and also the header", start: 4, at: 6) == nil)
        #expect(c.open == q)
        let answered = try #require(c.voiceAnswer(text: "the save one", start: 5.5, at: 7))
        #expect(answered.question == q)
        #expect(answered.event == .questionAnswered(id: q.id, answer: "the save one", via: .voice, t: 7))
        #expect(c.open == nil)
    }

    @Test func expireClosesOnlyThatQuestionAndResetClearsEverything() throws {
        var c = ChattyConversation()
        let q = try #require(c.respond(say: "", question: which, sentenceID: sentence, at: 5).asked)
        #expect(c.expire(UUID(), at: 25) == nil)
        #expect(c.expire(q.id, at: 25) == .questionAnswered(id: q.id, answer: "", via: .skipped, t: 25))
        #expect(c.expire(q.id, at: 26) == nil)
        _ = c.respond(say: "", question: which, sentenceID: sentence, at: 30)
        c.reset()
        #expect(c.open == nil)
        #expect(c.respond(say: "Hello.", question: nil, sentenceID: sentence, at: 31).speak == "Hello.")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter ChattyConversationTests`
Expected: compile error `cannot find 'ChattyConversation' in scope`.

- [ ] **Step 3: Write ChattyConversation**

`Packages/RedlineCore/Sources/RedlineCore/Live/ChattyConversation.swift`:
```swift
import Foundation

/// Chatty mode's turn-taking rules (spec §10), kept apart from the network code so they can be tested with
/// plain times (seconds since session start).
///
/// - A short remark is spoken at most once every `lineInterval` seconds. Questions skip that limit, and asking
///   one counts as the last spoken line.
/// - Only one clarifying question is open at a time. A new one while another is open is dropped; that answer's
///   remark may still be spoken. When a question opens, only its text is spoken.
/// - The open question closes on a click (`answer`), on the reviewer's next sentence that started after it was
///   asked (`voiceAnswer`), or as skipped (`answer(_:via: .skipped,…)` or `expire`).
public struct ChattyConversation: Sendable {
    public static let lineInterval: Double = 10

    public struct Question: Equatable, Sendable, Identifiable {
        public var id: UUID
        /// The sentence the question is about.
        public var sentenceID: UUID
        public var text: String
        public var options: [String]
        /// When it was asked.
        public var askedAt: Double

        /// The timeline event that logs this question.
        public var event: TimelineEvent {
            .aiQuestion(id: id, sentenceID: sentenceID, text: text, options: options, t: askedAt)
        }
    }

    /// What to do with one live answer.
    public struct Outcome: Equatable, Sendable {
        /// A question that was just opened.
        public var asked: Question?
        /// What to speak now, if anything.
        public var speak: String?
        /// The remark that was spoken, for `aiAnnotation.say`. nil when silent or when a question was spoken.
        public var said: String?

        public init(asked: Question? = nil, speak: String? = nil, said: String? = nil) {
            self.asked = asked
            self.speak = speak
            self.said = said
        }
    }

    public private(set) var open: Question?
    private var lastSpokenAt: Double?

    public init() {}

    public mutating func reset() {
        open = nil
        lastSpokenAt = nil
    }

    /// Decides what to say for the live answer to `sentenceID`, received at `t`.
    public mutating func respond(say: String, question: LiveQuestion?, sentenceID: UUID, at t: Double) -> Outcome {
        if let question, open == nil {
            let q = Question(id: UUID(), sentenceID: sentenceID, text: question.text, options: question.options, askedAt: t)
            open = q
            lastSpokenAt = t
            return Outcome(asked: q, speak: q.text)
        }
        let line = say.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, lastSpokenAt.map({ t - $0 >= Self.lineInterval }) ?? true else { return Outcome() }
        lastSpokenAt = t
        return Outcome(speak: line, said: line)
    }

    /// Closes the open question with `answer` (a clicked option, or "" with `.skipped`). nil when none is open.
    public mutating func answer(_ answer: String, via: AnswerVia, at t: Double) -> TimelineEvent? {
        guard let q = open else { return nil }
        open = nil
        return .questionAnswered(id: q.id, answer: answer, via: via, t: t)
    }

    /// The 20 s timeout: skips question `id` if it is still the open one.
    public mutating func expire(_ id: UUID, at t: Double) -> TimelineEvent? {
        guard open?.id == id else { return nil }
        return answer("", via: .skipped, at: t)
    }

    /// A finished sentence answers the open question if it started at or after the question was asked.
    public mutating func voiceAnswer(text: String, start: Double, at t: Double) -> (question: Question, event: TimelineEvent)? {
        guard let q = open, start >= q.askedAt else { return nil }
        open = nil
        return (q, .questionAnswered(id: q.id, answer: text, via: .voice, t: t))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter ChattyConversationTests`
Expected: all 7 tests pass.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make test`
Expected: `Test run with 154 tests in 9 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Packages/RedlineCore/Sources/RedlineCore/Live/ChattyConversation.swift Packages/RedlineCore/Tests/RedlineCoreTests/ChattyConversationTests.swift
git commit -m "feat(core): Chatty turn-taking rules"
```

---

### Task 6: MicGate

**Files:**
- Create: `Packages/RedlineCore/Sources/RedlineCore/Input/MicGate.swift`
- Test: `Packages/RedlineCore/Tests/RedlineCoreTests/MicGateTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public final class MicGate: Sendable {
      public static let defaultTail: Duration          // .milliseconds(300)
      public init(tail: Duration = MicGate.defaultTail)
      public func close()                                                    // speaking started
      public func open(at now: ContinuousClock.Instant = .now)               // speaking ended; listen after the tail
      public func isListening(at now: ContinuousClock.Instant = .now) -> Bool
  }
  ```
  It's safe to call from any thread. The audio thread calls `isListening()` and the main actor calls `close`/`open`.

- [ ] **Step 1: Write the failing tests**

`Packages/RedlineCore/Tests/RedlineCoreTests/MicGateTests.swift`:
```swift
import Testing
import Foundation
@testable import RedlineCore

@Suite struct MicGateTests {
    @Test func listensByDefault() {
        #expect(MicGate().isListening())
        #expect(MicGate.defaultTail == .milliseconds(300))
    }

    @Test func closedWhileSpeakingAndForTheTail() {
        let gate = MicGate(tail: .milliseconds(300))
        let t0 = ContinuousClock.now
        gate.close()
        #expect(!gate.isListening(at: t0))
        #expect(!gate.isListening(at: t0 + .seconds(60)))   // stays closed until open
        gate.open(at: t0)
        #expect(!gate.isListening(at: t0 + .milliseconds(299)))
        #expect(gate.isListening(at: t0 + .milliseconds(300)))
    }

    @Test func speakingAgainDuringTheTailClosesIt() {
        let gate = MicGate(tail: .milliseconds(300))
        let t0 = ContinuousClock.now
        gate.close()
        gate.open(at: t0)
        gate.close()
        #expect(!gate.isListening(at: t0 + .seconds(1)))
        gate.open(at: t0 + .seconds(1))
        #expect(!gate.isListening(at: t0 + .milliseconds(1200)))
        #expect(gate.isListening(at: t0 + .milliseconds(1300)))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter MicGateTests`
Expected: compile error `cannot find 'MicGate' in scope`.

- [ ] **Step 3: Write MicGate**

`Packages/RedlineCore/Sources/RedlineCore/Input/MicGate.swift`:
```swift
import Foundation
import os

/// Lets the microphone pipeline ignore Redline's own voice in Chatty mode (spec §10, "mic gate"). It is
/// closed while a line is spoken and for a short tail after, so the reviewer hears it but it is never transcribed.
///
/// Thread-safe: the audio thread reads it on every buffer, and the main actor opens and closes it.
public final class MicGate: Sendable {
    public static let defaultTail: Duration = .milliseconds(300)

    private struct State: Sendable {
        var closed = false
        var reopensAt: ContinuousClock.Instant?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let tail: Duration

    public init(tail: Duration = MicGate.defaultTail) {
        self.tail = tail
    }

    /// Speaking started: ignore the microphone until `open` plus the tail.
    public func close() {
        state.withLock {
            $0.closed = true
            $0.reopensAt = nil
        }
    }

    /// Speaking ended at `now`: listen again once the tail has passed.
    public func open(at now: ContinuousClock.Instant = .now) {
        let reopensAt = now + tail
        state.withLock {
            $0.closed = false
            $0.reopensAt = reopensAt
        }
    }

    /// Whether microphone input at `now` should be transcribed.
    public func isListening(at now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { s in
            guard !s.closed else { return false }
            guard let reopensAt = s.reopensAt else { return true }
            return now >= reopensAt
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter MicGateTests`
Expected: all 3 tests pass.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make test`
Expected: `Test run with 157 tests in 10 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Packages/RedlineCore/Sources/RedlineCore/Input/MicGate.swift Packages/RedlineCore/Tests/RedlineCoreTests/MicGateTests.swift
git commit -m "feat(core): mic gate with a 300 ms tail"
```

---

### Task 7: LiveAnnotator Chatty path

**Files:**
- Modify: `Packages/RedlineCore/Sources/RedlineCore/Live/LiveAnnotator.swift` (whole file replaced below)
- Test: `Packages/RedlineCore/Tests/RedlineCoreTests/LiveAnnotatorTests.swift`

**Interfaces:**
- Consumes:
  - `AnnotateRequest.make(…, chatty:answering:)` and `AnnotateRequest.parseAnswer` (Task 4)
  - `ChattyConversation` (Task 5)
  - `TimelineEvent.aiQuestion`/`.questionAnswered` (Task 1)
  - `SessionContext.mode`, `SessionContext.clock.now()`
- Produces, on `LiveAnnotator` (all main actor):
  - `init(llm:model:frame:timeout: Duration = .seconds(8), questionTimeout: Duration = .seconds(20))`
  - `var onSpeak: ((String) -> Void)?`: a line to read aloud (a remark, or the question text).
  - `var onQuestion: ((ChattyConversation.Question?) -> Void)?`: the question that just opened, or nil once it closes.
  - `var openQuestion: ChattyConversation.Question? { get }`
  - `func answerQuestion(_ option: String)`: logs `.questionAnswered(via: .click)`.
  - `func skipQuestion()`: logs `.questionAnswered(answer: "", via: .skipped)`.
- Behaviour:
  - Only when `context.mode == .chatty`. Live sessions behave exactly as in phase 2.
  - A sentence that starts after the open question was asked answers it (`via: .voice`). It is sent with `answering:`.
  - After `questionTimeout` an open question is skipped. `stop()` skips an open question too.
  - `aiAnnotation.say` holds the remark only when it was spoken.

- [ ] **Step 1: Write the failing tests**

In `Packages/RedlineCore/Tests/RedlineCoreTests/LiveAnnotatorTests.swift`, replace the private `Sink` class and `makeAnnotator` function with:
```swift
@MainActor private final class Sink {
    var events: [TimelineEvent] = []
    var marks: [[Annotation]] = []
    var statuses: [LiveStatus] = []
    var results: [(id: UUID, hadFrame: Bool, marks: Int)] = []
    var spoken: [String] = []
    /// Text of each question shown, nil when it closed.
    var questions: [String?] = []
}

/// `startedAgo` moves the session clock back, so test sentences at small times start "before" a question.
@MainActor private func makeAnnotator(_ llm: (any LLMClient)?, model: String = "claude-haiku-5-5",
                                      timeout: Duration = .seconds(8), mode: SessionMode = .live,
                                      questionTimeout: Duration = .seconds(20), startedAgo: Double = 0)
    async throws -> (LiveAnnotator, Sink) {
    let sink = Sink()
    let a = LiveAnnotator(llm: llm, model: model, frame: { liveTestFrame(t: $0) }, timeout: timeout,
                          questionTimeout: questionTimeout)
    a.onMarks = { sink.marks.append($0) }
    a.onStatus = { sink.statuses.append($0) }
    a.onResult = { id, frame, marks in sink.results.append((id, frame != nil, marks.count)) }
    a.onSpeak = { sink.spoken.append($0) }
    a.onQuestion = { sink.questions.append($0?.text) }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = try SessionFolder.create(root: root, slug: "live", date: Date())
    let ctx = SessionContext(folder: folder, clock: SessionClock(startedAt: Date().addingTimeInterval(-startedAgo)), mode: mode,
                             emit: { sink.events.append($0) })
    try await a.start(context: ctx)
    return (a, sink)
}
```

Append to the end of the same file:
```swift
private let askAnswer = #"{"marks":[{"shape":"rect","x":10,"y":10,"w":100,"h":50,"caption":"Save"}],"say":"","question":{"text":"Which button?","options":["Save","Cancel"]}}"#
private let remarkAnswer = #"{"marks":[{"shape":"rect","x":10,"y":10,"w":100,"h":50,"caption":"Save"}],"say":"Now on billing.","question":{"text":"","options":[]}}"#

/// "via:answer" for each questionAnswered event, in order.
private func answers(_ events: [TimelineEvent]) -> [String] {
    events.compactMap { if case let .questionAnswered(_, answer, via, _) = $0 { "\(via.rawValue):\(answer)" } else { nil } }
}

@MainActor @Suite struct ChattyAnnotatorTests {
    @Test func questionOpensIsSpokenAndLogged() async throws {
        let llm = GatedLLM(answer: askAnswer, autoRelease: true)
        let (a, sink) = try await makeAnnotator(llm, mode: .chatty, startedAgo: 1000)
        let id = UUID()
        a.observe(.sentence(id: id, text: "make this bigger", start: 1, end: 2))
        await waitUntil { sink.questions.count == 1 }
        #expect(sink.questions == ["Which button?"])
        #expect(sink.spoken == ["Which button?"])
        #expect(a.openQuestion?.options == ["Save", "Cancel"])
        #expect(sink.events.contains { if case let .aiQuestion(_, sid, _, _, _) = $0 { sid == id } else { false } })
        guard case let .aiAnnotation(_, _, say)? = sink.events.first else { Issue.record("no aiAnnotation"); return }
        #expect(say == nil)
        let system = await llm.requests.first?.system
        #expect(system?.contains("Chatty mode is on") == true)
    }

    @Test func clickAnswerClosesTheQuestion() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: askAnswer, autoRelease: true), mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.questions.count == 1 }
        a.answerQuestion("Save")
        #expect(a.openQuestion == nil)
        #expect(sink.questions == ["Which button?", nil])
        #expect(answers(sink.events) == ["click:Save"])
        a.answerQuestion("Cancel")   // nothing open: ignored
        #expect(answers(sink.events) == ["click:Save"])
    }

    @Test func nextSentenceAnswersByVoiceAndIsSentWithTheQuestion() async throws {
        let llm = GatedLLM(answer: askAnswer, autoRelease: true)
        let (a, sink) = try await makeAnnotator(llm, mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.questions.count == 1 }
        a.observe(.sentence(id: UUID(), text: "the save one", start: 2000, end: 2001))
        #expect(answers(sink.events) == ["voice:the save one"])
        #expect(sink.questions.prefix(2) == ["Which button?", nil])
        await waitUntil { await llm.count == 2 }
        let second = try #require(await llm.sentence(1))
        #expect(second.contains("You asked: Which button?"))
        #expect(second.contains("Reviewer just said: the save one"))
    }

    @Test func onlyOneQuestionAtATime() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: askAnswer, autoRelease: true), mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.marks.count == 1 }
        a.observe(sentence("and that one", at: 3))   // started before the question: not an answer
        await waitUntil { sink.marks.count == 2 }
        #expect(sink.questions == ["Which button?"])
        #expect(sink.spoken == ["Which button?"])
        #expect(sink.events.filter { if case .aiQuestion = $0 { true } else { false } }.count == 1)
        #expect(answers(sink.events).isEmpty)
    }

    @Test func remarksAreRateLimitedAndLoggedWhenSpoken() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: remarkAnswer, autoRelease: true), mode: .chatty)
        a.observe(sentence("this page", at: 0))
        await waitUntil { sink.marks.count == 1 }
        a.observe(sentence("and this", at: 2))
        await waitUntil { sink.marks.count == 2 }
        #expect(sink.spoken == ["Now on billing."])
        let says = sink.events.compactMap { e -> String? in
            if case let .aiAnnotation(_, _, say) = e { say ?? "-" } else { nil }
        }
        #expect(says == ["Now on billing.", "-"])
    }

    @Test func unansweredQuestionIsSkippedAfterTheTimeout() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: askAnswer, autoRelease: true), mode: .chatty,
                                                questionTimeout: .milliseconds(50), startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.questions.count == 2 }
        #expect(sink.questions == ["Which button?", nil])
        #expect(answers(sink.events) == ["skipped:"])
        #expect(a.openQuestion == nil)
    }

    @Test func stopSkipsAnOpenQuestion() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: askAnswer, autoRelease: true), mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.questions.count == 1 }
        await a.stop()
        #expect(a.openQuestion == nil)
        #expect(sink.questions == ["Which button?", nil])
        #expect(answers(sink.events) == ["skipped:"])
    }

    @Test func liveModeNeverSpeaksOrAsks() async throws {
        let llm = GatedLLM(answer: askAnswer, autoRelease: true)
        let (a, sink) = try await makeAnnotator(llm, mode: .live)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.marks.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(sink.spoken.isEmpty && sink.questions.isEmpty && a.openQuestion == nil)
        #expect(!sink.events.contains { if case .aiQuestion = $0 { true } else { false } })
        let system = await llm.requests.first?.system
        #expect(system == AnnotateRequest.systemPrompt)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter "LiveAnnotatorTests|ChattyAnnotatorTests"`
Expected: compile errors, including `extra argument 'questionTimeout' in call` and `value of type 'LiveAnnotator' has no member 'onSpeak'`.

- [ ] **Step 3: Replace LiveAnnotator.swift**

Replace the whole of `Packages/RedlineCore/Sources/RedlineCore/Live/LiveAnnotator.swift` with:
```swift
import CoreGraphics
import Foundation
import os

private let liveLog = Logger(subsystem: "com.dmschellaz.redline", category: "live")

/// Live mode: after each finished sentence, asks the live model what the user means and draws it.
///
/// - At most one request is in flight. A sentence that finishes meanwhile is queued; a newer one replaces it
///   (newest wins). When the in-flight request finishes its marks are still drawn, then the queued one is sent.
/// - A timeout or any error drops the result and sets status `.offline`. Live marks never block the session.
/// - Chatty mode (session mode `.chatty`) sends the same request with the Chatty prompt and schema. Then
///   `ChattyConversation` decides what to say aloud (`onSpeak`) and whether to open a question (`onQuestion`).
///   The open question closes on `answerQuestion`, `skipQuestion`, the reviewer's next sentence, `questionTimeout`
///   or `stop`, and each close is logged as `.questionAnswered`.
@MainActor
public final class LiveAnnotator: SessionService, TimelineObserving, TokenReporting {
    /// Called with each non-empty batch of AI marks (global points), on the main actor.
    public var onMarks: (([Annotation]) -> Void)?
    /// Called once for every sentence the annotator took: with the frame the model saw and its marks (empty
    /// when it marked nothing or failed), or with a nil frame when the sentence was skipped. Main actor.
    public var onResult: ((_ sentenceID: UUID, _ frame: LiveFrame?, _ marks: [Annotation]) -> Void)?
    /// Called whenever `status` changes.
    public var onStatus: ((LiveStatus) -> Void)?
    /// Chatty: a line to read aloud (a short remark, or an open question's text). Main actor.
    public var onSpeak: ((String) -> Void)?
    /// Chatty: the question that just opened, or nil once it is answered, skipped or timed out. Main actor.
    public var onQuestion: ((ChattyConversation.Question?) -> Void)?

    public private(set) var status: LiveStatus = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    public private(set) var tokensUsed = TokenUsage()
    public private(set) var modelUsed: String?
    /// Chatty: the question waiting for an answer, if any.
    public var openQuestion: ChattyConversation.Question? { conversation.open }

    /// Sentences kept as context for the next request.
    static let contextSentences = 3

    private struct Job {
        var sentenceID: UUID
        var text: String
        var start: Double
        var end: Double
        var recent: [String]
        var clicks: [(point: CGPoint, displayID: UInt32)]
        var url: String?
        /// Chatty: the question this sentence answers.
        var answering: String?
    }

    private struct TimedOut: Error {}

    private var llm: (any LLMClient)?
    private var model: String
    private let frame: @MainActor (_ t: Double) async -> LiveFrame?
    private let timeout: Duration
    private let questionTimeout: Duration

    private var context: SessionContext?
    private var recent: [String] = []
    private var clicks: [(point: CGPoint, displayID: UInt32)] = []
    private var url: String?
    private var inFlight: Task<Void, Never>?
    private var queued: Job?
    private var conversation = ChattyConversation()
    /// Skips the open question after `questionTimeout`.
    private var expiry: Task<Void, Never>?
    /// Bumped on start and stop so late results from an earlier session are ignored.
    private var generation = 0

    public init(llm: (any LLMClient)?, model: String,
                frame: @escaping @MainActor (_ t: Double) async -> LiveFrame?,
                timeout: Duration = .seconds(8), questionTimeout: Duration = .seconds(20)) {
        self.llm = llm
        self.model = model
        self.frame = frame
        self.timeout = timeout
        self.questionTimeout = questionTimeout
    }

    /// Changes the client and model for the next session (the API key or Settings may change between sessions).
    public func configure(llm: (any LLMClient)?, model: String) {
        self.llm = llm
        self.model = model
    }

    public func start(context: SessionContext) async throws {
        generation += 1
        resetSession()
        tokensUsed = TokenUsage()
        modelUsed = nil
        guard context.mode != .manual, llm != nil else { return }
        self.context = context
    }

    public func stop() async {
        generation += 1
        inFlight?.cancel()
        closeQuestion(answer: "", via: .skipped)   // a question still open ends with the session
        resetSession()
        status = .idle
    }

    /// Chatty: the reviewer clicked an option in the island.
    public func answerQuestion(_ option: String) {
        closeQuestion(answer: option, via: .click)
    }

    /// Chatty: the reviewer clicked Skip.
    public func skipQuestion() {
        closeQuestion(answer: "", via: .skipped)
    }

    public func observe(_ event: TimelineEvent) {
        guard let context else { return }
        switch event {
        case let .sentence(id, text, start, end):
            var answering: String?
            if context.mode == .chatty, let answered = conversation.voiceAnswer(text: text, start: start, at: end) {
                expiry?.cancel()
                expiry = nil
                context.emit(answered.event)
                onQuestion?(nil)
                answering = answered.question.text
            }
            let job = Job(sentenceID: id, text: text, start: start, end: end, recent: recent, clicks: clicks, url: url,
                          answering: answering)
            recent.append(text)
            if recent.count > Self.contextSentences { recent.removeFirst(recent.count - Self.contextSentences) }
            clicks = []
            if inFlight == nil {
                send(job)
            } else {
                if let skipped = queued { onResult?(skipped.sentenceID, nil, []) }   // newest wins
                queued = job
            }
        case let .click(point, displayID, _):
            clicks.append((point, displayID))
        case let .urlChanged(url, _, _):
            self.url = url
        default:
            break
        }
    }

    // MARK: - Private

    private func resetSession() {
        context = nil
        inFlight = nil
        queued = nil
        recent = []
        clicks = []
        url = nil
        conversation.reset()
        expiry?.cancel()
        expiry = nil
    }

    private func closeQuestion(answer: String, via: AnswerVia) {
        guard let context, let event = conversation.answer(answer, via: via, at: context.clock.now()) else { return }
        expiry?.cancel()
        expiry = nil
        context.emit(event)
        onQuestion?(nil)
    }

    private func scheduleExpiry(of id: UUID, gen: Int) {
        expiry?.cancel()
        let wait = questionTimeout
        expiry = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, gen == self.generation, let context = self.context,
                  let event = self.conversation.expire(id, at: context.clock.now()) else { return }
            self.expiry = nil
            context.emit(event)
            self.onQuestion?(nil)
        }
    }

    private func send(_ job: Job) {
        let gen = generation
        inFlight = Task { [weak self] in
            await self?.run(job, gen: gen)
            guard let self, gen == self.generation else { return }
            self.inFlight = nil
            if let next = self.queued {
                self.queued = nil
                self.send(next)
            }
        }
    }

    private func run(_ job: Job, gen: Int) async {
        guard let llm, let context else { return }
        var seenFrame: LiveFrame?
        var seenMarks: [Annotation] = []
        defer { if gen == generation { onResult?(job.sentenceID, seenFrame, seenMarks) } }
        let wanted = (job.start + job.end) / 2
        guard let frame = await frame(wanted), gen == generation else {
            liveLog.error("No frame for sentence [\(job.start, format: .fixed(precision: 1))–\(job.end, format: .fixed(precision: 1))]; skipped")
            return
        }
        saveFrame(frame, folder: context.folder)
        seenFrame = frame
        let began = ContinuousClock.now
        let chatty = context.mode == .chatty
        let clicks = job.clicks.filter { $0.displayID == frame.display.id }.map(\.point)
        let request = AnnotateRequest.make(model: model, frame: frame, sentence: job.text,
                                           recentSentences: job.recent, clicks: clicks, url: job.url,
                                           chatty: chatty, answering: job.answering)
        status = .working
        do {
            let response = try await Self.send(request, via: llm, timeout: timeout)
            guard gen == generation else { return }
            tokensUsed = tokensUsed + TokenUsage(input: response.usage?.input_tokens ?? 0,
                                                 output: response.usage?.output_tokens ?? 0)
            modelUsed = response.model ?? model
            guard let text = response.firstText() else { throw ClaudeError.noText }
            let answer = try AnnotateRequest.parseAnswer(text, frame: frame, createdAt: job.end)
            let marks = answer.marks
            let elapsed = ContinuousClock.now - began
            liveLog.info("Sentence [\(job.start, format: .fixed(precision: 1))–\(job.end, format: .fixed(precision: 1))] frame t=\(frame.t, format: .fixed(precision: 1)) display \(frame.display.id): \(marks.count) mark(s) in \(elapsed, privacy: .public)")
            if marks.isEmpty { liveLog.info("No marks; model said: \(String(text.prefix(400)), privacy: .public)") }
            status = .ok
            seenMarks = marks
            let outcome = chatty
                ? conversation.respond(say: answer.say, question: answer.question, sentenceID: job.sentenceID,
                                       at: context.clock.now())
                : ChattyConversation.Outcome()
            if !marks.isEmpty {
                context.emit(.aiAnnotation(sentenceID: job.sentenceID, annotations: marks, say: outcome.said))
                onMarks?(marks)
            }
            if let question = outcome.asked {
                context.emit(question.event)
                onQuestion?(question)
                scheduleExpiry(of: question.id, gen: gen)
            }
            if let line = outcome.speak { onSpeak?(line) }
        } catch {
            guard gen == generation else { return }
            liveLog.error("Live request failed: \(String(describing: error), privacy: .public)")
            status = .offline
        }
    }

    /// Keeps the frame the model saw (raw/live-<ms>.jpg), so a missing or misplaced mark can be checked later.
    private func saveFrame(_ frame: LiveFrame, folder: SessionFolder) {
        let url = folder.rawURL.appending(path: "live-\(Int(frame.t * 1000)).jpg")
        let data = frame.jpeg
        Task.detached(priority: .utility) { try? data.write(to: url) }
    }

    /// Races the request against `timeout`; whichever finishes first wins and the other is cancelled.
    private nonisolated static func send(_ request: MessagesRequest, via llm: any LLMClient,
                                         timeout: Duration) async throws -> MessagesResponse {
        try await withThrowingTaskGroup(of: MessagesResponse.self) { group in
            group.addTask { try await llm.send(request) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; cd Packages/RedlineCore && swift test --filter "LiveAnnotatorTests|ChattyAnnotatorTests|SessionControllerTests"`
Expected: all pass: the 10 existing `LiveAnnotatorTests`, the 8 new `ChattyAnnotatorTests`, and `SessionControllerLiveTests.liveAnnotatorEndToEnd`.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make test`
Expected: `Test run with 165 tests in 11 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Packages/RedlineCore/Sources/RedlineCore/Live/LiveAnnotator.swift Packages/RedlineCore/Tests/RedlineCoreTests/LiveAnnotatorTests.swift
git commit -m "feat(core): LiveAnnotator speaks and asks in Chatty mode"
```

---

### Task 8: Mic gate in SpeechService

**Files:**
- Modify: `App/Redline/Services/SpeechService.swift`
- Modify: `App/Redline/Debug/DebugMenu.swift`

**Interfaces:**
- Consumes: `MicGate` (Task 6).
- Produces: `SpeechService.gate: MicGate` (a `let`). `VoiceService` (Task 9) closes and opens it. While the gate isn't listening, `AudioPipe` feeds the analyzer zeroed audio of the same length, so sentence times stay in step. It also reports silence to the `SilenceDetector`.

- [ ] **Step 1: Gate the audio pipe**

In `App/Redline/Services/SpeechService.swift`, in `AudioPipe`:

Replace:
```swift
    /// Called on the audio thread with the analyzer-timeline time the speech stopped.
    let onUtteranceEnd: @Sendable (Double) -> Void

    init?(from inFormat: AVAudioFormat, to outFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
          onUtteranceEnd: @escaping @Sendable (Double) -> Void) {
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        self.converter = converter
        self.outFormat = outFormat
        self.continuation = continuation
        self.onUtteranceEnd = onUtteranceEnd
    }
```
with:
```swift
    /// Called on the audio thread with the analyzer-timeline time the speech stopped.
    let onUtteranceEnd: @Sendable (Double) -> Void
    /// Read on the audio thread: closed while Chatty speaks, plus a short tail.
    let gate: MicGate

    init?(from inFormat: AVAudioFormat, to outFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation,
          gate: MicGate, onUtteranceEnd: @escaping @Sendable (Double) -> Void) {
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
        self.converter = converter
        self.outFormat = outFormat
        self.continuation = continuation
        self.gate = gate
        self.onUtteranceEnd = onUtteranceEnd
    }

    /// Zeroes every sample but keeps the length, so the analyzer's timeline stays in step with the clock.
    private static func silence(_ buffer: AVAudioPCMBuffer) {
        for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
        }
    }
```

In `push(_:)`, replace:
```swift
        } else if out.frameLength > 0 {
            let start = fedSeconds
            continuation.yield(AnalyzerInput(buffer: out))
            fedSeconds += Double(out.frameLength) / outFormat.sampleRate
            if let channel = buffer.floatChannelData?[0] {
                let level = SilenceDetector.level(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
```
with:
```swift
        } else if out.frameLength > 0 {
            // While Chatty speaks, its voice is replaced by silence (not dropped) so it is never transcribed.
            let listening = gate.isListening()
            if !listening { Self.silence(out) }
            let start = fedSeconds
            continuation.yield(AnalyzerInput(buffer: out))
            fedSeconds += Double(out.frameLength) / outFormat.sampleRate
            if let channel = buffer.floatChannelData?[0] {
                let level = listening
                    ? SilenceDetector.level(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                    : -120
```
The rest of `push` stays as it is.

In `final class SpeechService`, add after `var onPartial: (@MainActor (String) -> Void)?`:
```swift
    /// Closed by VoiceService while Chatty speaks, so Redline's own voice isn't transcribed.
    let gate = MicGate()
```

In `start(context:)`, replace:
```swift
            guard let pipe = AudioPipe(from: inFormat, to: format, continuation: continuation, onUtteranceEnd: { end in
```
with:
```swift
            guard let pipe = AudioPipe(from: inFormat, to: format, continuation: continuation, gate: gate, onUtteranceEnd: { end in
```
The tap is still installed through the existing `nonisolated static func installTap`. Don't move the tap closure into `start` (Swift 6 pitfall 1).

- [ ] **Step 2: Add a debug check**

In `App/Redline/Debug/DebugMenu.swift`, add inside `Menu("Debug") { … }` after the "Transcribe 10 s" button:
```swift
            Button("Mic gate 10 s (deaf 3–7 s)") {
                Task {
                    let speech = SpeechService()
                    await DebugHarness.run([speech], seconds: 10, title: "Mic gate") { _ in
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            speech.gate.close()
                            try? await Task.sleep(for: .seconds(4))
                            speech.gate.open()
                        }
                    }
                }
            }
```

- [ ] **Step 3: Build and check by hand**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make app`
Expected: the build succeeds with no output from `-quiet`.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make run`. Then use Debug → "Mic gate 10 s (deaf 3–7 s)" and count slowly, one number a second, "one" to "ten".
Expected:
- The alert lists `said:` lines with roughly the numbers from 0–3 s and from 7–10 s.
- Nothing said between about 3 and 7.3 s appears.
- Timestamps still increase and match when you spoke (the later numbers aren't shifted earlier).
- The app doesn't crash. A crash here means a main-actor closure reached the audio thread.

- [ ] **Step 4: Commit**

```bash
git add App/Redline/Services/SpeechService.swift App/Redline/Debug/DebugMenu.swift
git commit -m "feat(app): mic gate silences input while Chatty speaks"
```

---

### Task 9: VoiceService

**Files:**
- Create: `App/Redline/Services/VoiceService.swift`
- Modify: `App/Redline/Services/SystemAudio.swift`
- Modify: `App/Redline/Debug/DebugHarness.swift`
- Modify: `App/Redline/Debug/DebugMenu.swift`

**Interfaces:**
- Consumes: `MicGate` (Task 6), `SpeechService.gate` (Task 8), `SessionService`, `SessionContext.mode`, `SystemAudio.muteOutput()`/`restoreOutput()`.
- Produces:
  ```swift
  @MainActor final class VoiceService: NSObject, SessionService {
      var onSpeakingChanged: (@MainActor (Bool) -> Void)?
      var voiceIdentifier: String?            // AVSpeechSynthesisVoice identifier; nil = system default
      private(set) var isSpeaking: Bool
      init(gate: MicGate)
      func speak(_ text: String)              // only while a Chatty session runs; queues after the current line
      func stopTalking()                      // "Stop talking": cuts the line and anything queued, re-mutes
      static func voices() -> [AVSpeechSynthesisVoice]
      static func preview(voiceIdentifier: String?)
  }
  ```
  - `SystemAudio.isMutedByRedline: Bool`
  - `DebugHarness.run(_:seconds:title:mode: SessionMode = .manual, extra:)`

- [ ] **Step 1: Report whether Redline's mute is in place**

In `App/Redline/Services/SystemAudio.swift`, add after `restoreOutput()`:
```swift
    /// True while a mute set by muteOutput() is in place (VoiceService lifts it only then).
    static var isMutedByRedline: Bool { UserDefaults.standard.dictionary(forKey: savedKey) != nil }
```

- [ ] **Step 2: Write VoiceService**

`App/Redline/Services/VoiceService.swift`:
```swift
import AVFoundation
import RedlineCore

/// Chatty's voice: speaks lines with AVSpeechSynthesizer and the built-in voice picked in Settings.
///
/// - While it speaks, the microphone gate is closed. It reopens 300 ms after the last line, so Redline's
///   voice is never transcribed.
/// - Sessions mute the Mac's output. If that mute is in place, it is lifted for the line and put back after.
/// - No barge-in: the island's "Stop talking" calls `stopTalking()`.
@MainActor
final class VoiceService: NSObject, SessionService {
    /// Called when speaking starts (true) and when the last queued line ends or is cut (false).
    var onSpeakingChanged: (@MainActor (Bool) -> Void)?
    /// AVSpeechSynthesisVoice identifier; nil uses the system default voice for the current language.
    var voiceIdentifier: String?
    private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private let gate: MicGate
    /// Utterances handed to the synthesizer that haven't finished or been cancelled yet.
    private var pending: Set<ObjectIdentifier> = []
    /// True when speaking lifted the session's mute, so it is put back afterwards.
    private var liftedMute = false
    private var active = false

    init(gate: MicGate) {
        self.gate = gate
        super.init()
        synthesizer.delegate = self
    }

    func start(context: SessionContext) async throws {
        active = context.mode == .chatty
    }

    func stop() async {
        active = false
        cutOff(remute: false)   // AppModel restores the Mac's audio right after the session stops
    }

    func speak(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !line.isEmpty else { return }
        if !isSpeaking {
            gate.close()
            liftedMute = SystemAudio.isMutedByRedline
            if liftedMute { SystemAudio.restoreOutput() }
            isSpeaking = true
            onSpeakingChanged?(true)
        }
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = Self.voice(voiceIdentifier)
        pending.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    /// "Stop talking": cuts the current line and anything queued.
    func stopTalking() {
        cutOff(remute: true)
    }

    /// Built-in voices for the current language, best quality first. Novelty and Personal Voices are left out.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    /// Settings' "Preview" button.
    static func preview(voiceIdentifier: String?) {
        previewSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "I marked the billing card. Is that the one?")
        utterance.voice = voice(voiceIdentifier)
        previewSynthesizer.speak(utterance)
    }

    private static let previewSynthesizer = AVSpeechSynthesizer()

    private static func voice(_ identifier: String?) -> AVSpeechSynthesisVoice? {
        identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? AVSpeechSynthesisVoice(language: nil)
    }

    fileprivate func ended(_ id: ObjectIdentifier) {
        guard pending.remove(id) != nil, pending.isEmpty else { return }
        finish(remute: true)
    }

    private func cutOff(remute: Bool) {
        pending = []
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish(remute: remute)
    }

    private func finish(remute: Bool) {
        guard isSpeaking else { return }
        if remute && liftedMute { SystemAudio.muteOutput() }
        liftedMute = false
        gate.open()
        isSpeaking = false
        onSpeakingChanged?(false)
    }
}

extension VoiceService: AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizer calls its delegate on its own queue. These stay nonisolated (a @MainActor method called
    // off the main thread traps in Swift 6) and hop to the main actor carrying only a Sendable id.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.ended(id) }
    }
}
```

> If the compiler names a voice trait differently, ⌘-click `AVSpeechSynthesisVoice.voiceTraits` in Xcode to check: `.isNoveltyVoice`, `.isPersonalVoice`. Keep the filter's intent (built-in, non-novelty voices) and adjust only the name.

- [ ] **Step 3: Let the debug harness run a Chatty context**

In `App/Redline/Debug/DebugHarness.swift`, replace:
```swift
    static func run(_ services: [any SessionService], seconds: Double, title: String,
                    extra: (@MainActor (SessionContext) async -> Void)? = nil) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "redline-debug")
        guard let folder = try? SessionFolder.create(root: root, slug: "debug", date: Date()) else { return }
        let log = EventLog()
        let context = SessionContext(folder: folder, clock: SessionClock(startedAt: Date()), emit: { log.events.append($0) })
```
with:
```swift
    static func run(_ services: [any SessionService], seconds: Double, title: String, mode: SessionMode = .manual,
                    extra: (@MainActor (SessionContext) async -> Void)? = nil) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "redline-debug")
        guard let folder = try? SessionFolder.create(root: root, slug: "debug", date: Date()) else { return }
        let log = EventLog()
        let context = SessionContext(folder: folder, clock: SessionClock(startedAt: Date()), mode: mode,
                                     emit: { log.events.append($0) })
```

- [ ] **Step 4: Add a debug check**

In `App/Redline/Debug/DebugMenu.swift`, add after the "Mic gate" button:
```swift
            Button("Chatty voice + mic gate 12 s") {
                Task {
                    let speech = SpeechService()
                    let voice = VoiceService(gate: speech.gate)
                    await DebugHarness.run([speech, voice], seconds: 12, title: "Chatty voice", mode: .chatty) { _ in
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            voice.speak("This line is spoken by Redline and should not be transcribed.")
                        }
                    }
                }
            }
```

- [ ] **Step 5: Build and check by hand**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make app`
Expected: the build succeeds.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make run`. Use the Mac's built-in speakers, not headphones. Then Debug → "Chatty voice + mic gate 12 s".
Steps and expected results:
- About 2 s in, you hear the test line in the default voice.
- Stay quiet while it speaks, then say "this is me talking".
- The alert shows `said: this is me talking` and **no** `said:` line with "spoken by Redline".
- Your Mac's volume is the same as before. The harness never muted it, so the voice didn't touch the mute.
- The app doesn't crash. A crash here means a delegate callback reached main-actor code off the main thread.

- [ ] **Step 6: Commit**

```bash
git add App/Redline/Services/VoiceService.swift App/Redline/Services/SystemAudio.swift App/Redline/Debug/DebugHarness.swift App/Redline/Debug/DebugMenu.swift
git commit -m "feat(app): Chatty voice with mic gate and mute lifting"
```

---

### Task 10: Settings: voice picker and Chatty selectable

**Files:**
- Modify: `App/Redline/Settings/AppSettings.swift`
- Modify: `App/Redline/Settings/SettingsView.swift`
- Modify: `App/Redline/MenuContent.swift`

**Interfaces:**
- Consumes: `VoiceService.voices()`, `VoiceService.preview(voiceIdentifier:)` (Task 9).
- Produces:
  - `AppSettings.availableModes == [.manual, .live, .chatty]`
  - `AppSettings.voiceIdentifier: String?`, stored under UserDefaults key `voiceIdentifier`; nil means the system default.
  - The menu's Mode picker lists Chatty.
  - The "needs a key" note covers Live and Chatty.

- [ ] **Step 1: Settings model**

In `App/Redline/Settings/AppSettings.swift`, replace:
```swift
    /// Modes the user can pick today. Chatty isn't built yet.
    static let availableModes: [SessionMode] = [.manual, .live]
```
with:
```swift
    /// Modes the user can pick.
    static let availableModes: [SessionMode] = [.manual, .live, .chatty]
```

Add after the `liveModel` property:
```swift
    /// Chatty's voice (an AVSpeechSynthesisVoice identifier); nil uses the system default.
    var voiceIdentifier: String? {
        didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") }
    }
```

In `init()`, add before `hasAPIKey = KeychainStore.load() != nil`:
```swift
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier")
```

- [ ] **Step 2: Settings window**

In `App/Redline/Settings/SettingsView.swift`, add `import AVFoundation` at the top, next to the other imports.

Add this section right after the `Section("Live mode") { … }` block:
```swift
            Section("Chatty mode") {
                Picker("Voice", selection: $settings.voiceIdentifier) {
                    Text("System default").tag(String?.none)
                    ForEach(VoiceService.voices(), id: \.identifier) { voice in
                        Text(Self.voiceLabel(voice)).tag(String?.some(voice.identifier))
                    }
                }
                Button("Preview") { VoiceService.preview(voiceIdentifier: settings.voiceIdentifier) }
                Text("Chatty is Live plus a voice. It speaks a short line only when it's unsure or you change topic, and may ask which thing you mean. It uses the live model above. More voices: System Settings → Accessibility → Spoken Content.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

Add after `priceLabel(_:)`:
```swift
    /// "Samantha · en-US (Enhanced)".
    private static func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let base = "\(voice.name) · \(voice.language)"
        switch voice.quality {
        case .premium: return base + " (Premium)"
        case .enhanced: return base + " (Enhanced)"
        default: return base
        }
    }
```

- [ ] **Step 3: Menu**

In `App/Redline/MenuContent.swift`, replace:
```swift
        Picker("Mode", selection: Bindable(model.settings).sessionMode) {
            ForEach(AppSettings.availableModes, id: \.self) { Text($0.title).tag($0) }
            Text("Chatty (coming soon)").tag(SessionMode.chatty).disabled(true).selectionDisabled()
        }
        .pickerStyle(.inline)
        .disabled(model.isRecording || model.isStarting || model.isFinalizing || model.isReviewing)
        if model.settings.sessionMode == .live && !model.settings.hasAPIKey {
            Text("Live needs a Claude API key. Add one in Settings.")
        }
```
with:
```swift
        Picker("Mode", selection: Bindable(model.settings).sessionMode) {
            ForEach(AppSettings.availableModes, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        .disabled(model.isRecording || model.isStarting || model.isFinalizing || model.isReviewing)
        if model.settings.sessionMode != .manual && !model.settings.hasAPIKey {
            Text("\(model.settings.sessionMode.title) needs a Claude API key. Add one in Settings.")
        }
```

- [ ] **Step 4: Build and check by hand**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make app`
Expected: the build succeeds.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make run`
Expected:
- The menu's Mode picker shows Manual, Live and Chatty, and Chatty can be selected.
- With no key, it shows "Chatty needs a Claude API key. Add one in Settings."
- Settings has a "Chatty mode" section. Its Voice picker lists System default plus your language's voices, best quality first.
- **Preview** speaks the sample line in the chosen voice.
- The choice survives a relaunch.

- [ ] **Step 5: Commit**

```bash
git add App/Redline/Settings/AppSettings.swift App/Redline/Settings/SettingsView.swift App/Redline/MenuContent.swift
git commit -m "feat(app): pick Chatty mode and its voice"
```

---

### Task 11: Wire Chatty into AppModel

**Files:**
- Modify: `App/Redline/AppModel.swift`

**Interfaces:**
- Consumes:
  - `VoiceService` (Task 9), `SpeechService.gate` (Task 8), `AppSettings.voiceIdentifier` (Task 10)
  - `LiveAnnotator.onSpeak`/`onQuestion`/`answerQuestion(_:)`/`skipQuestion()` (Task 7)
- Produces, on `AppModel` (used by the island in Task 12):
  - `private(set) var openQuestion: ChattyConversation.Question?`
  - `private(set) var isSpeaking: Bool`
  - `func answerQuestion(_ option: String)`, `func skipQuestion()`, `func stopTalking()`
- Behaviour:
  - Chatty refuses to start without an API key (as Live does).
  - The feed expects live results in Live and Chatty.
  - The voice is chosen from Settings at every start.

- [ ] **Step 1: Add the voice and the Chatty state**

In `App/Redline/AppModel.swift`, replace:
```swift
    /// Live annotation health, for the island's status dot. LiveAnnotator.onStatus feeds this.
    private(set) var liveStatus: LiveStatus = .idle
```
with:
```swift
    /// Live annotation health, for the island's status dot. LiveAnnotator.onStatus feeds this.
    private(set) var liveStatus: LiveStatus = .idle
    /// Chatty: the question shown in the island, if any. LiveAnnotator.onQuestion feeds this.
    private(set) var openQuestion: ChattyConversation.Question?
    /// Chatty: true while a line is being spoken (shows "Stop talking").
    private(set) var isSpeaking = false
```

Replace:
```swift
    @ObservationIgnored private var live: LiveAnnotator!
```
with:
```swift
    @ObservationIgnored private var live: LiveAnnotator!
    @ObservationIgnored private var voice: VoiceService!
```

In `init()`, replace:
```swift
        live = LiveAnnotator(llm: nil, model: settings.liveModel, frame: { [capture] t in await capture.liveFrame(near: t) })
        controller = SessionController(
            capture: capture,
            services: [overlay, context, speech, live, feed],   // stop order is reversed: live, then speech flushes
            outputRoot: { settings.outputRoot },
            reportBuilder: { Self.makeReportBuilder(settings) })
```
with:
```swift
        live = LiveAnnotator(llm: nil, model: settings.liveModel, frame: { [capture] t in await capture.liveFrame(near: t) })
        voice = VoiceService(gate: speech.gate)
        controller = SessionController(
            capture: capture,
            // Stop order is reversed: the voice goes quiet, live skips an open question, then speech flushes.
            services: [overlay, context, speech, live, voice, feed],
            outputRoot: { settings.outputRoot },
            reportBuilder: { Self.makeReportBuilder(settings) })
```

In `init()`, add after `live.onResult = { … }`:
```swift
        live.onSpeak = { [weak self] in self?.voice.speak($0) }
        live.onQuestion = { [weak self] in self?.openQuestion = $0 }
        voice.onSpeakingChanged = { [weak self] in self?.isSpeaking = $0 }
```

- [ ] **Step 2: Island actions**

Add after `func setLiveStatus(_ status: LiveStatus) { liveStatus = status }`:
```swift
    /// Chatty: the reviewer clicked an option in the island.
    func answerQuestion(_ option: String) { live.answerQuestion(option) }

    /// Chatty: the reviewer clicked Skip.
    func skipQuestion() { live.skipQuestion() }

    /// Chatty: "Stop talking" in the island.
    func stopTalking() { voice.stopTalking() }
```

- [ ] **Step 3: Start, stop and cancel**

In `startSession()`, replace:
```swift
        if mode == .live && settings.apiKey() == nil {
            Notifier.post(title: "Can't start Live mode",
                          body: "Live mode needs a Claude API key. Add one in Settings, or switch to Manual.", folder: nil)
            return
        }
        isStarting = true
        defer { isStarting = false }
        liveStatus = .idle
        feed.expectsLiveResults = mode == .live
```
with:
```swift
        if mode != .manual && settings.apiKey() == nil {
            Notifier.post(title: "Can't start \(mode.title) mode",
                          body: "\(mode.title) mode needs a Claude API key. Add one in Settings, or switch to Manual.", folder: nil)
            return
        }
        isStarting = true
        defer { isStarting = false }
        liveStatus = .idle
        openQuestion = nil
        feed.expectsLiveResults = mode != .manual
        voice.voiceIdentifier = settings.voiceIdentifier
```

In `stopSession()`, replace:
```swift
        await controller.stop()
        SystemAudio.restoreOutput()
        liveStatus = .idle
```
with:
```swift
        await controller.stop()
        SystemAudio.restoreOutput()
        liveStatus = .idle
        openQuestion = nil
```

In `cancel()`, replace:
```swift
        await controller.cancel()
        SystemAudio.restoreOutput()
        liveStatus = .idle
```
with:
```swift
        await controller.cancel()
        SystemAudio.restoreOutput()
        liveStatus = .idle
        openQuestion = nil
```

- [ ] **Step 4: Build and check by hand**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make app`
Expected: the build succeeds.

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make run`. In a second Terminal tab, run `log stream --predicate 'subsystem == "com.dmschellaz.redline"'`. Pick Mode → Chatty, open a web page with two similar buttons, and press ⌃⌥⇧F.
Expected:
- While you talk normally, it draws like Live and stays mostly silent.
- Say "make that button bigger" without pointing at either. The log shows a live request, and within a few seconds you hear a short question.
- Saying an answer ("the left one") makes a new live request whose mark moves to your answer.
- Other audio stays muted except while Chatty speaks.
- Press ⌃⌥⇧F to stop. Audio comes back.
- Without an API key, Chatty doesn't start and posts "Can't start Chatty mode".

The island's question bar comes in Task 12.

- [ ] **Step 5: Commit**

```bash
git add App/Redline/AppModel.swift
git commit -m "feat(app): wire Chatty voice and questions into the session"
```

---

### Task 12: Island question bar and "Stop talking"

**Files:**
- Modify: `App/Redline/UI/RecordingPill.swift`

**Interfaces:**
- Consumes: `AppModel.openQuestion`, `.isSpeaking`, `.answerQuestion(_:)`, `.skipQuestion()`, `.stopTalking()` (Task 11); `ChattyConversation.Question` (Task 5); `Palette.ai`.
- Produces:
  - While recording with an open question, the island grows by `Island.questionHeight` and shows `QuestionBar`: the question text, one button per option, and **Skip**.
  - While speaking, the header shows **Stop talking**.
  - The status dot shows for Live and Chatty.

- [ ] **Step 1: Size the island for the question**

In `App/Redline/UI/RecordingPill.swift`, in `private enum Island`, add after `static let footerHeight: CGFloat = 44`:
```swift
    /// Chatty's question bar: the question on one line, its answer buttons under it.
    static let questionHeight: CGFloat = 58
```

In `IslandView`, add below `visibleRows`:
```swift
    /// Chatty's open question, shown only while recording.
    private var question: ChattyConversation.Question? {
        model.isRecording ? model.openQuestion : nil
    }
```

In `IslandView.contentHeight`, replace:
```swift
        if model.isReviewing { h += Island.footerHeight }
        return h
```
with:
```swift
        if model.isReviewing { h += Island.footerHeight }
        if question != nil { h += Island.questionHeight }
        return h
```

In `IslandView.body`, replace:
```swift
            IslandContent(model: model, close: close)
                .frame(height: headerHeight)
            if visibleRows > 0 || model.isReviewing {
```
with:
```swift
            IslandContent(model: model, close: close)
                .frame(height: headerHeight)
            if let question {
                QuestionBar(question: question, model: model)
            }
            if visibleRows > 0 || model.isReviewing {
```

Add `.animation(.snappy, value: model.openQuestion)` after `.animation(.snappy, value: model.controller.state)` in the same body.

- [ ] **Step 2: Status line, badge and Stop talking**

In `IslandContent`, in the `.recording` case, replace:
```swift
                        if mode == .live { LiveStatusBadge(status: model.liveStatus) }
```
with:
```swift
                        if mode != .manual { LiveStatusBadge(status: model.liveStatus) }
```

Replace:
```swift
                        if !model.partialTranscript.isEmpty {
                            Text(model.partialTranscript).foregroundStyle(.secondary)
                        } else if model.feed.isWaiting {
```
with:
```swift
                        if !model.partialTranscript.isEmpty {
                            Text(model.partialTranscript).foregroundStyle(.secondary)
                        } else if model.isSpeaking {
                            Text("Speaking…").foregroundStyle(Color(cgColor: Palette.ai))
                        } else if model.openQuestion != nil {
                            Text("Click an answer below, or say it.").foregroundStyle(Color(cgColor: Palette.ai))
                        } else if model.feed.isWaiting {
```

Replace:
```swift
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(confirmCancel ? "Discard?" : "Cancel") {
```
with:
```swift
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.isSpeaking {
                    Button("Stop talking") { model.stopTalking() }
                        .buttonStyle(IslandButtonStyle())
                }
                Button(confirmCancel ? "Discard?" : "Cancel") {
```

- [ ] **Step 3: The question bar**

Add after the `PulsingDot` struct:
```swift
/// Chatty's open question: the question, a button per answer option, and Skip. Saying the answer works too;
/// the question closes by itself after 20 s.
private struct QuestionBar: View {
    let question: ChattyConversation.Question
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color(cgColor: Palette.ai))
                Text(question.text).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            HStack(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    Button(option) { model.answerQuestion(option) }
                        .buttonStyle(IslandButtonStyle(prominent: true))
                }
                Button("Skip") { model.skipQuestion() }
                    .buttonStyle(IslandButtonStyle())
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: Island.questionHeight, maxHeight: Island.questionHeight, alignment: .leading)
        .help("Click an answer or say it")
    }
}
```

- [ ] **Step 4: Build**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make app`
Expected: the build succeeds.

- [ ] **Step 5: End-to-end manual test**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; make test && make run`
Expected: `Test run with 165 tests in 11 suites passed`, then the app launches.

Setup: Settings has an API key, Mode → **Chatty**, and a voice is picked. Play some music in another app. Open a page with two look-alike elements, e.g. two cards or two "Save" buttons. Use the Mac's speakers.

| # | Do | Expected |
|---|---|---|
| 1 | ⌃⌥⇧F | Pop sound. The music goes silent. The island shows "Recording · Chatty". |
| 2 | Say "this card's title is too small" while pointing at one card | A blue mark with a caption appears. Usually no voice. |
| 3 | Say "make that bigger" without pointing | Within a few seconds, a question with 2–3 option buttons and **Skip** appears under the header. You hear the question (the music briefly comes back while it speaks, then goes silent again). **Stop talking** shows while it speaks. |
| 4 | Click an option | The question bar closes. The island goes back to its normal height. |
| 5 | Trigger another question (as in 3), then say the answer, e.g. "the left one" | The question closes when your sentence finishes, and a new blue mark lands on what you picked. The island's sentence list shows "the left one". It never shows the question's own words. |
| 6 | Trigger another question and do nothing | After about 20 s it closes by itself. |
| 7 | While it speaks, click **Stop talking** | The voice stops at once. The music goes silent again. |
| 8 | Talk about a different page for a while | At most one spoken line every 10 s. Most sentences get only a mark. |
| 9 | ⌃⌥⇧F, then **Copy to Clipboard** in review | The music comes back. `feedback.md` has `- **Clarified:** <question> → <answer>` under the items from steps 4 and 5, and none for step 6. The transcript shows "(AI asked …)", "(picked …)" and "(question skipped)". |
| 10 | Open `session.json` in the session folder | It has `aiQuestion` and `questionAnswered` events with `"via" : "click"`, `"voice"` and `"skipped"`. |
| 11 | Menu → **Regenerate Last Report** on a Live session folder from before this phase | It still works, because old `session.json` files decode. |
| 12 | Mode → **Live**, run a short session | No voice and no questions. Behaves as before. |

- [ ] **Step 6: Commit**

```bash
git add App/Redline/UI/RecordingPill.swift
git commit -m "feat(app): island shows Chatty questions and Stop talking"
```

---

### Task 13: Docs: Try Chatty mode

**Files:**
- Modify: `docs/TRY-IT.md`

**Interfaces:**
- Consumes: the behaviour from Tasks 8–12 (menu, Settings and island labels exactly as written there).

- [ ] **Step 1: Add the section**

In `docs/TRY-IT.md`, insert after the "## 4b. Try Live mode" section (after its step 4) and before "## 5. Look at the result":
```markdown
## 4c. Try Chatty mode

Chatty is Live mode with a voice. It still draws blue marks, and it talks only when that helps.

1. In the menu bar menu, set **Mode** to **Chatty**. Like Live, it needs an API key and uses the live model from Settings → Live mode.
2. Pick a voice in **Settings → Chatty mode → Voice** and press **Preview**. Only voices that come with macOS are listed. Add nicer ones (Enhanced or Premium) in System Settings → Accessibility → Spoken Content → System voice → Manage Voices.
3. Start a session and talk as in Live mode. Most of the time Chatty just draws. It says a short line (12 words at most) only when it isn't sure of its mark or you've moved on to something new, and never more than once every 10 s.
4. When two things on screen could match what you said ("make that button bigger" with two buttons visible), it asks a question. You hear it, and the island shows it with 2–3 answer buttons and **Skip**. Answer in one of three ways:
   - Click an answer.
   - Just say it ("the left one"): your next sentence counts as the answer.
   - Ignore it: it closes by itself after 20 s.

   Only one question is open at a time.
5. Your other audio stays muted during the session. It comes back only while Chatty speaks, so you can hear it, and then mutes again. Redline doesn't listen while it speaks (plus a moment after), so its own voice never ends up in your transcript. You can't interrupt it by talking: click **Stop talking** on the island instead.
6. In the report, each item you clarified gets a line like `Clarified: Which button? → Save`. The write-up treats your answer as your own words.

If Chatty's voice shows up in your transcript, check the Debug menu's **Chatty voice + mic gate 12 s** test (debug builds).
```

In the same file, in "## Other menu items", replace the **Debug** bullet with:
```markdown
- **Debug** (debug builds only): quick tests of each piece (capture a screenshot, transcribe 10 s, the mic gate, Chatty's voice, log clicks and the URL, test the drawing overlay).
```

- [ ] **Step 2: Check the wording against the app**

Run: `grep -n "Chatty" docs/TRY-IT.md`
Expected: these labels match what Tasks 10–12 put in the app, word for word: the section, **Mode** → **Chatty**, **Settings → Chatty mode → Voice**, **Preview**, **Skip**, **Stop talking**, and **Chatty voice + mic gate 12 s**.

- [ ] **Step 3: Commit**

```bash
git add docs/TRY-IT.md
git commit -m "docs: how to try Chatty mode"
```

---

## Phase 3 acceptance

Phase 3 is done when:
- `make test` reports `Test run with 165 tests in 11 suites passed`.
- `make app` builds cleanly.
- Every row of the Task 12 end-to-end table passes on this Mac, including "Chatty voice isn't transcribed" from the spec's §7 manual checklist.
- A Live session behaves exactly as before (Task 12, row 12).
