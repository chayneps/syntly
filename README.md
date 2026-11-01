# Syntly — Open-Source macOS Real-Time AI Writing Assistant (Universal OpenAI API & Local Proxy Support)

**Syntly** is a lightweight, native macOS writing assistant built in Swift and SwiftUI that checks and polishes your writing **as you type** across any macOS application—powered by any **OpenAI-compatible API**, including **CLI Proxy API**, **LM Studio**, **Ollama**, **Kiro Gateway**, **OpenAI**, **OpenRouter**, or **Google AI Studio**.

---

## ✨ Features

- **Real-Time Corrections While You Type**:
  - Monitors focused text fields across native macOS apps, browsers, and Electron/Chromium apps (Slack, VS Code, Notion, Discord).
  - Combines an **instant `<5ms` local spellcheck pass** (`NSSpellChecker`) with **debounced contextual AI checks** and `SHA-256` paragraph caching.
- **Universal OpenAI-Compatible API Support**:
  - Connect to **CLI Proxy API** (`http://127.0.0.1:8317/v1`) using your Google/Anthropic/OpenAI accounts.
  - Connect to **LM Studio** (`http://localhost:1234/v1`) or **Ollama** (`http://localhost:11434/v1`) with zero API fees and 100% local privacy.
  - Connect to **Kiro Gateway**, **OpenAI**, **OpenRouter**, or **Google AI Studio** with your own API token.
  - Built-in **1-Click Test Connection** button and **Fetch Available Models** discovery.
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

## 🔑 AI Provider & Setup

Configure your provider in **Syntly Settings → API & Model**:

1. **CLI Proxy API (Recommended if running locally)**:
   - Endpoint: `http://127.0.0.1:8317/v1`
   - Token: Your API key configured in `~/.cli-proxy-api/config.yaml` (Syntly auto-detects local keys).
   - Model: `gemini-3.8-flash-high`, `gemini-3-flash`, `gpt-4o-mini`, etc.
2. **Local LM Studio / Ollama (100% Free & Offline)**:
   - LM Studio: `http://localhost:1234/v1` (Token optional)
   - Ollama: `http://localhost:11434/v1` (Token optional)
3. **Kiro Gateway / Cloud Endpoints**:
   - Endpoint: `https://api.kirogateway.com/v1` or `https://api.openai.com/v1`
   - Token: Stored securely in your macOS Keychain.
4. **Test Connection**:
   - Click **Test Connection Now** to measure round-trip latency and confirm model availability.
   - Click **Fetch Available Models** to automatically populate the model dropdown from the server.

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
*Packages high-resolution Apple ICNS squircle app icon (`assets/AppIcon.icns`), configures `Info.plist`, and codesigns the bundle.*

### Build Distribution DMG Installer (Universal 2: Apple Silicon + Intel)
```bash
chmod +x scripts/build-dmg.sh
./scripts/build-dmg.sh
```
*Creates `Syntly-0.1.0-Universal.dmg` containing a native Universal 2 binary (`arm64` + `x86_64`) and an `/Applications` drag-and-drop installer link.*

When prompted, grant **Accessibility Permission** in **System Settings → Privacy & Security → Accessibility** so Syntly can detect active text fields and apply corrections across apps.

---

## 📄 License

MIT License — see [LICENSE](LICENSE).
