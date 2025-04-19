import Foundation
import Cocoa

extension AppDelegate {
    /// Sends a chat instruction and text to the LLM, invoking completion with the response.
    func callChat(instruction: String,
                  text: String,
                  modelOverride: String? = nil,
                  completion: @escaping (String) -> Void) {
        let chatModel = modelOverride ?? openAIChatModel
        let endpoint: String
        var headers: [String: String] = ["Content-Type": "application/json"]
        switch serviceType {
        case .openAI:
            endpoint = "https://api.openai.com/v1/chat/completions"
            if let key = openAIKey, !key.isEmpty {
                headers["Authorization"] = "Bearer \(key)"
            }
        case .azure:
            endpoint = azureChatEndpoint ?? ""
            if let key = azureKey {
                headers["api-key"] = key
            }
        }
        guard let url = URL(string: endpoint) else { return }
        let userMsg: [String: Any] = ["role": "user", "content": text]
        let systemMsg: [String: Any] = ["role": "system", "content": instruction]
        let payload: [String: Any] = [
            "model": chatModel,
            "messages": [systemMsg, userMsg]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request) { data, _, error in
            var result = ""
            if let error = error {
                result = "Error: \(error.localizedDescription)"
            } else if let d = data,
                      let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let content = (first["message"] as? [String: Any])?["content"] as? String {
                result = content
            } else if let d = data,
                      let str = String(data: d, encoding: .utf8) {
                result = str
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }.resume()
    }

    /// Proofreads or cleans up the given transcript via the LLM (with optional screenshot), then inserts into the application.
    func proofreadTranscript(transcript: String) {
        // Indicate proofread in progress
        transcribeState = .transcribing
        // Build instruction
        let instruction = "Do not add, remove or alter any provided information. Do not try to answer questions. Do not add any explanations."
        // Determine model
        let proofModel = defaults.string(forKey: "ProofreadingModel") ?? openAIChatModel
        // Build content array: include screenshot if enabled, then transcript text
        var contentArr: [[String: Any]] = []
        if #available(macOS 13.0, *), defaults.bool(forKey: "EnableScreenshots") {
            if let screenshot = captureScreenshotDataURI() {
                contentArr.append([
                    "type": "image_url",
                    "image_url": ["url": screenshot]
                ])
            }
        }
        contentArr.append([
            "type": "text",
            "text": "Please proofread and clean up the following transcript of spoken text. You can refer the screenshot for how some words or abbreviations should be transcribed. Return only the cleaned transcript without any explanation:" + transcript
        ])
        // Create system and user messages
        let systemMsg: [String: Any] = ["role": "system", "content": instruction]
        let userMsg: [String: Any] = ["role": "user", "content": contentArr]
        let messages: [[String: Any]] = [systemMsg, userMsg]
        // Prepare payload
        let payload: [String: Any]
        if serviceType == .openAI {
            payload = ["model": proofModel, "messages": messages]
        } else {
            payload = ["messages": messages]
        }
        // Build request
        let endpoint = serviceType == .openAI
            ? "https://api.openai.com/v1/chat/completions"
            : (azureChatEndpoint ?? "")
        guard let url = URL(string: endpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if serviceType == .openAI {
            if let key = openAIKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        } else {
            if let key = azureKey { request.setValue(key, forHTTPHeaderField: "api-key") }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        // Send request
        URLSession.shared.dataTask(with: request) { data, _, error in
            var cleaned = ""
            if let error = error {
                cleaned = "Error: \(error.localizedDescription)"
            } else if let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let msg = (first["message"] as? [String: Any])?["content"] as? String {
                cleaned = msg
            } else if let data = data,
                      let raw = String(data: data, encoding: .utf8) {
                cleaned = raw
            }
            DispatchQueue.main.async {
                self.insertTranscript(cleaned)
                self.transcribeState = .ready
            }
        }.resume()
    }
}
