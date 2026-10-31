# Syntly — Open-Source macOS Real-Time AI Writing Assistant (Powered by Google Gemini)

**Syntly** is a lightweight, native macOS writing assistant built in Swift and SwiftUI that checks and polishes your writing **as you type** across any macOS application—powered for **$0** using your Google Gemini account.

---

## ✨ Features

- **Real-Time Corrections While You Type**:
  - Monitors focused text fields across native macOS apps, browsers, and Electron/Chromium apps (Slack, VS Code, Notion, Discord).
  - Combines an **instant `<5ms` local spellcheck pass** (`NSSpellChecker`) with **debounced contextual Gemini checks** (defaulting to the flagship **`gemini-3.8-flash`**) and `SHA-256` paragraph caching.
- **Non-Intrusive Floating Corner Pill (`NSPanel`)**:
  - Anchors a subtle status pill near the bottom-right corner of the active text input without ever stealing keyboard focus.
  - Shows live status: **All Clear (`✓`)**, **Checking (`⋯`)**, **Color-Coded Issue Count Badge**, or **Paused (`⏸`)**.
- **Color-Coded Suggestion Categories**:
  - 🔴 **Correctness**: Spelling, grammar, punctuation, and tense errors.
  - 🔵 **Clarity & Conciseness**: Wordy phrases, passive voice, and hard-to-read sentences.
  - 🟣 **Tone & Delivery**: Politeness, confidence, and formality adjustments.
  - 🟢 **Fluency**: Natural phrasing and idiom improvements.
- **Keyboard-First & 1-Click Fixes**:
  - Press **`Option + Tab` (`⌥Tab`)** while typing to immediately accept the top correction in-place.
  - Press **`Cmd + Shift + G` (`⌘⇧G`)** (or click the floating pill) to expand the Suggestion & Rewrite card, review inline diffs (`~~original~~` → **`replacement`**), **Accept All**, or rewrite text in *Concise*, *Professional*, *Friendly*, or *Natural* tones.
- **Privacy & Context Guardrails**:
  - Automatically ignores secure password fields (`kAXSecureTextFieldSubrole`).
  - Includes a **Personal Dictionary**, **English Dialect selector** (US, UK, CA, AU), and **Per-App Blocklist**.

---

## 🔑 Free Google Gemini Account Setup ($0 Cost)

Because Syntly is 100% client-side and open-source, there is no backend server and zero developer API fee. Users can authenticate for free in two ways:

### Option 1: Local Gemini CLI (Uses Your Google Account / Gemini Pro Subscription)
1. Install the official Gemini CLI (`npm install -g @google/gemini-cli`) and run `gemini` in Terminal to sign in with your Google Account (*Login with Google*).
2. Syntly automatically detects `/usr/local/bin/gemini` (or `/opt/homebrew/bin/gemini`) and uses your included daily quota (**1,000 requests/day** on Free Google accounts, **1,500/day** on Google AI Pro, or **2,000/day** on Google AI Ultra) at **$0 extra cost**.

### Option 2: Google AI Studio API Key (Fast `<400ms` Direct REST)
1. Generate a free API key at [Google AI Studio](https://aistudio.google.com/apikey) (no credit card required for the Free Tier, or use the $10/month Google Cloud credit bundled with Google AI Pro).
2. Paste the key into **Syntly Settings → Gemini Account** (stored securely in your local **macOS Keychain**).

---

## 🚀 Build & Run

### Requirements
- macOS 14.0+ (Sonoma / Sequoia / Tahoe)
- Swift 5.9+ / Xcode Command Line Tools

### Run Directly or Run Tests
```bash
# Run unit tests
swift test

# Build and launch from CLI
swift run Syntly
```

### Package as a Native `Syntly.app` Bundle
```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open Syntly.app
```

When prompted, grant **Accessibility Permission** in **System Settings → Privacy & Security → Accessibility** so Syntly can detect active text fields and apply corrections across apps.

---

## 📄 License

MIT License — see [LICENSE](LICENSE).
