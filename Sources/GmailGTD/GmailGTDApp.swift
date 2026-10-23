import SwiftUI
import AppKit
import GTDCore

/// A SwiftPM executable has no app bundle, so macOS starts it as a background process with no
/// window or Dock icon. Promote it to a regular foreground app on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct GmailGTDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Gmail GTD") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.start() }
        }
        .commands {
            CommandMenu("Triage") {
                ForEach(GTDBucket.allCases, id: \.self) { bucket in
                    Button("File as \(bucket.title)") { Task { await model.fileSelected(into: bucket) } }
                        .keyboardShortcut(KeyEquivalent(bucket.shortcut), modifiers: [])
                }
                Button("Back to Inbox") { Task { await model.unfileSelected() } }
                    .keyboardShortcut("0", modifiers: [])
                Divider()
                Button("Suggest Bucket") { Task { await model.suggestForSelected() } }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}
