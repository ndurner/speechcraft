# SpeechCraft

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![Swift 5.5+](https://img.shields.io/badge/Swift-5.5%2B-orange.svg)](https://swift.org) [![Platform: macOS 12+](https://img.shields.io/badge/macOS-12%2B-lightgrey.svg)](https://www.apple.com/macos)

> A lightweight macOS menu‑bar utility that turns your voice into text and smart edits using the OpenAI API.

## Table of Contents
1. [Features](#features)
2. [Requirements](#requirements)
3. [Getting the App](#getting-the-app)
4. [Installation](#installation)
5. [Configuration](#configuration)
6. [Usage](#usage)
7. [Development](#development)
8. [License](#license)

## Features
- 🎤 **Push‑to‑Talk Transcription**: Start/stop recording with **Option+S**, auto‑paste the transcript.
- ✂️ **Smart Text Transformations**: Copy selection, speak an instruction with **Option+Shift+S**, and replace text via GPT‑4o.
- 📋 **Clipboard Integration**: Seamlessly saves and restores your clipboard.
- 🖼️ **Visual Context**: Optionally include a screenshot for richer prompts (macOS 13+).
  Configure via **Transcription → Include screenshots in GPT requests**.
- 📝 **Proofread Transcripts**: Automatically proofread and clean up your transcriptions with GPT-4o with image context. Yes, you can now dictate code!
- 🔐 **Flexible Deployment**: Supports App Store (sandboxed) or Developer ID (hardened runtime) builds.
- 🚀 **Minimal Footprint**: Runs in the menu bar, no Dock icon.
- 💬 **Modal Chat**: Press **Option+A** to record an audio instruction (optionally with selected text & screenshot), then view the AI’s response in a modal dialog with Copy/Close buttons.

## Requirements
- macOS 12.0 (Monterey) or later
- Xcode 14 or later (Swift 5.5+)
- An OpenAI or Azure OpenAI subscription

## Getting the App

If you just want to try SpeechCraft, download the latest DMG from the Releases page on GitHub and install it directly. No build tools are required:

https://github.com/esawtooth/SpeechCraft/releases

Developers who wish to build from source can follow the instructions below.

## Installation
1. Clone the repo:
   ```bash
   git clone https://github.com/yourorg/SpeechCraft.git
   cd SpeechCraft
   ```
2. Open the Xcode project:
   ```bash
   open speechcraft/speechcraft/SpeechCraft.xcodeproj
   ```
3. Select the **SpeechCraft** scheme, configure your Team under **Signing & Capabilities**, then **Build** & **Run**.

## Configuration
1. **Entitlements**
   - App Store: Enable **App Sandbox** (allow network, microphone).
   - Outside Store: Disable sandbox, enable **Hardened Runtime**.
2. **Info.plist**
   - `NSMicrophoneUsageDescription`: “Recording audio for transcription”
   - `NSCameraUsageDescription`: “Screen recording for rich context”
   - `LSUIElement`: `YES` (hides Dock icon)
3. **Permissions** (System Settings → Privacy & Security)
   - Grant **Accessibility** & **Microphone** access to SpeechCraft.
4. **Environment Variables** (Xcode Scheme → Run → Arguments → Env Vars)
   ```text
   AZURE_OPENAI_ENDPOINT            = https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_TRANSCRIBE_DEPLOYMENT/audio/transcriptions?api-version=2025-03-01-preview
   AZURE_OPENAI_CHAT_ENDPOINT       = https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_CHAT_DEPLOYMENT/chat/completions?api-version=2025-03-01-preview
   AZURE_OPENAI_KEY                 = <your_api_key>
   ```

## Usage
- **Option+S**: Start/stop voice recording → automatic transcription & paste.
- **Option+Shift+S**: Copy selection → record instruction → GPT‑4o applies changes → replaces text.
- **Option+A**: Start/stop audio instruction recording (captures optional selected text & screenshot) → sends to AI chat → displays the response in a modal dialog with Copy/Close options.

🟢 Ready | 🔴 Recording | 🔵 Processing

## Development
1. Fork the repo and create a feature branch.
2. Open in Xcode, implement your changes.
3. If you have a custom icon (e.g. `icon.png`), you can embed it into your built `.app` by running:
   ```bash
   python3 apply_icon.py /path/to/SpeechCraft.app icon.png
   ```
4. Run & test locally.
5. Submit a pull request with clear commit messages.
6. Ensure SwiftLint and pre‑commit hooks pass.

## License
This project is released under the MIT License. See [LICENSE](LICENSE) for details.
