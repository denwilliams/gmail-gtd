import Foundation

public enum GmailLinks {
    /// Deep link to a thread in the Gmail web UI. `authuser` picks the right account when several are signed in.
    public static func thread(_ id: String, account email: String?) -> URL {
        var comps = URLComponents(string: "https://mail.google.com/mail/")!
        if let email { comps.queryItems = [.init(name: "authuser", value: email)] }
        comps.fragment = "all/\(id)"
        return comps.url!
    }

    public static func inbox(account email: String?) -> URL {
        var comps = URLComponents(string: "https://mail.google.com/mail/")!
        if let email { comps.queryItems = [.init(name: "authuser", value: email)] }
        comps.fragment = "inbox"
        return comps.url!
    }

    /// The Gmail iOS app's own scheme: web links open Safari, not the app. The thread form is undocumented (it's the
    /// one the app itself uses); the app opens on whichever account it last showed.
    public static func appThread(_ id: String) -> URL { URL(string: "googlegmail:///cv=\(id)/accountId=1")! }

    public static var appInbox: URL { URL(string: "googlegmail://")! }
}
