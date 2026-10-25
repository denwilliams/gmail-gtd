import SwiftUI
import AppKit
import GTDCore

/// A SwiftPM executable has no app bundle, so macOS starts it as a background process with no
/// window or Dock icon. Promote it to a regular foreground app on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build tooling: `GmailGTD --export-icon <folder>.iconset` writes the icon files and quits.
        let args = CommandLine.arguments
        // `GmailGTD --check-config` reports what the app can see (never the values) and quits.
        if args.contains("--check-config") {
            print("client ID saved: \(OAuthConfig.load() != nil ? "yes" : "no")")
            print("signed in (tokens in Keychain): \(TokenStore.load() != nil ? "yes" : "no")")
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--export-icon"), args.indices.contains(i + 1) {
            AppIcon.exportIconset(to: args[i + 1])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIcon.image   // the Dock icon when there is no app bundle
        NSApp.activate()

        // Since macOS 14 an app started by a script can't make itself active, and SwiftUI doesn't put its window
        // on screen until it is, so the app sat in the background with only a menu bar. Ordering the window to the
        // front doesn't need activation. (Launching from Finder or the Dock activates normally; this is harmless there.)
        Task { @MainActor in
            for attempt in 1...40 {
                try? await Task.sleep(for: .milliseconds(250))
                let windows = NSApp.windows.filter { $0.canBecomeMain }
                if windows.isEmpty && attempt == 6 {   // still nothing after 1.5s: ask SwiftUI for one
                    NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
                }
                for window in windows where !window.isVisible { window.orderFrontRegardless() }
                if !windows.isEmpty && windows.allSatisfy(\.isVisible) { break }
            }
        }
    }

    /// Clicking the Dock icon with no window open brings one back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
}

@main
struct GmailGTDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        // One window: every view shares one model, so extra windows would only duplicate it. Unlike a WindowGroup,
        // a Window scene is opened at launch every time, even when the app is started by a script.
        Window("Gmail GTD", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 560)
                .task {
                    if ScreenshotExport.directory != nil { ScreenshotExport.log("window task started") }
                    await model.start()
                    if let folder = ScreenshotExport.directory {
                        ScreenshotExport.log("model started, demo=\(model.demo), folder=\(model.folder)")
                        await ScreenshotExport.run(model: model, into: folder)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Categorisation Settings…") { model.showingCategorisationSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // Replaces the system Undo: nothing in the mail window is editable text, and ⌘Z should take back a move.
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoStack.last.map { "Undo \($0.summary)" } ?? "Undo") { Task { await model.undoLastMove() } }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(model.undoStack.isEmpty)
            }
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
                    Button("Approve Suggestion") { Task { await model.acceptSuggestion() } }
                        .keyboardShortcut("a", modifiers: [])
                        .disabled(model.approvalBucket == nil || model.showingCategorisationSettings)
                    Button("Done") { Task { await model.finishSelected() } }
                        .keyboardShortcut("e", modifiers: [])
                        .disabled(!model.canFinish)
                    Button("Regenerate Suggestion") { model.regenerateSelected() }
                        .keyboardShortcut("r", modifiers: [])
                    Button("Open in Gmail") { model.openSelectedInGmail() }
                        .keyboardShortcut("o", modifiers: [])
                }
                .disabled(model.detail == nil || model.showingCategorisationSettings)
                Divider()
                Button("Keyboard Shortcuts") { model.shortcutsPinned.toggle() }
                    .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}
