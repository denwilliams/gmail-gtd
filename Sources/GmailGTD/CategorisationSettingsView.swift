import SwiftUI
import GTDCore

struct CategorisationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var settings = CategorisationSettings()
    @State private var token = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Categorisation Settings").font(.title2.bold())
            Toggle("Enable Jev alongside the local model", isOn: $settings.jevEnabled)
            Text("When enabled, visible email threads (senders, subjects and message text) are sent automatically to TypeSafe for categorisation. API charges may apply. A token alone does not enable Jev. Approve requires a valid Jev result; there is no local fallback. Summaries and project plans stay on-device.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Jev API token (stored only in Keychain)", text: $token)
            Text("Clear this field and save to remove the stored token.").font(.caption).foregroundStyle(.secondary)
            promptEditor("Local categorisation prompt", text: $settings.localPrompt,
                         limit: TriagePrompts.localMaxBytes, defaultValue: TriagePrompts.local)
            promptEditor("Jev categorisation prompt", text: $settings.jevPrompt,
                         limit: TriagePrompts.jevMaxBytes, defaultValue: TriagePrompts.jev)
            Text("Jev uses jev-1.14.0: 64k tokens/request, 32k/question. This app conservatively caps the complete request at 30,000 UTF-8 JSON bytes, trimming email from the oldest end. Prompts are never silently shortened. Local email uses its existing small context budget.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try model.saveCategorisationSettings(settings, token: token)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 680)
        .onAppear { settings = model.categorisationSettings; token = JevTokenStore.load() ?? "" }
        .onDisappear { token = "" }
    }

    private func promptEditor(_ title: String, text: Binding<String>, limit: Int, defaultValue: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(text.wrappedValue.utf8.count)/\(limit) UTF-8 bytes").font(.caption)
                    .foregroundStyle(text.wrappedValue.utf8.count > limit ? Color.red : Color.secondary)
                Button("Reset") { text.wrappedValue = defaultValue }
            }
            TextEditor(text: text).font(.body.monospaced()).frame(height: 130)
                .border(.quaternary)
        }
    }
}
