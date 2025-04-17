import SwiftUI

@main
struct SpeechCraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { PreferencesView() }
    }
}
