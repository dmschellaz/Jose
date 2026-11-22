# Install Redline on a Mac

Use this to install Redline on a Mac where you don't want to build it from source. It needs macOS 26 or later and runs on both Apple silicon and Intel Macs.

## 1. Download and copy
1. Open the [Releases page](https://github.com/dmschellaz/Jose/releases) and download `Redline-<version>.dmg` from the latest release.
2. Open the DMG and drag **Redline** onto **Applications**.

## 2. Let macOS open it (first launch only)
Redline isn't notarized by Apple (that needs a paid developer account), so macOS blocks the first launch:

1. Open **Redline** from Applications. macOS says it can't verify the app; click **Done**.
2. Open **System Settings → Privacy & Security**, scroll down to the line about Redline, and click **Open Anyway**. Confirm with your password or Touch ID.

Or, in Terminal, remove the download flag, then open Redline normally:

```bash
xattr -dr com.apple.quarantine /Applications/Redline.app
```

## 3. Set it up
Redline lives in the menu bar (a pencil-and-squiggle icon). On first launch:

1. **Permissions:** the setup window lists Screen Recording, Microphone, Speech Recognition and Input Monitoring. Grant each one; for Screen Recording and Input Monitoring, quit and reopen Redline afterwards.
2. **API key:** menu bar icon → **Settings…** → paste a Claude API key that was created inside a workspace (console.anthropic.com → Settings → Workspaces) → **Save Key**.
3. **Hand-off:** in Settings, pick where Claude Code runs. **This Mac** copies a short prompt that points to the session folder. **Another computer** sets up the "paste twice" hand-off.
4. **Notifications (optional):** System Settings → Notifications → Redline → Allow.

The first time Redline reads a browser tab, macOS asks to let it control Chrome, Safari or Arc. Allow it, so feedback can say which page it's about.

Then press **⌃⌥⇧F** to start or stop a session. See [TRY-IT.md](TRY-IT.md) for the full walkthrough.

## Updating
Download the new DMG, quit Redline, and replace the app in Applications. Each build is signed separately, so macOS may ask for Screen Recording, Input Monitoring and other permissions again. If a permission looks granted but doesn't work, remove Redline from that list in Privacy & Security and add it back.

## Making a release (maintainers)
```bash
make release
```
This builds `dist/Redline-<version>.dmg`: a universal, ad-hoc signed app. The version comes from `CFBundleShortVersionString` in `project.yml`. Attach the DMG to a GitHub release.
