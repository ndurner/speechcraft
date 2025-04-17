import Cocoa
import SwiftUI
import AVFoundation
import ApplicationServices
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var eventTap: CFMachPort?
    // SwiftUI Preferences window
    private var preferencesWindow: NSWindow?
    var runLoopSource: CFRunLoopSource?
    var audioRecorder: AVAudioRecorder?
    // Silence-detection auto-stop
    private var silenceTimer: Timer?
    private var lastVoiceDate: Date?
    /// dB level below which is considered silence
    private let silenceLevelThreshold: Float = -30.0
    var isRecording = false
    var audioURL: URL?
    // Instruction recording mode
    private var instructionMode = false
    private var originalSelectedText: String?
    // Status bar item to indicate recording/transcribing state
    private var statusItem: NSStatusItem?
    private enum TranscribeState {
        case ready, recording, transcribing, error
    }
    // Configurable transcription model and prompt
    private var transcriptionModel = UserDefaults.standard.string(forKey: "TranscriptionModel") ?? "gpt-4o-transcribe"
    private let availableModels = ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper"]
    private var transcriptionPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt") ?? ""
    
    // Service configuration
    private enum ServiceType: String { case openAI = "OpenAI", azure = "Azure" }
    /// Current service type, read directly from UserDefaults
    private var serviceType: ServiceType {
        ServiceType(rawValue: UserDefaults.standard.string(forKey: "ServiceType") ?? "OpenAI") ?? .openAI
    }
    /// OpenAI API key from settings
    private var openAIKey: String? {
        UserDefaults.standard.string(forKey: "OpenAIKey")
    }
    /// OpenAI chat model from settings
    private var openAIChatModel: String {
        UserDefaults.standard.string(forKey: "OpenAIChatModel") ?? "gpt-3.5-turbo"
    }
    /// Azure API key from settings
    private var azureKey: String? {
        UserDefaults.standard.string(forKey: "AzureKey")
    }
    /// Azure transcription endpoint from settings
    private var azureTranscribeEndpoint: String? {
        UserDefaults.standard.string(forKey: "AzureTranscribeEndpoint")
    }
    /// Azure chat endpoint from settings
    private var azureChatEndpoint: String? {
        UserDefaults.standard.string(forKey: "AzureChatEndpoint")
    }
    private let defaults = UserDefaults.standard
    // MARK: - HotKey Capture
    struct HotKey: Codable {
        let keyCode: CGKeyCode
        let modifiers: CGEventFlags.RawValue
        let character: String
    }
    private enum HotKeyCaptureType { case record, instruction }
    private var keyCaptureMonitor: Any?
    private var captureType: HotKeyCaptureType?
    // Record hotkey (load or default Option+S)
    var recordHotKey: HotKey = {
        if let data = UserDefaults.standard.data(forKey: "RecordHotKey"),
           let hk = try? JSONDecoder().decode(HotKey.self, from: data) {
            return hk
        }
        return HotKey(keyCode: 1, modifiers: CGEventFlags.maskAlternate.rawValue, character: "S")
    }()
    // Instruction hotkey (load or default Option+Shift+S)
    var instructionHotKey: HotKey = {
        if let data = UserDefaults.standard.data(forKey: "InstructionHotKey"),
           let hk = try? JSONDecoder().decode(HotKey.self, from: data) {
            return hk
        }
        let mods = CGEventFlags.maskAlternate.union(.maskShift).rawValue
        return HotKey(keyCode: 1, modifiers: mods, character: "S")
    }()

    /// Returns a human-readable description of a HotKey (e.g. "⌥⇧S").
    func hotKeyDescription(_ hk: HotKey) -> String {
        var parts = ""
        let flags = CGEventFlags(rawValue: hk.modifiers)
        if flags.contains(.maskCommand) { parts += "⌘" }
        if flags.contains(.maskAlternate) { parts += "⌥" }
        if flags.contains(.maskControl) { parts += "⌃" }
        if flags.contains(.maskShift) { parts += "⇧" }
        parts += hk.character.uppercased()
        return parts
    }

    // MARK: - Transcription State
    private var transcribeState: TranscribeState = .ready {
        didSet { updateStatusIcon() }
    }

    // MARK: Configuration Check
    /// Returns true if required keys and endpoints are configured
    private var isConfigured: Bool {
        switch serviceType {
        case .openAI:
            return !(openAIKey?.isEmpty ?? true)
        case .azure:
            return !(azureKey?.isEmpty ?? true) &&
                   !(azureTranscribeEndpoint?.isEmpty ?? true) &&
                   !(azureChatEndpoint?.isEmpty ?? true)
        }
    }

    /// Ensure state is error if unconfigured
    private func updateConfigurationState() {
        if !isConfigured {
            transcribeState = .error
        } else if transcribeState == .error {
            transcribeState = .ready
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register default preferences
        UserDefaults.standard.register(defaults: [
            "EnableScreenshots": true,
            "EnableAutoSilenceStop": false,
            "SilenceTimeout": 2.0
        ])
        // Check and request Accessibility permission
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            // Prompt displayed; user must allow in System Settings → Privacy & Security → Accessibility
            NSLog("Accessibility permission not yet granted; requested via system prompt.")
        }
        // Check and request microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Microphone Access Required"
                        alert.informativeText = "Please enable Microphone access for SpeechCraft in System Settings → Privacy & Security → Microphone."
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Microphone Access Required"
                alert.informativeText = "Please enable Microphone access for SpeechCraft in System Settings → Privacy & Security → Microphone."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        setupEventTap()
        setupStatusItem()
        transcribeState = .ready
        // Validate configuration
        updateConfigurationState()
    }

    func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        guard let eventTap = eventTap else {
            NSLog("Failed to create event tap.")
            return
        }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        let mySelf = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
        return mySelf.handleEvent(proxy: proxy, type: type, event: event)
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            // Filter to modifier bits only
            let maskFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            let rawFlags = event.flags.intersection(maskFlags)
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // If unconfigured, open Settings on either hotkey
            if transcribeState == .error {
                if keyCode == recordHotKey.keyCode && rawFlags.rawValue == recordHotKey.modifiers {
                    openSettings(nil); return nil
                }
                if keyCode == instructionHotKey.keyCode && rawFlags.rawValue == instructionHotKey.modifiers {
                    openSettings(nil); return nil
                }
            }
            // Instruction hotkey
            if keyCode == instructionHotKey.keyCode && rawFlags.rawValue == instructionHotKey.modifiers {
                handleInstructionHotkey(); return nil
            }
            // Record/Stop hotkey
            if keyCode == recordHotKey.keyCode && rawFlags.rawValue == recordHotKey.modifiers {
                toggleRecording(); return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }

    func toggleRecording() {
        if !isRecording {
            startRecording()
            isRecording = true
        } else {
            stopRecording()
            isRecording = false
        }
    }

    func startRecording() {
        // AVAudioSession is unavailable on macOS; AVAudioRecorder works without explicit session setup
        let tmpDir = FileManager.default.temporaryDirectory
        let filename = "speechcraft_\(Date().timeIntervalSince1970).wav"
        audioURL = tmpDir.appendingPathComponent(filename)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        do {
            audioRecorder = try AVAudioRecorder(url: audioURL!, settings: settings)
            // Enable metering for silence detection
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.prepareToRecord()
            audioRecorder?.record()
            NSLog("startRecording: Recording started")
            transcribeState = .recording
            // Auto-stop on silence if enabled
            let autoStop = UserDefaults.standard.bool(forKey: "EnableAutoSilenceStop")
            if autoStop {
                let timeout = UserDefaults.standard.double(forKey: "SilenceTimeout")
                NSLog("startRecording: Auto-silence-stop enabled (timeout = %.2f s)", timeout)
                lastVoiceDate = Date()
                // Schedule periodic level checks
                silenceTimer?.invalidate()
                silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    self?.checkSilence()
                }
            }
        } catch {
            NSLog("Failed to start recording: \(error)")
        }
    }

    func stopRecording() {
        // Invalidate silence detection timer
        if let timer = silenceTimer {
            timer.invalidate()
            silenceTimer = nil
            NSLog("stopRecording: silence timer invalidated")
        }
        audioRecorder?.stop()
        transcribeState = .transcribing
        audioRecorder = nil
        guard let url = audioURL else { return }
        if instructionMode {
            transcribeInstruction(fileURL: url)
        } else {
            transcribe(fileURL: url)
        }
    }
    
    /// Periodically called to detect silence and auto-stop recording
    private func checkSilence() {
        guard let recorder = audioRecorder else { return }
        recorder.updateMeters()
        let level = recorder.averagePower(forChannel: 0)
        let now = Date()
        NSLog("checkSilence: level = %.1f dB", level)
        if level > silenceLevelThreshold {
            // Detected voice, reset timer
            lastVoiceDate = now
        } else if let last = lastVoiceDate {
            let silenceDuration = now.timeIntervalSince(last)
            let timeout = UserDefaults.standard.double(forKey: "SilenceTimeout")
            if silenceDuration >= timeout {
                NSLog("checkSilence: silence for %.2f s, timeout %.2f s reached, auto-stopping", silenceDuration, timeout)
                // Stop timer and recording
                silenceTimer?.invalidate()
                silenceTimer = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.isRecording else { return }
                    self.stopRecording()
                    self.isRecording = false
                }
            }
        }
    }

    func transcribe(fileURL: URL) {
        // Determine endpoint and API key based on service type
        let endpointURL: String
        let apiKey: String
        switch serviceType {
        case .openAI:
            endpointURL = "https://api.openai.com/v1/audio/transcriptions"
            guard let key = openAIKey, !key.isEmpty else {
                NSLog("OpenAI API key not configured")
                return
            }
            apiKey = key
        case .azure:
            guard let ep = azureTranscribeEndpoint, !ep.isEmpty,
                  let key = azureKey, !key.isEmpty else {
                NSLog("Azure endpoint or API key not configured")
                return
            }
            endpointURL = ep
            apiKey = key
        }
        guard let url = URL(string: endpointURL) else {
            NSLog("Invalid transcription endpoint URL: \(endpointURL)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: serviceType == .openAI ? "Authorization" : "api-key")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        // Add model param (configurable)
        let params = ["model": transcriptionModel]
        for (key, value) in params {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        // Add audio file
        let filename = fileURL.lastPathComponent
        if let fileData = try? Data(contentsOf: fileURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        // Add prompt if provided
        if !transcriptionPrompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(transcriptionPrompt)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        // Perform request without streaming
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("Transcription error: \(error)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else {
                NSLog("Failed to parse transcription response")
                return
            }
            DispatchQueue.main.async {
                self.insertTranscript(text)
                self.transcribeState = .ready
            }
        }.resume()
    }

    func insertTranscript(_ transcript: String) {
        let pasteboard = NSPasteboard.general
        // Save existing plain-text string (if any)
        let previousString = pasteboard.string(forType: .string)
        // Overwrite with our transcript
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        // Simulate paste (Cmd+V)
        simulatePaste()
        // Restore prior clipboard string after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pasteboard.clearContents()
            if let prev = previousString {
                pasteboard.setString(prev, forType: .string)
            }
        }
    }

    func simulatePaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    // Simulate Command+C to copy the current selection
    private func simulateCopy() {
        let src = CGEventSource(stateID: .hidSystemState)
        let cKeyCode: CGKeyCode = 8  // 'c'
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: cKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: cKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    // Handle Option+Shift+S: copy selection and record audio for instruction
    private func handleInstructionHotkey() {
        if !isRecording {
            instructionMode = true
            let pasteboard = NSPasteboard.general
            let prevChangeCount = pasteboard.changeCount
            simulateCopy()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let pb = NSPasteboard.general
            if pb.changeCount > prevChangeCount, let copied = pb.string(forType: .string) {
                self.originalSelectedText = copied
            } else {
                self.originalSelectedText = nil
            }
            self.startRecording()
            self.isRecording = true
            }
        } else if isRecording && instructionMode {
            stopRecording()
            isRecording = false
        }
    }

    // MARK: - Status Item Indicator
    /// Draws a filled circle image for the given state.
    private func statusImage(for state: TranscribeState) -> NSImage {
        let diameter: CGFloat = 14
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        let color: NSColor
        switch state {
        case .ready: color = .systemGreen
        case .recording: color = .systemRed
        case .transcribing: color = .systemBlue
        case .error: color = .systemRed
        }
        color.setFill()
        let rect = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        NSBezierPath(ovalIn: rect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Creates the status bar item and sets initial icon.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        configureMenu()
    }

    /// Updates the status bar icon based on current state.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        switch transcribeState {
        case .error:
            if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Not Configured") {
                img.isTemplate = true
                button.image = img
                button.contentTintColor = .systemRed
            }
        default:
            // Clear any tint when showing colored circles
            button.contentTintColor = nil
            button.image = statusImage(for: transcribeState)
        }
    }
    // MARK: - Status Item Menu
    private func configureMenu() {
        guard let statusItem = statusItem else { return }
        let menu = NSMenu()
        // Settings item
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        if let gearIcon = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings") {
            gearIcon.isTemplate = true
            settingsItem.image = gearIcon
        }
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        // Model submenu
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let modelSub = NSMenu(title: "Model")
        for m in availableModels {
            let it = NSMenuItem(title: m, action: #selector(selectModel(_:)), keyEquivalent: "")
            it.target = self
            it.state = (m == transcriptionModel ? .on : .off)
            modelSub.addItem(it)
        }
        menu.setSubmenu(modelSub, for: modelItem)
        menu.addItem(modelItem)
        // Prompt
        menu.addItem(NSMenuItem(title: "Set Prompt…", action: #selector(setPrompt(_:)), keyEquivalent: ""))
        menu.items.last?.target = self
        // Change Record Hotkey
        let recordHK = NSMenuItem(title: "Change Record Hotkey… (Currently: \(hotKeyDescription(recordHotKey)))", action: #selector(changeRecordHotkey(_:)), keyEquivalent: "")
        recordHK.target = self
        menu.addItem(recordHK)
        // Change Instruction Hotkey
        let instrHK = NSMenuItem(title: "Change Instruction Hotkey… (Currently: \(hotKeyDescription(instructionHotKey)))", action: #selector(changeInstructionHotkey(_:)), keyEquivalent: "")
        instrHK.target = self
        menu.addItem(instrHK)
        // Quit
        let quit = NSMenuItem(title: "Quit SpeechCraft", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        transcriptionModel = sender.title
        defaults.set(transcriptionModel, forKey: "TranscriptionModel")
        // update checks
        if let items = statusItem?.menu?.item(withTitle: "Model")?.submenu?.items {
        for it in items { it.state = (it.title == transcriptionModel ? .on : .off) }
        }
    }

    @objc private func setPrompt(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Set Transcription Prompt"
        alert.informativeText = "Enter a custom prompt for the transcription (optional):"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        tf.stringValue = transcriptionPrompt
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            transcriptionPrompt = tf.stringValue
            defaults.set(transcriptionPrompt, forKey: "TranscriptionPrompt")
        }
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }
    
    // MARK: - HotKey Capture Methods
    @objc func changeRecordHotkey(_ sender: Any?) {
        beginHotKeyCapture(type: .record)
    }

    @objc func changeInstructionHotkey(_ sender: Any?) {
        beginHotKeyCapture(type: .instruction)
    }

    private func beginHotKeyCapture(type: HotKeyCaptureType) {
        captureType = type
        // Inform user
        let alert = NSAlert()
        alert.messageText = "Press desired hotkey"
        alert.informativeText = "Now press the key combination you want to assign."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: NSApp.mainWindow ?? NSWindow()) { _ in }
        // Install local monitor
        keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let type = self.captureType else { return event }
            // Filter to modifier bits only
            let maskMods: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            // Convert rawValue (UInt) to UInt64 for CGEventFlags.RawValue
            let rawMods = UInt64(event.modifierFlags.intersection(maskMods).rawValue)
            let char = event.charactersIgnoringModifiers?.uppercased() ?? ""
            let hk = HotKey(keyCode: event.keyCode, modifiers: rawMods, character: char)
            switch type {
            case .record:
                self.recordHotKey = hk
                if let data = try? JSONEncoder().encode(hk) {
                    self.defaults.set(data, forKey: "RecordHotKey")
                }
            case .instruction:
                self.instructionHotKey = hk
                if let data = try? JSONEncoder().encode(hk) {
                    self.defaults.set(data, forKey: "InstructionHotKey")
                }
            }
            self.captureType = nil
            if let monitor = self.keyCaptureMonitor {
                NSEvent.removeMonitor(monitor)
                self.keyCaptureMonitor = nil
            }
            self.configureMenu()
            return nil
        }
    }

    // MARK: - Settings
    @objc private func openSettings(_ sender: Any?) {
        if preferencesWindow == nil {
            let contentView = PreferencesView()
            let hostingController = NSHostingController(rootView: contentView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Preferences"
            window.contentViewController = hostingController
            preferencesWindow = window
        }
        preferencesWindow?.center()
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    // MARK: - Instruction Mode
    private func transcribeInstruction(fileURL: URL) {
        // Transcribe the spoken instruction
        guard let endpoint = ProcessInfo.processInfo.environment["AZURE_OPENAI_ENDPOINT"],
              let apiKey = ProcessInfo.processInfo.environment["AZURE_OPENAI_KEY"],
              let url = URL(string: endpoint) else {
            NSLog("AZURE_OPENAI_ENDPOINT or AZURE_OPENAI_KEY not set or invalid")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        // Add model param for instruction transcription
        let params = ["model": transcriptionModel]
        for (key, value) in params {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        let filename = fileURL.lastPathComponent
        if let fileData = try? Data(contentsOf: fileURL) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }
        // Add prompt if provided
        if !transcriptionPrompt.isEmpty {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(transcriptionPrompt)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("Instruction transcription error: \(error)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let instruction = json["text"] as? String else {
                NSLog("Failed to parse instruction transcription response or instruction missing")
                return
            }
            let original = self.originalSelectedText
            self.callChat(instruction: instruction, text: original ?? "") { result in
                DispatchQueue.main.async {
                    self.insertTranscript(result)
                    self.transcribeState = .ready
                    self.instructionMode = false
                    self.originalSelectedText = nil
                }
            }
        }.resume()
    }

    /// Captures the screen where the cursor is using ScreenCaptureKit and returns a base64-encoded PNG data URI.
    /// Captures a one‐off screenshot of the frontmost application using ScreenCaptureKit
    /// and returns it as a PNG data URI.
    @available(macOS 13.0, *)
    private func captureScreenshotDataURI() -> String? {
        // 1) Identify frontmost app
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontApp.bundleIdentifier else {
            NSLog("captureScreenshotDataURI: no frontmost application")
            return nil
        }

        // 2) Fetch shareable content (only on‐screen windows)
        var shareableContent: SCShareableContent?
        let contentSem = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error = error {
                NSLog("captureScreenshotDataURI: error fetching content: \(error.localizedDescription)")
            }
            shareableContent = content
            contentSem.signal()
        }
        _ = contentSem.wait(timeout: .now() + 5)

        guard let content = shareableContent else {
            NSLog("captureScreenshotDataURI: no shareable content")
            return nil
        }

        // 3) Exclude every other app’s windows
        let appsToExclude = content.applications.filter { $0.bundleIdentifier != bundleID }

        // 4) Pick a display (we’ll just pick the first one)
        guard let scDisplay = content.displays.first else {
            NSLog("captureScreenshotDataURI: no displays available")
            return nil
        }

        // 5) Build a filter that leaves only the frontmost app’s windows
        let filter = SCContentFilter(
            display: scDisplay,
            excludingApplications: appsToExclude,
            exceptingWindows: []
        )

        // 6) Screenshot configuration
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor  = true

        // 7) Fire off the async screenshot
        var resultURI: String?
        let captureSem = DispatchSemaphore(value: 0)
        Task {
            do {
                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                // Downscale if max dimension > 1280px
                let maxSide = max(cgImage.width, cgImage.height)
                let finalCG: CGImage
                if maxSide > 1280 {
                    let scale = 1280.0 / Double(maxSide)
                    let ciSrc = CIImage(cgImage: cgImage)
                    if let scaleFilter = CIFilter(name: "CILanczosScaleTransform") {
                        scaleFilter.setValue(ciSrc, forKey: kCIInputImageKey)
                        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
                        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
                        let ciCtx = CIContext()
                        if let outCI = scaleFilter.outputImage,
                           let scaledCG = ciCtx.createCGImage(outCI, from: outCI.extent) {
                            finalCG = scaledCG
                        } else {
                            finalCG = cgImage
                        }
                    } else {
                        finalCG = cgImage
                    }
                } else {
                    finalCG = cgImage
                }
                let bitmap = NSBitmapImageRep(cgImage: finalCG)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let b64 = png.base64EncodedString()
                    resultURI = "data:image/png;base64,\(b64)"
                }
            } catch {
                NSLog("captureScreenshotDataURI: screenshot error: \(error)")
            }
            captureSem.signal()
        }
        _ = captureSem.wait(timeout: .now() + 5)
        return resultURI
    }

    private func callChat(instruction: String, text: String, completion: @escaping (String) -> Void) {
        // Determine chat endpoint and key
        let endpointURL: String
        let apiKey: String
        switch serviceType {
        case .openAI:
            endpointURL = "https://api.openai.com/v1/chat/completions"
            guard let key = openAIKey, !key.isEmpty else {
                NSLog("OpenAI API key not configured")
                return
            }
            apiKey = key
        case .azure:
            guard let ep = azureChatEndpoint, !ep.isEmpty,
                  let key = azureKey, !key.isEmpty else {
                NSLog("Azure chat endpoint or API key not configured")
                return
            }
            endpointURL = ep
            apiKey = key
        }
        guard let url = URL(string: endpointURL) else {
            NSLog("Invalid chat endpoint URL: \(endpointURL)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if serviceType == .openAI {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Build a single user message with structured content: optional image + text
        var contentArr: [[String: Any]] = []
        if #available(macOS 13.0, *) {
            if let screenshot = captureScreenshotDataURI() {
                NSLog("Screen Captured!")
                contentArr.append([
                    "type": "image_url",
                    "image_url": ["url": screenshot]
                ])
            }
        }
        // Add the instruction as a text part
        var textPart: [String: Any] = ["type": "text", "text": "Instruction: \(instruction)"]
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText {
            textPart["text"] = (textPart["text"] as! String)
                + "\nText: \(text)"
                + "\nPlease execute the instruction on the text and return only the output without any explanation."
        } else {
            textPart["text"] = (textPart["text"] as! String)
                + "\nPlease execute the instruction and return only the output without any explanation."
        }
        contentArr.append(textPart)
        // Construct the chat message array
        let userMsg: [String: Any] = ["role": "user", "content": contentArr]
        let messages = [userMsg]
        NSLog("Sending Chat API messages: %@", messages)
        // Prepare payload
        let payload: [String: Any]
        if serviceType == .openAI {
            payload = ["model": openAIChatModel, "messages": messages]
        } else {
            payload = ["messages": messages]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("Chat completion error: \(error)")
                return
            }
            guard let data = data else {
                NSLog("Chat completion: no data in response")
                return
            }
            // Try to parse JSON choices
            var resultText: String? = nil
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first {
                // Chat completion format
                if let message = (first["message"] as? [String: Any])?["content"] as? String {
                    resultText = message
                }
                // Fallback to text (e.g., completions endpoint)
                else if let text = first["text"] as? String {
                    resultText = text
                }
            }
            // If parsing failed, fallback to raw response string
            if resultText == nil, let raw = String(data: data, encoding: .utf8) {
                resultText = raw
            }
            if let output = resultText {
                completion(output)
            } else {
                NSLog("Failed to parse chat completion response, data: %s", String(describing: String(data: data, encoding: .utf8) ?? "<non-textual>") )
            }
        }.resume()
    }
}
