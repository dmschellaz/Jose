# Trying Redline on your Mac

This takes about 10 minutes the first time. You need: Xcode (signed in with your Apple ID), XcodeGen (`brew install xcodegen`), and a Claude API key from console.anthropic.com (optional: without one you still get screenshots and a transcript, just no AI write-up).

## 1. Build and launch

```bash
cd ~/Developer/Jose
make run
```

A pencil icon appears in the menu bar (there is no Dock icon). `make run` always rebuilds and relaunches. Launch it this way or with `open`, not by running the binary from Terminal, or macOS gives the permissions to Terminal instead of Redline.

To open the project in Xcode instead: run `make project`, then `open Redline.xcodeproj` and press ⌘R.

## 2. Grant permissions (first launch only)

A **Redline Setup** window opens. Click **Grant** on each row:

| Permission | What happens |
|---|---|
| Microphone | System prompt → Allow |
| Speech Recognition | System prompt → Allow |
| Screen Recording | System Settings opens → turn Redline on |
| Input Monitoring | System Settings opens → turn Redline on |

macOS may ask you to quit and reopen Redline after Screen Recording or Input Monitoring. Do that (`make run` again), then click **Re-check**. All four should be green. You can reopen this window any time from the menu: **Permissions…**

The first time Redline reads a browser tab, macOS also asks to let Redline control Chrome/Safari/Arc. Allow it, so feedback can say which page it's about.

## 3. Add your API key

Create the key inside a workspace: in console.anthropic.com go to **Settings → Workspaces**, pick (or create) one such as "Redline", and create the key there. A key that isn't scoped to a workspace is rejected with "must include the anthropic-workspace-id header".

Menu bar icon → **Settings…** → paste your key → **Save Key** (pasting a new key replaces the old one). The key is stored in your Keychain only. Leave the report model on `claude-sonnet-5-5` (or pick `claude-opus-5-5`).

## 4. Record a feedback session

1. Open the web app you're working on (e.g. `http://localhost:3000`) in Chrome, Safari or Arc.
2. Press **⌃⌥⇧F** (Control-Option-Shift-F). You hear a pop, other audio on the Mac is muted until you stop, and a black island drops from the top of the screen showing the timer and your words as you speak.
3. Walk through the app and talk: "the header logo is too small".
4. **Hold ⌥ (Option) on its own** for a moment: the screen tints and the cursor becomes a crosshair. Drag to circle the thing you mean, then let go. The red mark fades after a few seconds but is kept for the report.
5. Click to another page and keep going. Press **⌃⌥⇧M** to split feedback into a new item if you want.
6. Press **⌃⌥⇧F** again (or **Stop** on the island). Audio comes back on and the island shows "Writing report…".

The island then shows **Feedback ready**, what's on your clipboard, and a line like `Sonnet 5.5 · 12.3k in · 1.4k out · $0.039`: the model that wrote the report, the tokens it used and the estimated API cost (standard API prices). Close it with **×**.

To throw a session away: **Cancel** on the island (click twice) or **Cancel Session** in the menu.

## 5. Look at the result

Click the notification, or menu → **Recent Sessions**. Each session is a folder in `~/Feedback/`, for example `~/Feedback/localhost-3000-2026-11-22-1430/`:

- `feedback.md` is the numbered list of changes, with screenshots
- `01-….png`, `02-….png` are screenshots with your marks drawn on
- `raw/` holds the clean screenshots
- `session.json` is the full timeline

Open `feedback.md` in any Markdown viewer (VS Code: ⇧⌘V; Finder: select it and press Space).

## 6. Hand it to Claude Code

In Claude Code, inside the repo of the app you reviewed, paste (⌘V). The prompt looks like:

```
Read ~/Feedback/localhost-3000-2026-11-22-1430/feedback.md and the screenshots it links, then make each revision in this project. Ask me if an item is ambiguous.
```

Claude Code reads the Markdown and opens the screenshots itself.

**Claude Code on another computer?** It can't open files on this Mac, so set **Settings → Hand-off → Claude Code runs on: Another computer**. Chat apps drop pasted text when images come along, so the hand-off is **paste twice**:

1. In the Claude chat, press ⌘V: the write-up text goes in. Redline notices and swaps the screenshots onto the clipboard (you hear a tink).
2. Press ⌘V again: the screenshots attach, in order. Send.

The island shows which paste is next and closes itself after the second. The write-up refers to the images as "attached image 1", "attached image 2", and so on. **Copy Again** on the island, or menu bar icon → **Copy Last Write-up (Paste Twice)**, starts over; **Copy Last Screenshots Only** copies just the images. If you copy something else in between, Redline stops and leaves your clipboard alone.

## Other menu items

- **Regenerate Last Report**: rebuilds the write-up for the last session (e.g. after adding an API key or switching models).
- **Debug** (debug builds only): quick tests of each piece (capture a screenshot, transcribe 10 s, log clicks and the URL, test the drawing overlay).

## If something doesn't work

- **No pencil icon:** check the app is running with `pgrep -x Redline`. Your menu bar may be full; hide other icons or use a menu bar manager.
- **"Couldn't start recording":** a permission is missing. Menu → **Permissions…**
- **Report says "Saved without an AI write-up":** the notification gives the reason (no key, key rejected, rate limit, network). If the log mentions `anthropic-workspace-id`, your key isn't scoped to a workspace: make a new one inside a workspace (step 3). For details, run `log stream --predicate 'subsystem == "com.dmschellaz.redline"'` while you choose Regenerate.
- **Permissions keep being asked for again:** you're running an unsigned build. Make sure `.team` exists in the repo folder (it holds your Team ID) and `make run` again.
