import SwiftUI
import AppKit
import GTDCore

/// A SwiftPM executable has no app bundle, so macOS starts it as a background process with no
/// window or Dock icon. Promote it to a regular foreground app on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build tooling: `GmailGTD --export-icon <folder>.iconset` writes the icon files and quits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-icon"), args.indices.contains(i + 1) {
            AppIcon.exportIconset(to: args[i + 1])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIcon.image   // the Dock icon when there is no app bundle
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
            CommandMenu("Go") {
                Group {
                    Button("Today") { model.folder = .today }
                        .keyboardShortcut("t", modifiers: .command)
                    Button("Inbox") { model.folder = .inbox }
                        .keyboardShortcut("0", modifiers: .command)
                    Divider()
                    ForEach(GTDBucket.allCases, id: \.self) { bucket in
                        Button(bucket.title) { model.folder = .bucket(bucket) }
                            .keyboardShortcut(KeyEquivalent(bucket.shortcut), modifiers: .command)
                    }
                }
                .disabled(!model.signedIn)
            }
            CommandMenu("Triage") {
                // Plain-key shortcuts only apply once there is a thread open, so they never swallow typing
                // (for example in the sign-in fields).
                Group {
                    ForEach(GTDBucket.allCases, id: \.self) { bucket in
                        Button("File as \(bucket.title)") { Task { await model.fileSelected(into: bucket) } }
                            .keyboardShortcut(KeyEquivalent(bucket.shortcut), modifiers: [])
                    }
                    Button("Back to Inbox") { Task { await model.unfileSelected() } }
                        .keyboardShortcut("0", modifiers: [])
                    Divider()
                    Button("Accept Suggestion") { Task { await model.acceptSuggestion() } }
                        .keyboardShortcut("a", modifiers: [])
                    Button("Archive") { Task { await model.archiveSelected() } }
                        .keyboardShortcut("e", modifiers: [])
                        .disabled(!model.canArchive)
                    Button("Regenerate Suggestion") { model.regenerateSelected() }
                        .keyboardShortcut("r", modifiers: [])
                    Button("Open in Gmail") { model.openSelectedInGmail() }
                        .keyboardShortcut("o", modifiers: [])
                }
                .disabled(model.detail == nil)
                Divider()
                Button("Keyboard Shortcuts") { model.shortcutsPinned.toggle() }
                    .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}
