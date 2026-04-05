import SwiftUI

@main
struct PersonalAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window — entirely menu-bar driven.
        Settings { EmptyView() }
    }
}
