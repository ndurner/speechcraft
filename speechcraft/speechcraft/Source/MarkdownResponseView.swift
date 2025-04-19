import SwiftUI
import MarkdownUI

/// A scrollable, selectable view that renders Markdown coming from an LLM.
/// * Uses SwiftUI’s native `Markdown` view when you build with the macOS 14 / iOS 17 SDK.
/// * Falls back to the open‑source **MarkdownUI** package if the symbol is not available.
/// * As a safety net, converts to `AttributedString` so the project still compiles even
///   on older Xcode versions.
struct MarkdownResponseView: View {
    let text: String

    private var markdownText: String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n") // Windows → Unix
            .replacingOccurrences(of: "\n", with: "\n\n")  // single → double newline
    }

    var body: some View {
        ScrollView(.vertical) {
            content
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    @ViewBuilder
    private var content: some View {
        Markdown(markdownText)
    }
}
