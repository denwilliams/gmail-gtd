import Foundation

public enum GmailLinks {
    /// Deep link to a thread in the Gmail web UI. `authuser` picks the right account when several are signed in.
    public static func thread(_ id: String, account email: String?) -> URL {
        var comps = URLComponents(string: "https://mail.google.com/mail/")!
        if let email { comps.queryItems = [.init(name: "authuser", value: email)] }
        comps.fragment = "all/\(id)"
        return comps.url!
    }

    /// The same thread in Gmail's phone web UI. Phone browsers are sent there, and it drops the desktop `#all/<id>`
    /// route, landing on the mailbox. All Mail, so archived threads open too. (Undocumented, like the desktop route.)
    public static func mobileThread(_ id: String, account email: String?) -> URL {
        var comps = URLComponents(string: "https://mail.google.com/mail/mu/mp/")!
        if let email { comps.queryItems = [.init(name: "authuser", value: email)] }
        comps.fragment = "cv/All Mail/\(id)"
        return comps.url!
    }

    public static func inbox(account email: String?) -> URL {
        var comps = URLComponents(string: "https://mail.google.com/mail/")!
        if let email { comps.queryItems = [.init(name: "authuser", value: email)] }
        comps.fragment = "inbox"
        return comps.url!
    }

    /// The Gmail iOS app (web links open Safari, not the app). It has no documented link to a thread, and opens on
    /// whichever account it last showed, so threads stay on the web link, which names the account.
    public static var appInbox: URL { URL(string: "googlegmail://")! }
}
