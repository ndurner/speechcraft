# SpeechCraft for macOS

This is a background macOS app that listens for **Option+S** to start and stop audio recording.
When recording stops, it sends the audio to OpenAI's `gpt-4o-transcribe` model for streaming transcription,
then inserts the final transcript at the current cursor position.

## Setup

1. Create a new macOS App project in Xcode (AppKit or SwiftUI-based).
2. Add the files `AppDelegate.swift` and `SuperWhisperApp.swift` from this directory into your project.
3. In your target's **Signing & Capabilities**, configure sandbox and network:
   - If you prefer unrestricted behavior, **remove** the **App Sandbox** capability entirely (this disables sandboxing).
   - Otherwise, leave **App Sandbox** **Enabled**, then under **App Sandbox** options:
     - Check **Incoming Connections (Server)** and **Outgoing Connections (Client)** to allow network access.
     - (Optional) add a temporary exception for `com.apple.nesessionmanager.content-filter` if your network layer requires it.
4. In **Info.plist** (your target’s Info.plist inside the Xcode project), make sure you have:
   - **NSMicrophoneUsageDescription** (String): "Recording audio for transcription"
     (Without this, macOS will silently deny microphone access.)
   - **LSUIElement** (Boolean): **YES** (1) to hide the Dock icon and menu bar.
5. In **System Settings → Privacy & Security**:
   - Under **Accessibility**, add and enable your built app so it can capture global key events.
   - Under **Microphone**, add and enable your built app so it can record audio.
6. Set your Azure OpenAI endpoint URL and API key in the app environment:
   - In Xcode scheme **Edit Scheme → Run → Arguments → Environment Variables**, add:
     - `AZURE_OPENAI_ENDPOINT` = `https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_TRANSCRIBE_DEPLOYMENT/audio/transcriptions?api-version=2025-03-01-preview`
     - `AZURE_OPENAI_CHAT_ENDPOINT` = `https://YOUR_RESOURCE.openai.azure.com/openai/deployments/YOUR_CHAT_DEPLOYMENT/chat/completions?api-version=2025-03-01-preview`
     - `AZURE_OPENAI_KEY` = `<your_api_key>`

## Usage

- Press **Option+S** to start recording (status bar icon turns red).
- Press **Option+S** again to stop recording, transcribe (icon turns blue), and automatically paste the result at the current cursor (icon then turns green).
- Press **Option+Shift+S** to copy the current selection, speak an instruction (icon turns red), and on pressing again, transcribe the instruction, apply it to the selection via GPT-4o (icon turns blue), then replace the selected text with the result (icon turns green).

## Dependencies

- macOS 12+ (Monterey or later)
- Swift 5.5+
 - Swift 5.5+

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.