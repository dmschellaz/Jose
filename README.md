# Redline (working name)

A macOS menu bar app for capturing app feedback for Claude Code. Press a hotkey, walk through the web app you're building while you talk, and Redline listens, watches, optionally draws on screen to show what it understood, and produces a feedback report (Markdown + annotated screenshots) with a ready-to-paste prompt for Claude Code.

Three modes trade token use against interactivity:
- **Manual:** you narrate and draw; the AI runs once at the end.
- **Live:** the AI draws on screen as you talk.
- **Chatty:** the AI draws and talks back.

## Status
Phase 1 (Manual mode) — see the [phase 1 plan](docs/superpowers/plans/2026-11-22-redline-phase1-manual-mode.md).

## Install
Download the DMG from [Releases](https://github.com/dmschellaz/Jose/releases) and follow [docs/INSTALL.md](docs/INSTALL.md). It's not notarized, so the first launch needs **Open Anyway** in Privacy & Security.

## Build and run
Requires macOS 26+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

1. Put your Apple Developer Team ID in `.team` (gitignored): `echo YOURTEAMID > .team`
2. `make test` runs the core test suite.
3. `make run` builds and launches the menu bar app. Always launch through `make run` or `open`, so macOS attributes permissions to Redline.
4. On first launch, grant the permissions in the setup window and add your Claude API key in Settings.

Press ⌃⌥⇧F to start or stop a session, ⌃⌥⇧M to mark a moment, and hold ⌥ to draw.

## Docs
- [Install from a release](docs/INSTALL.md)
- [Try it locally](docs/TRY-IT.md)
- [Design spec](docs/superpowers/specs/2026-11-22-redline-feedback-app-design.md)
- [Research: Clicky and similar tools](docs/research/2026-11-22-clicky-and-feedback-tools.md)
