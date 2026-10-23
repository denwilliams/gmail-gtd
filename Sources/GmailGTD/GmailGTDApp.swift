import SwiftUI
import GTDCore

@main
struct GmailGTDApp: App {
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
