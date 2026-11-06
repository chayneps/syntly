# Synt(ax)ly — Native macOS Real-Time AI Writing Assistant

<p align="center">
  <img src="assets/app_icon_1024.png" width="128" height="128" alt="Syntly App Icon" style="border-radius: 28px;" />
</p>

<p align="center">
  <b>Lightweight, privacy-conscious native macOS writing assistant and interactive Writing Pad.</b><br/>
  Real-time inline proofreading across every app & custom persona rewrites powered by local or cloud AI models.
</p>

<p align="center">
  <a href="https://github.com/chayneps/syntly/releases"><img src="https://img.shields.io/badge/macOS-14.0%2B-blue?style=flat-square&logo=apple" alt="macOS 14+" /></a>
  <a href="https://github.com/chayneps/syntly/releases"><img src="https://img.shields.io/badge/Architecture-Universal%202%20(Apple%20Silicon%20%2B%20Intel)-orange?style=flat-square" alt="Universal 2" /></a>
  <img src="https://img.shields.io/badge/Swift-5.9%2B-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 5.9+" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License: MIT" /></a>
  <a href="https://github.com/chayneps/syntly/actions"><img src="https://img.shields.io/badge/Build-Passing-brightgreen?style=flat-square" alt="Build Status" /></a>
</p>

---

## ⚡ Quick Download & Installation

Download the ready-to-run DMG installer for version **v2 (2.0.0)** directly from GitHub Releases:

👉 **[Download Syntly v2 DMG (Universal 2)](https://github.com/chayneps/syntly/releases/latest)**

*Supports both Apple Silicon (M1/M2/M3/M4) and Intel Macs natively.*

---

### 📥 Installation Steps

1. Download and open **`Syntly-2.0.0-Universal.dmg`**.
2. Drag **Syntly.app** into the **Applications** folder shortcut.

---

### 🔓 Overcoming the "Unknown Developer" / Gatekeeper Warning

Because Synt(ax)ly is a free, independent open-source tool distributed outside the Mac App Store (without a paid $99/yr Apple Developer certificate), macOS Gatekeeper blocks it on the first launch with:

> ⚠️ **"Syntly.app" Not Opened**  
> *Apple could not verify "Syntly.app" is free of malware that may harm your Mac or compromise your privacy.*

This happens because macOS is configured to allow only *"App Store & Known Developers"*. On modern macOS (Sonoma & Sequoia), clicking *"Open Anyway"* in System Settings often loops or fails to launch the app.

Use either method below to open Syntly in seconds:

#### Method 1: Instant Terminal Command (Recommended)
Open **Terminal** and run:
```bash
xattr -cr /Applications/Syntly.app
```
> **Why this works**: Web browsers (Safari, Chrome) automatically attach a hidden `com.apple.quarantine` attribute to files downloaded from the internet. This command removes that tag, allowing macOS to treat Syntly as a trusted local application and launch immediately on double-click.

#### Method 2: Unlock the "Anywhere" Option in System Settings
To allow all open-source apps on your Mac without blocking:
1. Open **Terminal** and run:
   ```bash
   sudo spctl --master-disable
   ```
2. Re-open **System Settings → Privacy & Security**.
3. Under the **Security** section, the dropdown will now display **"Anywhere"**. Select it, and Syntly will launch without any Gatekeeper prompt.  
*(To restore default settings later, run `sudo spctl --master-enable`).*

---

### 🛡️ Step 3: Grant Accessibility Permission (One-Click Setup)
Synt(ax)ly needs macOS Accessibility permission to detect active text fields and display the real-time Manga Thinking Bubble beside your cursor:
1. Launch **Syntly.app**. It will appear quietly in your macOS menu bar at the top-right of your screen.
2. Click the **Synt(ax)ly menu bar icon** and click the yellow warning:
   > **`⚠️ Grant Accessibility Access…`**
3. This opens **System Settings → Privacy & Security → Accessibility** automatically.
4. Toggle **ON** the switch next to **Synt(ax)ly** (or click `+` and choose `/Applications/Syntly.app`).

---

### ⚙️ Step 4: Configure Your AI Model (CLIProxyAPI & Gateways)
Open **Settings (`⌘,`) → API & Model** from the menu bar icon:

- **[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (Recommended — Zero-API-Key)**:
  - If you run `cli-proxy-api` locally (`http://127.0.0.1:8317/v1`), click the **"CLI Proxy API"** preset button.
  - Syntly **automatically detects** your existing Google, Gemini, or Claude authentication tokens from `~/.cli-proxy-api/config.yaml`—no manual copying required!
- **[Kiro Gateway](https://github.com/jwadow/kiro-gateway)**: Select the Kiro Gateway preset to route requests via your active Kiro subscription with Claude and frontier models.
- **[Ollama](https://ollama.com) / [LM Studio](https://lmstudio.ai)**: 100% free and offline local inference using open weights (`llama3.2`, `qwen`).
- **Google AI Studio (Gemini) / OpenAI / OpenRouter**: Enter your API key and click **Test Connection** to benchmark real-world latency.

---

## ✨ Core Features

### 1. Dedicated Writing Pad Workspace (`⌘N`)

![Syntly Writing Pad Workspace](assets/screenshot_writing_pad.png)
*Dedicated, distraction-free drafting pad with custom persona instructions, multi-select rewrite levers, and live diff preview.*

- **Document Canvas**: A dedicated, distraction-free drafting pad for emails, reports, technical writing, and essays.
- **Custom Persona & Style Instructions**: A multiline instruction box to define *who* is writing and what domain guidelines to follow (e.g. *"Act as an executive CTO"*, *"Use active voice"*, *"Client email format"*). Save reusable style presets with one click.
- **Multi-Select Functional Levers**: Toggle any combination of structural modifiers without clashing with your persona:
  - `✓ Make Concise` — Cuts fluff and redundancies by ~30–40% without losing facts.
  - `✓ Bullet Points` — Restructures blocks of text into scannable bullets.
  - `✓ Be Direct` — Removes timid hedging (*"I think"*, *"maybe"*, *"just wanted to check"*) with confident, active voice.
  - `✓ Sound Natural` — Fixes awkward translations and ensures smooth native English idioms.
  - `✓ Fix Only` — Strictly corrects typos, spelling, and grammar without altering your original voice or wording.
- **Twin Action Bar**:
  - `[ Re-check ]` (`⌘R`): Instant re-scan of the document.
  - `[ Rewrite ]` (`⌘↵`): Executes the rewrite incorporating all active persona rules and selected modifiers.
- **Preview & Revert**: Review rewrites before accepting, choose **Replace Original** or **Insert Below**, or click **Revert to Original (Undo)** at any time.

### 2. System-Wide Real-Time Proofreading (`⌥Tab`)

![Real-Time In-Context Proofreading & Manga Thinking Bubble](assets/screenshot_floating_pill.png)
*Real-time in-context proofreading while typing across any macOS application — the hot-pink Manga Thinking Bubble docks right beside your active cursor with live suggestions HUD and instant keyboard replacement (`⌥Tab`).*

- **Manga Thinking Bubble Floating Pill**: The iconic hot-pink thinking bubble floats right beside your active cursor across Slack, Notes, Mail, VS Code, Discord, and browsers. Shows a green checkmark when your writing is all clear, and a red counter badge when improvements are detected.
- **Right-Click Context Menu & Per-App Controls**: Right-click (or `Control + Click`) the floating bubble or the suggestion dialog header at any time:
  - **Disable in [App Name] for 1 Hour**: Temporarily snooze the pill for 60 minutes in that specific app without affecting any other windows.
  - **Disable in [App Name]**: Permanently disable Synt(ax)ly in that application.
  - **Resume / Re-enable**: Easily unpause or re-enable via the pill context menu or the menu bar dropdown icon.
  - Quick shortcuts to **Open Writing Pad (`⌘N`)**, **Settings (`⌘,`)**, or **Reset Position**.
- **Draggable Pill & HUD with Position Memory**: Drag the pill or the expanded card anywhere on your display so it never blocks your content; your custom coordinates are remembered automatically per app, and double-clicking resets them to default.
- **Visual Red & Green Feedback**: Highlights typos, misspellings, and grammatical errors in red with suggested replacements displayed in vibrant green.
- **Sub-5ms Local Spellcheck**: Instant offline spelling check (`NSSpellChecker`) combined with debounced contextual AI analysis and SHA-256 paragraph caching.
- **One-Key Quick Accept**: Press **`Option + Tab` (`⌥Tab`)** to immediately accept the top correction in-place without switching windows.
- **Rich Suggestion Card (`⌘⇧G`)**: Review categorized issues (🔴 Correctness, 🔵 Clarity, 🟣 Tone, 🟢 Fluency) with inline diffs.

### 3. Native macOS Polish
- **Instant Response**: Built without App Nap throttling, opening the menu bar dropdown instantly at 0ms.
- **Launch at Login**: Easily toggle `Launch at Login` in Settings or the menu bar using modern macOS `SMAppService`.
- **System Theme Harmony**: Built with 100% semantic Apple AppKit & SwiftUI components, rendering cleanly in both Light Mode and Dark Mode.
- **Privacy First**: Secure password fields (`kAXSecureTextFieldSubrole`) are automatically ignored. Zero telemetry or user tracking.

---

## 🔑 AI Providers & Supported Gateways

Synt(ax)ly connects to any standard OpenAI-compatible completions endpoint. Configure your preferred backend in **Settings (`⌘,`) → API & Model**:

| Provider / Gateway | Endpoint | Pricing & Capabilities |
|---|---|---|
| **[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)** *(Recommended)* | `http://127.0.0.1:8317/v1` | **Zero-API-Key**: Leverages your logged-in Google / Gemini / Anthropic subscriptions |
| **[Kiro Gateway](https://github.com/jwadow/kiro-gateway)** | `https://api.kirogateway.com/v1` *(or local)* | **Kiro Subscription**: Routes requests through Kiro IDE / CLI with Claude & frontier models |
| **[LM Studio](https://lmstudio.ai) / [Ollama](https://ollama.com)** | `http://localhost:1234/v1` / `:11434/v1` | **100% Free & Offline**: Private local inference using open-source models (`llama3.2`, `qwen`) |
| **[Google AI Studio](https://aistudio.google.com)** | `https://generativelanguage.googleapis.com/v1beta/openai/` | Generous free tier via standard Gemini API key |
| **OpenAI / OpenRouter / vLLM** | `https://api.openai.com/v1` | Pay-as-you-go with personal API keys |

### Featured Gateways:

#### ⚡ [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)
- **What it does**: An open-source gateway that exposes local CLI and web-authenticated AI sessions (such as Gemini CLI, Google Cloud SDK, Claude Code, and Codex) as a standard OpenAI-compatible HTTP server running at `http://127.0.0.1:8317/v1`.
- **How to connect in Synt(ax)ly**:
  1. Start `cli-proxy-api` in your terminal.
  2. In Syntly, open **Settings (`⌘,`) → API & Model** and click the **CLI Proxy API (127.0.0.1:8317)** preset.
  3. Syntly **automatically detects** your local configuration and auth tokens from `~/.cli-proxy-api/config.yaml`—no manual API key copying required!

#### 🛡️ [jwadow/kiro-gateway](https://github.com/jwadow/kiro-gateway)
- **What it does**: A dedicated proxy API gateway for the Kiro IDE & CLI (powered by Amazon Q Developer / AWS CodeWhisperer infrastructure). It provides OpenAI- and Anthropic-compatible endpoints, enabling external macOS apps and agentic tools to query Claude and frontier reasoning models through your active Kiro subscription.
- **How to connect in Synt(ax)ly**:
  1. Launch your `kiro-gateway` instance (or point to your managed gateway endpoint).
  2. In Syntly, select the **Kiro Gateway** preset from the Provider dropdown.
  3. Enter your gateway endpoint and API token; Syntly securely saves the token in the encrypted **macOS Keychain**.

- **Test Connection**: Click *Test Connection* in Settings to benchmark real-world round-trip latency.
- **Fetch Available Models**: Click the refresh button beside the model picker to query your gateway's `/models` endpoint and populate active models automatically.

---

## 🛠️ Build from Source

### Prerequisites
- macOS 14.0+ (Sonoma, Sequoia, or later)
- Xcode 15+ / Command Line Tools (`xcode-select --install`)
- Swift 5.9+

### Build & Run
```bash
# Clone the repository
git clone https://github.com/chayneps/syntly.git
cd syntly

# Run test suite (19 unit and integration tests)
swift test

# Build and package native Syntly.app bundle
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open Syntly.app
```

### Build Universal 2 DMG Installer
```bash
chmod +x scripts/build-dmg.sh
./scripts/build-dmg.sh
```
*Creates a compressed `Syntly-2.0.0-Universal.dmg` containing the native Universal 2 (`arm64` + `x86_64`) binary and drag-and-drop `/Applications` folder shortcut.*

---

## 📄 License

Distributed under the **MIT License**. See [LICENSE](LICENSE) for details.
