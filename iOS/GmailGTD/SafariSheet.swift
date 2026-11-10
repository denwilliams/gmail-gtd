import SafariServices
import SwiftUI

/// A web page in a Safari sheet over the app. (Google's sign-in works here; it's refused in an embedded web view.)
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let safari = SFSafariViewController(url: url)
        safari.dismissButtonStyle = .done
        return safari
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Opens connections to Gmail early (DNS, TLS), so the sheet doesn't wait for them. Keep the token while signed in.
@MainActor
enum GmailPrewarm {
    static func start() -> SFSafariViewController.PrewarmingToken {
        SFSafariViewController.prewarmConnections(to: [
            URL(string: "https://mail.google.com/mail/mu/mp/")!,
            URL(string: "https://accounts.google.com/")!,
        ])
    }
}
