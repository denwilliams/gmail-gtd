import SafariServices
import SwiftUI
import AuthenticationServices
import GTDCore

/// The iPhone app. It shares the Mac app's model (`AppModel`), so filing, undo, facets, filters and the
/// on-device summaries behave the same; only the screens differ.
@main
struct GmailGTDiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setAppActive(phase == .active)
                }
                .task { await model.start() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var prewarm: SFSafariViewController.PrewarmingToken?

    var body: some View {
        @Bindable var model = model
        Group {
            if model.signedIn { MailNavigation() } else { SignInScreen() }
        }
        .sheet(item: $model.gmailPage) { page in SafariSheet(url: page.url).ignoresSafeArea() }
        .onChange(of: model.signedIn && !model.demo, initial: true) { _, live in
            prewarm?.invalidate()
            prewarm = live ? GmailPrewarm.start() : nil
        }
    }
}

// MARK: - Sign in

struct SignInScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var signingIn = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.full").font(.system(size: 44)).foregroundStyle(.tint)
                        Text("Gmail GTD").font(.largeTitle.bold())
                        Text("Sign in with your Google Workspace account.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("iOS OAuth client ID", text: $model.clientID, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.callout.monospaced())
                } header: {
                    Text("Google Cloud client")
                } footer: {
                    Text("Use an iOS OAuth client with bundle ID dev.denw.gmail-gtd.ios. The Mac app's Desktop client doesn't work on iPhone.")
                }
                Section {
                    Button {
                        signIn()
                    } label: {
                        HStack {
                            Text("Sign In")
                            if signingIn { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(signingIn || model.clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Try Demo") { Task { await model.startDemo() } }
                }
                if let error = model.error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
            }
        }
    }

    private func signIn() {
        signingIn = true
        let session = webAuthenticationSession
        Task {
            await model.signIn { url, scheme in
                try await session.authenticate(using: url, callbackURLScheme: scheme)
            }
            signingIn = false
        }
    }
}
