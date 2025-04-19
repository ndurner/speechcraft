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

    /// Proofreads or cleans up the given transcript via the LLM, then inserts into the application.
    func proofreadTranscript(transcript: String) {
        transcribeState = .transcribing
        let instruction = "Please proofread and clean up the following transcript. Return only the cleaned transcript without any explanation."
        let proofModel = defaults.string(forKey: "ProofreadingModel") ?? openAIChatModel
        callChat(instruction: instruction, text: transcript, modelOverride: proofModel) { cleaned in
            DispatchQueue.main.async {
                self.insertTranscript(cleaned)
                self.transcribeState = .ready
            }
        }
    }
}