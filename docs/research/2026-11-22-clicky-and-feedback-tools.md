# Research: Clicky and similar tools (2026-11-22)

Background research for the Redline design spec (`docs/superpowers/specs/2026-11-22-redline-feedback-app-design.md`). Product claims below are self-reported by each product and were not independently verified.

## Clicky / HeyClicky
- **What it is:** a voice + screen AI assistant for Mac and Windows by Humansongs, Inc. You press a hotkey, ask out loud or by typing, and it looks at your screen, answers, and points or draws.
- **Invocation:** lives in the notch / a floating island. Hotkeys: Fn+Control dictation, Control+Option screen drawing, double-Control text composer.
- **On-screen:** rings, highlights, arrows, lines; they stay attached to content when you scroll. "Drive" mode moves the mouse and types.
- **Voice:** realtime with barge-in, captions, many languages.
- **Providers (per privacy policy):** OpenAI, Anthropic, Google for AI; Cerebras, Groq, Deepgram for dictation.
- **Privacy:** sees the screen only on hotkey; screenshots not stored by Clicky.
- **Pricing:** Free with daily limits; Pro $16/mo yearly ($20 monthly); Max $80/mo yearly ($100 monthly).
- **Requirements:** macOS 14.2+ (Apple Silicon and Intel), Windows 10/11.

### Original open-source Clicky (farzaa/clicky, MIT)
Used as the main implementation reference.
- Swift/SwiftUI + AppKit, `LSUIElement`, MVVM. Key files: `CompanionManager.swift`, `MenuBarPanelManager.swift`, `OverlayWindow.swift`, `CompanionScreenCaptureUtility.swift`, `GlobalPushToTalkShortcutMonitor.swift`.
- Menu bar `NSStatusItem` + non-activating `NSPanel`; full-screen transparent `NSPanel` overlay joining all Spaces.
- Push-to-talk Ctrl+Option via a listen-only `CGEvent` tap, which is more reliable for modifier-only shortcuts than AppKit global monitors.
- ScreenCaptureKit multi-monitor capture.
- Pointing protocol: the LLM embeds `[POINT:x,y:label:screenN]` and the overlay animates a cursor along a bezier to it.
- AssemblyAI streaming STT, Claude for reasoning, ElevenLabs TTS. Keys are held in a Cloudflare Worker proxy.
- New development moved to the closed HeyClicky product (April 2026).

## Feedback-for-coding-agent tools (closest competitors)
| Tool | How it works | Output to agent |
|---|---|---|
| **Annotate** | Record a window or displays, draw (pen/rect/text), narrate; local, Apple Silicon only | Local MCP server (`get_timeline`, `get_frames_near`, `get_transcript_range`…) + copyable session prompt |
| **Remarc** | Point at text/screenshot/web element and talk; "Crit Mode" splits a spoken review into comment cards (macOS 26); Chrome extension adds DOM/CSS/React context | Copy as agent prompt, Markdown/JSON export, webhooks, MCP plugins |
| **Xannotate** | Record, draw/point, speak, hand off to Claude Code; local | Hand-off to Claude Code |
| **PinVari** | Screenshot + numbered marks + on-device voice transcription | Local files |
| **Jompter** | Voice + screenshots/recordings → Markdown prompts; local Whisper | Markdown |
| **MarkuprPlus** | Visual feedback app + CLI + MCP server | Claude Code via CLI/MCP |
| **Snap** (MIT, Tauri) | Marked-up screenshot overlay | MCP tool to fetch latest screenshot |

**Gap:** in every one of these the user does the drawing. None has an AI that watches live and marks up the screen to show what it understood. That gap is Redline's differentiator.

## Technical notes
- **Claude Code images:** a clipboard paste carries one image at a time. Claude Code can read image files by path, so a folder of Markdown + PNGs with a short path-based prompt is the most reliable hand-off.
- **Screen Recording permission:** it only registers when launched as a `.app` (e.g. via `open`), not by running the binary from Terminal. The preflight check function doesn't add the app to the permission list.
- **macOS 26:** `SpeechAnalyzer` + `SpeechTranscriber` give on-device streaming STT.

## Sources
- https://www.heyclicky.com/ , https://www.heyclicky.com/changelog , https://www.heyclicky.com/privacy-policy
- https://github.com/farzaa/clicky , https://github.com/farzaa/clicky-releases
- https://www.scriptbyai.com/annotate-screen-recording-ai-prompts/
- https://raw.githubusercontent.com/metedata/Remarc/main/README.md
- https://raw.githubusercontent.com/hashfunction/MarkuprPlus/HEAD/README.md
- https://github.com/adjective-rob/snap
- https://raw.githubusercontent.com/tryskilly/skilly/main/README.md
- https://developer.apple.com/forums/thread/819555
