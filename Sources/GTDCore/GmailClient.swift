import Foundation

/// What the app needs from a mail backend: the real Gmail API or the in-memory demo.
public protocol MailService: Sendable {
    func listThreads(labelIDs: [String], query: String?, max: Int) async throws -> [ThreadRef]
    func thread(_ id: String, full: Bool) async throws -> GmailThread
    func labels() async throws -> [GmailLabel]
    func createLabel(_ name: String) async throws -> GmailLabel
    func modifyThread(_ id: String, add: [String], remove: [String]) async throws
    func threadCount(labelID: String) async throws -> Int
    func emailAddress() async throws -> String
}

extension MailService {
    public func listThreads(labelIDs: [String], max: Int) async throws -> [ThreadRef] {
        try await listThreads(labelIDs: labelIDs, query: nil, max: max)
    }
    public func thread(_ id: String) async throws -> GmailThread { try await thread(id, full: false) }
    public func modifyThread(_ id: String, remove: [String]) async throws {
        try await modifyThread(id, add: [], remove: remove)
    }
}

/// Thin Gmail REST client. Refreshes the access token as needed.
public actor GmailClient: MailService {
    private let auth: GmailAuth
    private var tokens: Tokens
    private let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!

    public init(auth: GmailAuth) throws {
        guard let tokens = TokenStore.load() else { throw GmailError.notSignedIn }
        self.auth = auth
        self.tokens = tokens
    }

    public func listThreads(labelIDs: [String], query: String?, max: Int) async throws -> [ThreadRef] {
        var items = [URLQueryItem(name: "maxResults", value: String(max))]
        items += labelIDs.map { URLQueryItem(name: "labelIds", value: $0) }
        if let query { items.append(.init(name: "q", value: query)) }
        let list: ThreadList = try await get("threads", items)
        return list.threads ?? []
    }

    /// Approximate number of threads carrying a label (Gmail's own estimate).
    public func threadCount(labelID: String) async throws -> Int {
        let list: ThreadList = try await get("threads", [.init(name: "labelIds", value: labelID), .init(name: "maxResults", value: "1")])
        return list.resultSizeEstimate ?? 0
    }

    public func emailAddress() async throws -> String {
        let profile: GmailProfile = try await get("profile")
        return profile.emailAddress
    }

    public func thread(_ id: String, full: Bool) async throws -> GmailThread {
        var items = [URLQueryItem(name: "format", value: full ? "full" : "metadata")]
        if !full { items += ["Subject", "From", "Date"].map { .init(name: "metadataHeaders", value: $0) } }
        return try await get("threads/\(id)", items)
    }

    public func labels() async throws -> [GmailLabel] {
        let list: LabelList = try await get("labels")
        return list.labels ?? []
    }

    public func createLabel(_ name: String) async throws -> GmailLabel {
        try await send("labels", method: "POST", body: [
            "name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show",
        ])
    }

    public func modifyThread(_ id: String, add: [String], remove: [String]) async throws {
        let _: GmailThread = try await send("threads/\(id)/modify", method: "POST",
                                            body: ["addLabelIds": add, "removeLabelIds": remove])
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        return try await perform(URLRequest(url: comps.url!))
    }

    private func send<T: Decodable>(_ path: String, method: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: base.appending(path: path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(req)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        if tokens.expiry <= Date() { tokens = try await auth.refresh(tokens) }
        var req = request
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GmailError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
