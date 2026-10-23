import SwiftUI
import AppKit

/// Renders the app's own window to PNG files for the README: `GmailGTD --demo --export-screenshots <folder>`.
/// It only ever shows the demo mailbox (fictional people), never a real one, and it draws the app's own
/// views, so it needs no screen-recording permission.
@MainActor
enum ScreenshotExport {
    static var directory: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--export-screenshots"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    /// stderr is unbuffered, so progress shows up even when output is redirected.
    static func log(_ message: String) { FileHandle.standardError.write(Data("[export] \(message)\n".utf8)) }

    static func run(model: AppModel, into directory: String) async {
        guard model.demo else {
            log("Refusing to export screenshots of a real mailbox: add --demo.")
            NSApp.terminate(nil)
            return
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            log("No window to capture.")
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()

        let scenes: [(name: String, folder: Folder)] = [
            ("today", .today),
            ("inbox", .inbox),
            ("next-action", .bucket(.nextAction)),
            ("projects", .bucket(.project)),
        ]
        for scene in scenes {
            model.folder = scene.folder
            log("scene \(scene.name): waiting")
            await settle(model)
            capture(window, to: "\(directory)/\(scene.name).png")
            log("saved \(scene.name).png")
        }
        NSApp.terminate(nil)
    }

    /// Waits for the list to load and for the on-device model to finish the summaries on screen.
    private static func settle(_ model: AppModel) async {
        try? await Task.sleep(for: .seconds(3))
        var waited = 0.0
        while (!model.pending.isEmpty || !model.inflight.isEmpty || model.loading) && waited < 180 {
            try? await Task.sleep(for: .milliseconds(500))
            waited += 0.5
        }
        try? await Task.sleep(for: .seconds(1.5))
    }

    private static func capture(_ window: NSWindow, to path: String) {
        // The window's frame view includes the title bar and toolbar, not just the content.
        guard let frame = window.contentView?.superview ?? window.contentView,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(filePath: path))
        }
    }
}
